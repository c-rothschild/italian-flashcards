#!/usr/bin/env python3
"""Local server for the Italian flashcard app.

Serves the web UI from ./static and a small JSON API that reads and writes
data/terms.csv (columns: term, definition, category). Standard library only.

If the project is a git repo with an "origin" remote, every change to the CSV is
committed and pushed so the iOS app can download the latest cards. Learn progress
(data/progress.json, not committed) is synced with the iOS app through the
repo's "progress" branch, using your `gh` login.

    python3 server.py                # http://127.0.0.1:8000, opens a browser
    python3 server.py --port 9000 --no-browser
    python3 server.py --no-sync      # don't push changes to GitHub
"""

import argparse
import base64
import csv
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
STATIC_DIR = APP_DIR / "static"
HEADER = ["term", "definition", "category"]


class ConflictError(Exception):
    """The client's view of the data is out of date."""


class GitSync:
    """Commits the terms CSV and pushes it to the "origin" remote.

    Saves are debounced so a burst of edits becomes one commit. Only the CSV is
    committed, so other uncommitted work in the repo is left alone. A failed
    push (e.g. offline) is retried after the next save and at the next startup.
    """

    DELAY = 3.0  # seconds of quiet before syncing

    def __init__(self, data_path):
        self.data_path = Path(data_path).resolve()
        self.lock = threading.Lock()
        self.timer = None
        self.state = "idle"  # idle | pending | syncing | ok | error
        self.message = ""
        self.last_synced = None
        self.repo = self._find_repo()
        self.enabled = self.repo is not None
        if not self.enabled:
            self.message = "Not syncing: data file isn't in a git repo with an \"origin\" remote."

    def _git(self, *args, cwd=None, timeout=60):
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        return subprocess.run(["git", "-C", str(cwd or self.repo), *args],
                              capture_output=True, text=True, timeout=timeout, env=env)

    def _find_repo(self):
        here = self.data_path.parent
        try:
            top = self._git("rev-parse", "--show-toplevel", cwd=here, timeout=10).stdout.strip()
            if not top or not self._git("remote", "get-url", "origin", cwd=here, timeout=10).stdout.strip():
                return None
            top = Path(top).resolve()
            return top if self.data_path.is_relative_to(top) else None
        except (OSError, subprocess.SubprocessError):
            return None

    def schedule(self):
        if not self.enabled:
            return
        with self.lock:
            if self.timer:
                self.timer.cancel()
            self.state = "pending"
            self.timer = threading.Timer(self.DELAY, self.sync)
            self.timer.daemon = True
            self.timer.start()

    def sync(self):
        if not self.enabled:
            return
        with self.lock:
            self.timer = None
            self.state = "syncing"
        rel = str(self.data_path.relative_to(self.repo))
        try:
            self._git("add", "--", rel)
            if self._git("diff", "--cached", "--quiet", "--", rel).returncode != 0:
                count = max(0, sum(1 for _ in open(self.data_path, encoding="utf-8")) - 1)
                done = self._git("commit", "-q", "-m", f"Update flashcards ({count} terms)", "--", rel)
                if done.returncode != 0:
                    raise RuntimeError(done.stderr.strip() or done.stdout.strip())
            pushed = self._git("push", "-q", "origin", "HEAD")
            if pushed.returncode != 0:
                raise RuntimeError(pushed.stderr.strip().splitlines()[-1] if pushed.stderr.strip() else "push failed")
            with self.lock:
                if self.state == "syncing":
                    self.state = "ok"
                self.message = "Synced to GitHub."
                self.last_synced = time.time()
            print("Synced flashcards to GitHub.")
        except (OSError, subprocess.SubprocessError, RuntimeError) as e:
            with self.lock:
                if self.state == "syncing":
                    self.state = "error"
                self.message = f"GitHub sync failed (will retry after your next change): {e}"
            print(self.message)

    def status(self):
        with self.lock:
            return {"enabled": self.enabled, "state": self.state, "message": self.message, "lastSynced": self.last_synced}


# --- Learn progress ---------------------------------------------------------
#
# progress.json: {"version": 1, "terms": {"<term>\u0000<definition>": record}} where a
# record is {"status": "new"|"learning"|"mastered", "misses": int, "firstTry": bool|null,
# "updated": ms since epoch}. Two copies merge term by term; the newer record wins.
# The iOS app (ios/ItalianFlashcards/Model/ProgressStore.swift) uses the same format.

