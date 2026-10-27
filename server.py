#!/usr/bin/env python3
"""Local server for the Italian flashcard app.

Serves the web UI from ./static and a small JSON API that reads and writes
data/terms.csv (columns: term, definition, category). Standard library only.

If the project is a git repo with an "origin" remote, every change to the CSV is
committed and pushed so the iOS app can download the latest cards.

    python3 server.py                # http://127.0.0.1:8000, opens a browser
    python3 server.py --port 9000 --no-browser
    python3 server.py --no-sync      # don't push changes to GitHub
"""

import argparse
import csv
import json
import os
import subprocess
import tempfile
import threading
import time
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


class TermStore:
    """CSV-backed term list. Rows are addressed by index; every mutation
    carries the term/definition the client expects at that index, so a
    stale client (e.g. after the CSV was edited by hand) gets a conflict
    instead of silently changing the wrong row."""

    def __init__(self, path, on_change=None):
        self.path = Path(path)
        self.lock = threading.Lock()
        self.on_change = on_change

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
            for i, new in changes:
                rows[i] = new
            self._write(rows)
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


def make_handler(store, sync):
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
    p.add_argument("--no-sync", action="store_true", help="don't commit/push changes to GitHub")
    args = p.parse_args()

    sync = GitSync(args.data)
    if args.no_sync:
        sync.enabled = False
        sync.message = "Not syncing (--no-sync)."
    store = TermStore(args.data, on_change=sync.schedule)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store, sync))
    url = f"http://{args.host}:{args.port}/"
    print(f"Italian flashcards running at {url}  (data: {store.path})")
    print("GitHub sync: on (changes are pushed automatically)" if sync.enabled else sync.message)
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