STATUSES = ("new", "learning", "mastered")


def clean_record(rec):
    if not isinstance(rec, dict):
        return None
    status = rec.get("status")
    updated = rec.get("updated")
    if status not in STATUSES or not isinstance(updated, (int, float)) or isinstance(updated, bool):
        return None
    misses = rec.get("misses")
    first = rec.get("firstTry")
    return {
        "status": status,
        "misses": misses if isinstance(misses, int) and not isinstance(misses, bool) and misses >= 0 else 0,
        "firstTry": first if isinstance(first, bool) else None,
        "updated": updated,
    }


def merge_progress(into, other):
    """Copies records from `other` that are newer than the ones in `into`. Returns True if `into` changed."""
    changed = False
    for key, rec in (other or {}).items():
        rec = clean_record(rec)
        if not isinstance(key, str) or rec is None:
            continue
        mine = into.get(key)
        if mine is None or rec["updated"] > mine["updated"]:
            into[key] = rec
            changed = True
    return changed


def write_json_atomic(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".progress-", suffix=".json")
    try:
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class ProgressSync:
    """Keeps a local progress file in step with progress.json on the repo's
    "progress" branch (a branch of its own, so studying doesn't add commits to
    main). Uses the GitHub API with the token from `gh auth token`."""

    BRANCH = "progress"
    FILE = "progress.json"
    PUSH_DELAY = 3.0   # seconds of quiet after an answer before pushing
    PULL_EVERY = 30.0  # background check for progress made on the phone

    def __init__(self, path, repo_dir, enabled=True):
        self.path = Path(path)
        self.lock = threading.Lock()      # guards self.terms and status fields
        self.net_lock = threading.Lock()  # one GitHub round trip at a time
        self.terms = {}
        self.revision = 0                 # bumps whenever self.terms changes
        self.dirty = False                # local changes not yet on GitHub
        self.timer = None
        self.state = "idle"
        self.message = ""
        self.last_pull = 0.0
        self.etag = None
        self.sha = None
        self.token = None
        self.slug = None
        self._load()
        self.enabled = enabled and self._setup(repo_dir)
        if not enabled:
            self.message = "Progress stays on this computer (--no-sync)."

    # --- local file ---

    def _load(self):
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            merge_progress(self.terms, data.get("terms"))
            self.dirty = bool(data.get("unsynced"))
        except (OSError, ValueError, AttributeError):
            pass

    def _save(self):
        write_json_atomic(self.path, {"version": 1, "unsynced": self.dirty, "terms": self.terms})

    # --- GitHub plumbing ---

    def _setup(self, repo_dir):
        if repo_dir is None:
            self.message = "Progress stays on this computer: no GitHub repo."
            return False
        try:
            url = subprocess.run(["git", "-C", str(repo_dir), "remote", "get-url", "origin"],
                                 capture_output=True, text=True, timeout=10).stdout.strip()
            m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$", url)
            if not m:
                self.message = "Progress stays on this computer: origin isn't on GitHub."
                return False
            self.slug = f"{m.group(1)}/{m.group(2)}"
            self.token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            self.token = None
        if not self.token:
            self.message = "Progress stays on this computer: run `gh auth login` to sync it."
            return False
        return True

    def _api(self, method, path, body=None, headers=None):
        req = urllib.request.Request(
            f"https://api.github.com/repos/{self.slug}/{path}", method=method,
            data=None if body is None else json.dumps(body).encode("utf-8"),
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "italian-flashcards", **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=20) as res:
                return res.status, json.loads(res.read() or b"null"), res.headers
        except urllib.error.HTTPError as e:
            if e.code == 304:
                return 304, None, e.headers
            try:
                payload = json.loads(e.read() or b"null")
            except ValueError:
                payload = None
            return e.code, payload, e.headers

    def _fetch_remote(self):
        """Returns (records, changed); records is None when unchanged since the last fetch."""
        status, data, headers = self._api("GET", f"contents/{self.FILE}?ref={self.BRANCH}",
                                          headers={"If-None-Match": self.etag} if self.etag else None)
        if status == 304:
            return None
        if status == 404:  # no branch or file yet
            self.sha, self.etag = None, None
            self._ensure_branch()
            return {}
        if status != 200:
            raise RuntimeError(f"GitHub said {status}: {(data or {}).get('message', '')}".strip())
        self.sha = data["sha"]
        self.etag = headers.get("ETag")
        content = json.loads(base64.b64decode(data["content"]).decode("utf-8") or "{}")
        return content.get("terms") or {}

    def _ensure_branch(self):
        status, _, _ = self._api("GET", f"branches/{self.BRANCH}")
        if status == 200:
            return
        status, repo, _ = self._api("GET", "")
        base = repo["default_branch"] if status == 200 else "main"
        status, ref, _ = self._api("GET", f"git/ref/heads/{base}")
        if status != 200:
            raise RuntimeError("couldn't read the main branch")
        status, data, _ = self._api("POST", "git/refs", {"ref": f"refs/heads/{self.BRANCH}", "sha": ref["object"]["sha"]})
        if status not in (201, 422):  # 422: someone else just created it
            raise RuntimeError(f"couldn't create the progress branch ({status})")

    def _push(self, terms, mastered):
        body = {
            "message": f"Update learn progress ({mastered} mastered)",
            "branch": self.BRANCH,
            "content": base64.b64encode(
                (json.dumps({"version": 1, "terms": terms}, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")
            ).decode("ascii"),
        }
        if self.sha:
            body["sha"] = self.sha
        status, data, _ = self._api("PUT", f"contents/{self.FILE}", body)
        if status in (409, 422):  # someone (the phone) pushed in between
            return False
        if status not in (200, 201):
            raise RuntimeError(f"GitHub said {status}: {(data or {}).get('message', '')}".strip())
        self.sha = data["content"]["sha"]
        self.etag = None
        return True

    def sync(self, push=True):
        """Pulls the phone's progress and, if there are local changes, pushes the merged result."""
        if not self.enabled:
            return
        with self.net_lock:
            with self.lock:
                self.state = "syncing"
            try:
                for _ in range(4):
                    remote = self._fetch_remote()
                    with self.lock:
                        if remote is not None and merge_progress(self.terms, remote):
                            self.revision += 1
                        # Anything newer here than on GitHub still needs pushing.
                        if remote is not None and not self.dirty:
                            self.dirty = any(k not in remote or (clean_record(remote[k]) or {}).get("updated", -1) < r["updated"]
                                             for k, r in self.terms.items())
                        need_push = push and self.dirty
                        snapshot = dict(self.terms)
                        self._save()
                    self.last_pull = time.time()
                    if not need_push:
                        break
                    mastered = sum(1 for r in snapshot.values() if r["status"] == "mastered")
                    if self._push(snapshot, mastered):
                        with self.lock:
                            # Changes made while pushing stay dirty.
                            self.dirty = any(self.terms.get(k) != r for k, r in snapshot.items()) or len(self.terms) != len(snapshot)
                            self._save()
                        if not self.dirty:
                            break
                    self.etag = None  # conflict or more changes: fetch again and retry
                with self.lock:
                    if self.dirty and push:
                        self.state = "error"
                        self.message = "Couldn't push learn progress yet (will retry)."
                    else:
                        self.state = "ok"
                        self.message = "Learn progress synced with GitHub."
            except (OSError, ValueError, KeyError, RuntimeError) as e:
                with self.lock:
                    self.state = "error"
                    self.message = f"Couldn't sync learn progress (will retry): {e}"
                print(self.message)

    def schedule_push(self):
        if not self.enabled:
            return
        with self.lock:
            if self.timer:
                self.timer.cancel()
            self.timer = threading.Timer(self.PUSH_DELAY, self.sync)
            self.timer.daemon = True
            self.timer.start()

    def run_background(self):
        if not self.enabled:
            return

        def loop():
            while True:
                self.sync()
                time.sleep(self.PULL_EVERY)
        threading.Thread(target=loop, daemon=True).start()

    # --- used by the web app ---

    def snapshot(self):
        with self.lock:
            return {"terms": dict(self.terms), "revision": self.revision,
                    "sync": {"enabled": self.enabled, "state": self.state, "message": self.message}}

    def update(self, records):
        if not isinstance(records, dict):
            raise ValueError("Expected an object of progress records.")
        with self.lock:
            if merge_progress(self.terms, records):
                self.revision += 1
                self.dirty = True
                self._save()
        self.schedule_push()
        return self.snapshot()

    def rename(self, old_key, new_key):
        """A card's text was edited: carry its progress over to the new text."""
        with self.lock:
            rec = self.terms.get(old_key)
            if rec is None or old_key == new_key:
                return
            self.terms[new_key] = dict(rec, updated=max(rec["updated"], time.time() * 1000))
            self.revision += 1
            self.dirty = True
            self._save()
        self.schedule_push()

    def refresh(self, max_age=5.0):
        """Pull now unless we did so in the last few seconds (used when the page regains focus)."""
        if self.enabled and time.time() - self.last_pull > max_age:
            self.sync()


class TermStore:
    """CSV-backed term list. Rows are addressed by index; every mutation
    carries the term/definition the client expects at that index, so a
    stale client (e.g. after the CSV was edited by hand) gets a conflict
    instead of silently changing the wrong row."""

    def __init__(self, path, on_change=None, on_rename=None):
        self.path = Path(path)
        self.lock = threading.Lock()
        self.on_change = on_change
        self.on_rename = on_rename  # (old_key, new_key) when a card's text changes

    # --- file I/O -------------------------------------------------------

    def _read(self):
        if not self.path.exists():
            return []
        rows = []
        has_header = False
        with open(self.path, newline="", encoding="utf-8-sig") as f:
            for i, r in enumerate(csv.reader(f)):
                if not r or not any(c.strip() for c in r):
                    continue
                if i == 0 and [c.strip().lower() for c in r[:2]] == HEADER[:2]:
                    has_header = True
                    continue
                if not has_header:
                    # Headerless file in the original "term,definition" format; an
                    # unquoted comma belongs to the definition.
                    r = [r[0], ",".join(r[1:]), ""]
                elif len(r) < 3:
                    r = (r + ["", ""])[:3]
                elif len(r) > 3:
                    # Unquoted commas in the definition: keep the last field as the category.
                    r = [r[0], ",".join(r[1:-1]), r[-1]]
                rows.append({"term": r[0].strip(), "definition": r[1].strip(), "category": r[2].strip()})
        return rows

    def _write(self, rows):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".terms-", suffix=".csv")
        try:
            # mkstemp creates owner-only files; keep the CSV's existing (or normal) permissions.
            mode = self.path.stat().st_mode & 0o777 if self.path.exists() else 0o644
            os.chmod(tmp, mode | 0o644)
            with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(HEADER)
                for r in rows:
                    w.writerow([r["term"], r["definition"], r["category"]])
            os.replace(tmp, self.path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        if self.on_change:
            self.on_change()

    # --- helpers --------------------------------------------------------

    @staticmethod
    def snapshot(rows):
        cats = sorted({r["category"] for r in rows if r["category"]}, key=str.casefold)
        return {
            "terms": [dict(r, id=i) for i, r in enumerate(rows)],
            "categories": cats,
        }

    @staticmethod
    def _check(rows, item):
        i = item.get("id")
        exp = item.get("expected") or {}
        if not isinstance(i, int) or not 0 <= i < len(rows):
            raise ConflictError("That term no longer exists.")
        r = rows[i]
        if r["term"] != exp.get("term") or r["definition"] != exp.get("definition"):
            raise ConflictError("The term list changed since it was loaded.")
        return i

    @staticmethod
    def _clean(value, field, required=False):
        if not isinstance(value, str):
            value = "" if value is None else str(value)
        value = " ".join(value.split())
        if required and not value:
            raise ValueError(f"{field} cannot be empty.")
        return value

    # --- operations -----------------------------------------------------

    def get(self):
        with self.lock:
            return self.snapshot(self._read())

    def add(self, items):
        with self.lock:
            rows = self._read()
            # Insert lowest index first so restored rows (undo) land where they were.
            prepared = []
            for it in items:
                row = {
                    "term": self._clean(it.get("term"), "Term", required=True),
                    "definition": self._clean(it.get("definition"), "Definition", required=True),
                    "category": self._clean(it.get("category"), "Category"),
                }
                idx = it.get("index")
                prepared.append((idx if isinstance(idx, int) else None, row))
            positioned = sorted((p for p in prepared if p[0] is not None), key=lambda p: p[0])
            for idx, row in positioned:
                rows.insert(max(0, min(idx, len(rows))), row)
            rows.extend(row for idx, row in prepared if idx is None)
            self._write(rows)
            return self.snapshot(rows)

    def update(self, items):
        with self.lock:
            rows = self._read()
            changes = []
            for it in items:
                i = self._check(rows, it)
                new = dict(rows[i])
                for field, label, req in (("term", "Term", True), ("definition", "Definition", True), ("category", "Category", False)):
                    if field in it:
                        new[field] = self._clean(it[field], label, required=req)
                changes.append((i, new))
            renamed = [(rows[i], new) for i, new in changes]
            for i, new in changes:
                rows[i] = new
            self._write(rows)
            if self.on_rename:
                for old, new in renamed:
                    self.on_rename(old["term"] + "\0" + old["definition"], new["term"] + "\0" + new["definition"])
            return self.snapshot(rows)

    def delete(self, items):
        with self.lock:
            rows = self._read()
            idxs = {self._check(rows, it) for it in items}
            rows = [r for i, r in enumerate(rows) if i not in idxs]
            self._write(rows)
            return self.snapshot(rows)

    def rename_category(self, old, new):
        new = self._clean(new, "Category name", required=True)
        with self.lock:
            rows = self._read()
            if not any(r["category"] == old for r in rows):
                raise ConflictError(f"Category “{old}” no longer exists.")
            for r in rows:
                if r["category"] == old:
                    r["category"] = new
            self._write(rows)
            return self.snapshot(rows)

    def delete_category(self, name, delete_terms):
        with self.lock:
            rows = self._read()
            if delete_terms:
                rows = [r for r in rows if r["category"] != name]
            else:
                for r in rows:
                    if r["category"] == name:
                        r["category"] = ""
            self._write(rows)
            return self.snapshot(rows)


def make_handler(store, sync, progress):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

        def log_message(self, fmt, *args):
            if self.path.startswith("/api/"):
                super().log_message(fmt, *args)

        def end_headers(self):
            # Always serve fresh files so edits to the app show up on reload.
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def _json(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            route = self.path.split("?")[0]
            if route == "/api/terms":
                return self._json(HTTPStatus.OK, store.get())
            if route == "/api/sync-status":
                return self._json(HTTPStatus.OK, sync.status())
            if route == "/api/progress":
                if "refresh=1" in self.path:
                    progress.refresh()
                return self._json(HTTPStatus.OK, progress.snapshot())
            if self.path.startswith("/api/"):
                return self._json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            return super().do_GET()

        def do_POST(self):
            route = self.path.split("?")[0]
            try:
                length = int(self.headers.get("Content-Length") or 0)
                data = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(data, dict):
                    raise ValueError("Expected a JSON object.")
                if route == "/api/terms/add":
                    result = store.add(data.get("items") or [])
                elif route == "/api/terms/update":
                    result = store.update(data.get("items") or [])
                elif route == "/api/terms/delete":
                    result = store.delete(data.get("items") or [])
                elif route == "/api/categories/rename":
                    result = store.rename_category(data.get("from"), data.get("to"))
                elif route == "/api/categories/delete":
                    result = store.delete_category(data.get("name"), bool(data.get("deleteTerms")))
                elif route == "/api/progress":
                    result = progress.update(data.get("terms"))
                else:
                    return self._json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
            except ConflictError as e:
                return self._json(HTTPStatus.CONFLICT, {"error": str(e), **store.get()})
            except (ValueError, TypeError, AttributeError) as e:
                return self._json(HTTPStatus.BAD_REQUEST, {"error": str(e)})
            return self._json(HTTPStatus.OK, result)

    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--data", default=str(APP_DIR / "data" / "terms.csv"), help="path to the terms CSV")
    p.add_argument("--no-browser", action="store_true", help="don't open a browser tab")
    p.add_argument("--no-sync", action="store_true", help="don't commit/push changes or sync progress with GitHub")
    args = p.parse_args()

    sync = GitSync(args.data)
    if args.no_sync:
        sync.enabled = False
        sync.message = "Not syncing (--no-sync)."
    data_path = Path(args.data).resolve()
    progress = ProgressSync(data_path.parent / "progress.json", sync.repo, enabled=not args.no_sync)
    store = TermStore(args.data, on_change=sync.schedule, on_rename=progress.rename)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store, sync, progress))
    url = f"http://{args.host}:{args.port}/"
    print(f"Italian flashcards running at {url}  (data: {store.path})")
    print("GitHub sync: on (changes are pushed automatically)" if sync.enabled else sync.message)
    print("Learn progress: synced with the iOS app" if progress.enabled else progress.message)
    progress.run_background()
    if sync.enabled:
        # Push edits made while the server was off (or a push that failed last time).
        threading.Thread(target=sync.sync, daemon=True).start()
    print("Press Ctrl+C to stop.")
    if not args.no_browser:
        threading.Timer(0.5, webbrowser.open, [url]).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
