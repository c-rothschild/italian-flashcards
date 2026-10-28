"use strict";

/* ================= helpers ================= */

const $ = (sel, root = document) => root.querySelector(sel);
const UNCATEGORIZED = "Uncategorized";

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === "class") node.className = v;
    else if (k === "dataset") Object.assign(node.dataset, v);
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else if (k === "html") node.innerHTML = v; // only used with static SVG strings below
    else node.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

const ICONS = {
  speaker: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H2v6h4l5 4V5z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>',
  edit: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5z"/></svg>',
  trash: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v6M14 11v6"/></svg>',
};

const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem("itflash:" + key); return v == null ? fallback : JSON.parse(v); }
    catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem("itflash:" + key, JSON.stringify(value)); } catch { /* storage unavailable */ }
  },
};

const catLabel = (c) => c || UNCATEGORIZED;
const cardKey = (t) => t.term + "\u0000" + t.definition;

function shuffled(arr) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/* ================= state ================= */

const state = {
  terms: [],
  categories: [],                                  // category keys; "" = uncategorized
  deselected: new Set(store.get("deselected", [])), // unchecked categories (new ones start checked)
  front: store.get("front", "term"),
  shuffle: store.get("shuffle", false),
  deck: [],
  pos: 0,
  flipped: false,
  view: store.get("view", "study"),
  // manage view
  search: "",
  filterCat: "__all__",
  editingId: null,
  editDraft: null,
  focusEdit: false,
  selectedIds: new Set(),
  renamingCat: null,
};

function applyData(data) {
  state.terms = data.terms;
  const cats = data.categories.slice();
  if (state.terms.some((t) => !t.category)) cats.push("");
  state.categories = cats;
  // ids are row positions, so any change can invalidate them
  state.selectedIds.clear();
  state.editingId = null;
  state.editDraft = null;
  if (state.filterCat !== "__all__" && !cats.includes(state.filterCat)) state.filterCat = "__all__";
  rebuildDeck({ keepOrder: true });
  reconcileLearn();
  renderAll();
}

/* ================= API ================= */

async function api(path, body) {
  let res;
  try {
    res = await fetch(path, body === undefined ? {} : {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    toast("Can't reach the app server. Is server.py still running?", { error: true });
    throw new Error("network");
  }
  const data = await res.json().catch(() => ({}));
  if (res.status === 409) {
    if (data.terms) applyData(data);
    toast(`${data.error} The list has been refreshed — please try again.`, { error: true });
    throw new Error("conflict");
  }
  if (!res.ok) {
    toast(data.error || `Something went wrong (${res.status}).`, { error: true });
    throw new Error("http " + res.status);
  }
  applyData(data);
  if (body !== undefined) pollSync();
  return data;
}

// Shows whether the latest edits have been pushed to GitHub (where the iOS app reads them).
let syncTimer;
async function pollSync() {
  clearTimeout(syncTimer);
  let st;
  try { st = await fetch("/api/sync-status").then((r) => r.json()); } catch { return; }
  const line = $("#sync-status");
  line.className = "sync-status";
  if (!st.enabled) {
    line.textContent = "Cloud sync is off — the iOS app won't see changes.";
    line.title = st.message || "";
    return;
  }
  line.title = st.message || "";
  if (st.state === "pending" || st.state === "syncing") {
    line.textContent = "Syncing to GitHub…";
    syncTimer = setTimeout(pollSync, 1500);
  } else if (st.state === "error") {
    line.textContent = "⚠ Couldn't sync to GitHub. Will retry after your next change.";
    line.classList.add("error");
  } else if (st.lastSynced) {
    const t = new Date(st.lastSynced * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    line.textContent = `✓ Synced to GitHub at ${t}`;
    line.classList.add("ok");
  } else {
    line.textContent = "Cloud sync is on.";
  }
}

const ref = (t) => ({ id: t.id, expected: { term: t.term, definition: t.definition } });

/* ================= toast & confirm ================= */

let toastTimer;
function toast(msg, { error = false, action = null, ms = 4000 } = {}) {
  const box = $("#toast");
  const btn = $("#toast-action");
  $("#toast-msg").textContent = msg;
  box.classList.toggle("error", error);
  btn.hidden = !action;
  btn.onclick = null;
  if (action) {
    btn.textContent = action.label;
    btn.onclick = () => { box.hidden = true; action.run(); };
  }
  box.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { box.hidden = true; }, action ? Math.max(ms, 6000) : ms);
}

function confirmDialog(title, body, buttons) {
  const dlg = $("#confirm-dialog");
  $("#confirm-title").textContent = title;
  $("#confirm-body").textContent = body;
  const actions = $("#confirm-actions");
  actions.replaceChildren(
    el("button", { class: "btn", value: "" }, "Cancel"),
    ...buttons.map((b) => el("button", { class: "btn " + (b.class || ""), value: b.value }, b.label)),
  );
  return new Promise((resolve) => {
    const form = dlg.querySelector("form");
    // Resolve on the button press itself; "close" also covers Esc. (Chrome can hold back
    // "close" for a tab that isn't being drawn.)
    const onSubmit = (e) => finish(e.submitter?.value ?? "");
    const onClose = () => finish(dlg.returnValue);
    const finish = (value) => {
      form.removeEventListener("submit", onSubmit);
      dlg.removeEventListener("close", onClose);
      resolve(value);
    };
    form.addEventListener("submit", onSubmit);
    dlg.addEventListener("close", onClose);
    dlg.returnValue = "";
    dlg.showModal();
  });
}

/* ================= speech ================= */

const speech = {
  supported: "speechSynthesis" in window,
  voices: [],
  voice: null,
  activeBtn: null,
};

function scoreVoice(v) {
  const n = v.name.toLowerCase();
  let s = 0;
  if (n.includes("premium")) s += 40;
  if (n.includes("enhanced")) s += 30;
  if (n.includes("google")) s += 20;
  if (v.lang.replace("_", "-").toLowerCase() === "it-it") s += 5;
  if (v.localService) s += 1;
  return s;
}

function loadVoices() {
  if (!speech.supported) return;
  const all = speechSynthesis.getVoices();
  speech.voices = all
    .filter((v) => v.lang.toLowerCase().startsWith("it"))
    .sort((a, b) => scoreVoice(b) - scoreVoice(a) || a.name.localeCompare(b.name));
  const saved = store.get("voice", null);
  speech.voice = speech.voices.find((v) => v.voiceURI === saved) || speech.voices[0] || null;

  const sel = $("#voice-select");
  if (!speech.voices.length) {
    sel.replaceChildren(el("option", { value: "" }, all.length ? "No Italian voice found" : "Default voice"));
    sel.disabled = true;
    return;
  }
  sel.disabled = false;
  sel.replaceChildren(...speech.voices.map((v) =>
    el("option", { value: v.voiceURI, selected: v === speech.voice }, v.name)));
}

function speak(text, btn) {
  if (!speech.supported) {
    toast("Your browser doesn't support speech synthesis.", { error: true });
    return;
  }
  const clean = text.replace(/\.{2,}|…/g, " ").trim();
  if (!clean) return;
  const u = new SpeechSynthesisUtterance(clean);
  u.lang = speech.voice ? speech.voice.lang : "it-IT";
  if (speech.voice) u.voice = speech.voice;
  u.rate = 0.9;
  const clear = () => { if (btn) btn.classList.remove("speaking"); };
  u.onstart = () => { if (speech.activeBtn && speech.activeBtn !== btn) speech.activeBtn.classList.remove("speaking"); speech.activeBtn = btn; btn?.classList.add("speaking"); };
  u.onend = clear;
  u.onerror = clear;
  const busy = speechSynthesis.speaking || speechSynthesis.pending;
  speechSynthesis.cancel();
  speechSynthesis.resume();
  // Chrome can drop an utterance queued in the same tick as cancel().
  if (busy) setTimeout(() => speechSynthesis.speak(u), 60);
  else speechSynthesis.speak(u);
}

function speakButton(text, extraClass = "speak-btn") {
  const btn = el("button", {
    class: extraClass,
    type: "button",
    title: "Pronounce",
    "aria-label": `Pronounce “${text}”`,
    html: ICONS.speaker,
  });
  btn.addEventListener("click", (e) => { e.stopPropagation(); speak(text, btn); });
  return btn;
}

/* ================= study ================= */

function isSelected(cat) { return !state.deselected.has(cat); }

function rebuildDeck({ keepOrder = false, reshuffle = false } = {}) {
  const pool = state.terms.filter((t) => isSelected(t.category));
  const current = state.deck[state.pos];
  let deck;
  if (state.shuffle && keepOrder && !reshuffle && state.deck.length) {
    // Keep the existing shuffled order; drop removed cards and mix in new ones at the end.
    const byKey = new Map(pool.map((t) => [cardKey(t), t]));
    deck = [];
    for (const old of state.deck) {
      const t = byKey.get(cardKey(old));
      if (t) { deck.push(t); byKey.delete(cardKey(old)); }
    }
    deck.push(...shuffled([...byKey.values()]));
  } else {
    deck = state.shuffle ? shuffled(pool) : pool;
  }
  state.deck = deck;
  if (keepOrder && current) {
    const i = deck.findIndex((t) => cardKey(t) === cardKey(current));
    state.pos = i >= 0 ? i : Math.min(state.pos, Math.max(0, deck.length - 1));
    if (i < 0) state.flipped = false;
  } else {
    state.pos = 0;
    state.flipped = false;
  }
}

function renderCategoryPanel() {
  const counts = new Map();
  for (const t of state.terms) counts.set(t.category, (counts.get(t.category) || 0) + 1);
  $("#cat-list").replaceChildren(...state.categories.map((c) => {
    const box = el("input", { type: "checkbox", checked: isSelected(c) });
    box.addEventListener("change", () => {
      if (box.checked) state.deselected.delete(c); else state.deselected.add(c);
      selectionChanged();
    });
    const label = el("label", { onmouseup: () => setTimeout(() => box.blur(), 0) }, box,
      el("span", { class: "name" }, catLabel(c)),
      el("span", { class: "count" }, counts.get(c) || 0));
    return el("li", {}, label);
  }));
  const n = state.terms.filter((t) => isSelected(t.category)).length;
  const k = state.categories.filter(isSelected).length;
  $("#cat-total").textContent = `${n} card${n === 1 ? "" : "s"} from ${k} of ${state.categories.length} categories`;
}

function selectionChanged() {
  saveSelection();
  rebuildDeck();
  resetLearn(); // the new session picks up your saved progress
  renderAll();
}

function saveSelection() {
  // Only remember categories that still exist.
  for (const c of [...state.deselected]) if (!state.categories.includes(c)) state.deselected.delete(c);
  store.set("deselected", [...state.deselected]);
}

function buildFace(t, side, isFront) {
  const isTerm = side === "term";
  const text = isTerm ? t.term : t.definition;
  const textEl = el("div", { class: "text" + (text.length > 40 ? " long" : ""), lang: isTerm ? "it" : "en" }, text);
  return [
    el("span", { class: "side-label" }, isTerm ? "Italiano" : "English"),
    isTerm ? speakButton(t.term) : null,
    textEl,
    el("span", { class: "cat-tag" }, catLabel(t.category)),
    isFront ? el("span", { class: "flip-hint" }, "click to flip") : null,
  ].filter(Boolean);
}

function renderCard() {
  const card = $("#card");
  const t = state.deck[state.pos];
  const empty = !t;
  card.hidden = empty;
  $("#empty-study").hidden = !empty;
  $("#prev-btn").disabled = empty || state.pos === 0;
  $("#next-btn").disabled = empty || state.pos >= state.deck.length - 1;
  $("#counter").textContent = empty ? "0 / 0" : `${state.pos + 1} / ${state.deck.length}`;
  $("#progress-bar").style.width = empty ? "0" : `${((state.pos + 1) / state.deck.length) * 100}%`;
  if (empty) return;

  const frontSide = state.front;
  const backSide = frontSide === "term" ? "definition" : "term";
  // Swap content without animating the card back to its front.
  card.classList.add("no-anim");
  card.classList.toggle("flipped", state.flipped);
  $("#face-front").replaceChildren(...buildFace(t, frontSide, true));
  $("#face-back").replaceChildren(...buildFace(t, backSide, false));
  void card.offsetWidth;
  card.classList.remove("no-anim");
}

function renderStudyToolbar() {
  for (const b of document.querySelectorAll("[data-front]")) b.setAttribute("aria-pressed", String(b.dataset.front === state.front));
  $("#shuffle-btn").setAttribute("aria-pressed", String(state.shuffle));
}

function renderStudy() {
  renderCategoryPanel();
  renderStudyToolbar();
  renderCard();
}

function flip() {
  if (!state.deck.length) return;
  state.flipped = !state.flipped;
  $("#card").classList.toggle("flipped", state.flipped);
}

function go(delta) {
  const next = state.pos + delta;
  if (next < 0 || next >= state.deck.length) return;
  state.pos = next;
  state.flipped = false;
  renderCard();
}

function speakCurrent() {
  const t = state.deck[state.pos];
  if (!t) return;
  speak(t.term, document.querySelector("#card .speak-btn"));
}

/* ================= learn ================= */

// Answer checking. Ignores case, punctuation and extra spaces; any one part of a
// "hi/bye" or "good morning, good day" answer counts, "(male)"-style notes are
// optional, and English answers may drop a leading "the/a/an/to". A missing or
// wrong accent still counts, with a reminder.

const ROUND_SIZE = 7;
const ACCENTS = ["à", "è", "é", "ì", "ò", "ù"];

function normalizeAnswer(s) {
  return s.toLowerCase().normalize("NFC")
    .replace(/[’‘`´]/g, "'")
    .replace(/\s*\/\s*/g, "/")
    .replace(/\s*'\s*/g, "'")
    .replace(/[.,!?¿¡;:"“”«»…()[\]]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const stripAccents = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").normalize("NFC");
const dropArticle = (s) => s.replace(/^(the|a|an|to) /, "");
// "lui/lei parla" -> "parla": Italian usually drops the subject pronoun.
const dropPronoun = (s) => s.replace(/^(io|tu|lui|lei|noi|voi|loro) (?=\S)/, "");

// Word-level alternatives: "lui/lei è" -> "lui è", "lei è"; "he/she speaks" -> "he speaks",
// "she speaks"; a one-letter ending swaps the last letter: "sposato/a" -> "sposato", "sposata".
function expandSlashes(n) {
  let combos = [""];
  for (const word of n.split(" ")) {
    const opts = word.split("/").filter(Boolean)
      .map((o, i, all) => (i > 0 && o.length === 1 && all[0].length > 2 ? all[0].slice(0, -1) + o : o));
    if (!opts.length) continue;
    combos = combos.flatMap((c) => opts.map((o) => (c ? c + " " + o : o))).slice(0, 64);
  }
  return combos;
}

function acceptedAnswers(answer, english) {
  const out = new Set();
  const add = (s) => {
    const n = normalizeAnswer(s);
    if (!n) return;
    for (const v of [n, ...expandSlashes(n)]) {
      out.add(v);
      if (english && dropArticle(v)) out.add(dropArticle(v));
      if (!english && dropPronoun(v) !== v) out.add(dropPronoun(v));
    }
  };
  const noNotes = answer.replace(/\([^)]*\)/g, " ");
  for (const base of [answer, noNotes]) {
    add(base);
    for (const part of base.split(/[,;]/)) add(part);
    for (const part of base.split(/[/,;]/)) add(part);
  }
  return out;
}

/** "correct" | "accent" (right apart from accents) | "wrong" */
function gradeAnswer(input, answer, english) {
  const accepted = acceptedAnswers(answer, english);
  const given = normalizeAnswer(input);
  const tries = english ? [given, dropArticle(given)] : [given];
  if (tries.some((g) => accepted.has(g))) return "correct";
  const loose = new Set([...accepted].map(stripAccents));
  if (tries.some((g) => loose.has(stripAccents(g)))) return english ? "correct" : "accent";
  return "wrong";
}

/* ================= learn progress (synced with the iPhone app) ================= */

// key -> { status: "new"|"learning"|"mastered", misses, firstTry, updated }. The server keeps
// the copy in data/progress.json and syncs it with GitHub, where the iPhone app reads it.
const progress = {
  terms: new Map(),
  revision: null,
  pending: {}, // records not yet saved on the server
  sync: null,
  flushTimer: null,
};

async function loadProgress({ refresh = false } = {}) {
  let data;
  try {
    const res = await fetch("/api/progress" + (refresh ? "?refresh=1" : ""));
    if (!res.ok) return;
    data = await res.json();
  } catch { return; }
  applyProgress(data);
}

function applyProgress(data) {
  progress.sync = data.sync;
  if (data.revision !== progress.revision) {
    progress.revision = data.revision;
    progress.terms = new Map(Object.entries(data.terms || {}));
    for (const [k, rec] of Object.entries(progress.pending)) progress.terms.set(k, rec); // ours are newer
    if (syncLearnWithProgress() && state.view === "learn") { renderLearn(); return; }
  }
  if (state.view === "learn") renderLearnProgress();
}

function saveProgress(records) {
  const updated = Date.now();
  for (const [k, rec] of Object.entries(records)) {
    const full = { ...rec, updated };
    progress.terms.set(k, full);
    progress.pending[k] = full;
  }
  clearTimeout(progress.flushTimer);
  progress.flushTimer = setTimeout(flushProgress, 300);
}

async function flushProgress() {
  const sent = progress.pending;
  if (!Object.keys(sent).length) return;
  let data;
  try {
    const res = await fetch("/api/progress", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ terms: sent }),
    });
    if (!res.ok) throw new Error(String(res.status));
    data = await res.json();
  } catch {
    progress.flushTimer = setTimeout(flushProgress, 10000); // server unreachable: try again later
    return;
  }
  for (const [k, rec] of Object.entries(sent)) if (progress.pending[k] === rec) delete progress.pending[k];
  applyProgress(data);
}

// Saves an item's Learn state for its card (not for "practice missed" sessions).
function recordProgress(key) {
  const s = learn.s;
  if (s.missedOnly) return;
  const item = s.items.get(key);
  saveProgress({ [key]: { status: item.status, misses: item.misses, firstTry: item.firstTry } });
}

const learn = {
  answerWith: store.get("learnAnswer", "term"), // "term" | "definition" | "both"
  autoAudio: store.get("learnAudio", false),
  s: null, // current session; created lazily when the Learn tab renders
  autoTimer: null,
};

// Picks up where you left off: mastered terms are done, ones you're still learning come first.
function newSession(pool, { missedOnly = false } = {}) {
  const items = new Map(pool.map((t) => {
    const rec = missedOnly ? null : progress.terms.get(cardKey(t));
    return [cardKey(t), { t, status: rec?.status || "new", misses: rec?.misses || 0, firstTry: rec?.firstTry ?? null }];
  }));
  const keys = [...items.keys()];
  const learning = keys.filter((k) => items.get(k).status === "learning");
  const fresh = keys.filter((k) => items.get(k).status === "new");
  return { items, queue: [...shuffled(learning), ...shuffled(fresh)], round: null, phase: "idle", q: null, missedOnly, skips: [] };
}

// "Restart" / "Learn again": forget the progress on the selected terms (here and on the phone).
function restartLearn() {
  const reset = {};
  for (const t of state.terms) {
    const k = cardKey(t);
    if (isSelected(t.category) && progress.terms.has(k) && progress.terms.get(k).status !== "new") {
      reset[k] = { status: "new", misses: 0, firstTry: null };
    }
  }
  if (Object.keys(reset).length) saveProgress(reset);
  resetLearn();
  renderLearn();
}

function resetLearn() {
  clearTimeout(learn.autoTimer);
  learn.s = null;
}

function ensureSession() {
  if (learn.s) return learn.s;
  const pool = state.terms.filter((t) => isSelected(t.category));
  if (!pool.length) return null;
  learn.s = newSession(pool);
  startRound();
  return learn.s;
}

function startRound() {
  const s = learn.s;
  clearTimeout(learn.autoTimer);
  if (!s.queue.length) { s.phase = "done"; return; }
  s.round = { n: (s.round?.n || 0) + 1, keys: s.queue.splice(0, ROUND_SIZE), idx: 0, results: new Map() };
  askCurrent();
}

function askCurrent() {
  const s = learn.s;
  const key = s.round.keys[s.round.idx];
  const answerSide = learn.answerWith === "both" ? (Math.random() < 0.5 ? "term" : "definition") : learn.answerWith;
  s.q = { key, answerSide, given: null, grade: null, retypeError: false, firstAttempt: s.items.get(key).firstTry === null };
  s.skips = s.skips.filter((k) => k !== key); // it's back, so there's no skip left to undo
  s.phase = "asking";
  if (learn.autoAudio && answerSide === "definition") speak(s.items.get(key).t.term);
}

function currentItem() { return learn.s.items.get(learn.s.q.key); }
const answerText = (item, side) => (side === "term" ? item.t.term : item.t.definition);

function submitAnswer(input) {
  const s = learn.s;
  const item = currentItem();
  const grade = gradeAnswer(input, answerText(item, s.q.answerSide), s.q.answerSide === "definition");
  s.q.given = input;
  s.q.grade = grade;
  if (item.firstTry === null) item.firstTry = grade !== "wrong";
  if (grade === "wrong") {
    item.misses++;
    item.status = "learning";
    s.round.results.set(s.q.key, false);
    s.phase = "wrong";
  } else {
    item.status = "mastered";
    s.round.results.set(s.q.key, true);
    s.phase = "correct";
  }
  recordProgress(s.q.key);
  if (learn.autoAudio && s.q.answerSide === "term") speak(item.t.term);
  renderLearn();
}

function giveUp() {
  const s = learn.s;
  const item = currentItem();
  if (item.firstTry === null) item.firstTry = false;
  item.misses++;
  item.status = "learning";
  s.round.results.set(s.q.key, false);
  s.q.given = null;
  s.q.grade = "wrong";
  s.phase = "wrong";
  recordProgress(s.q.key);
  if (learn.autoAudio && s.q.answerSide === "term") speak(item.t.term);
  renderLearn();
}

function overrideCorrect() {
  const s = learn.s;
  const item = currentItem();
  item.misses = Math.max(0, item.misses - 1);
  if (s.q.firstAttempt) item.firstTry = true;
  item.status = "mastered";
  s.round.results.set(s.q.key, true);
  recordProgress(s.q.key);
  nextQuestion();
}

function checkRetype(input) {
  const s = learn.s;
  const grade = gradeAnswer(input, answerText(currentItem(), s.q.answerSide), s.q.answerSide === "definition");
  if (grade === "wrong") {
    s.q.retypeError = true;
    renderLearn({ keepRetype: input });
    return;
  }
  nextQuestion(); // still unlearned: it comes back next round
}

function nextQuestion() {
  const s = learn.s;
  clearTimeout(learn.autoTimer);
  s.round.idx++;
  if (s.round.idx < s.round.keys.length) askCurrent();
  else endRound();
  renderLearn();
}

// Skip: move the current term to the very end of everything still to learn, without
// counting it as right or wrong.
function canSkip() {
  const s = learn.s;
  return [...s.items].some(([k, item]) => k !== s.q.key && item.status !== "mastered");
}

function skipQuestion() {
  const s = learn.s;
  const r = s.round;
  if (s.phase !== "asking" || !canSkip()) return;
  const item = currentItem();
  const shown = answerText(item, s.q.answerSide === "term" ? "definition" : "term"); // don't reveal the answer
  r.keys.splice(r.idx, 1); // idx now points at the next term in the round
  s.queue.push(s.q.key);
  s.skips.push(s.q.key);
  if (r.idx < r.keys.length) askCurrent();
  else if (r.keys.length) endRound();
  else startRound(); // nothing was answered this round, so skip the empty summary
  toast(`Skipped “${shown}”. It'll come back at the end.`, { ms: 2200, action: { label: "Undo", run: undoSkip } });
  renderLearn();
}

// The most recent skipped term that hasn't come back yet (undo works between questions).
function lastSkip() {
  const s = learn.s;
  if (!s || !["asking", "summary"].includes(s.phase)) return null;
  while (s.skips.length && !s.items.has(s.skips.at(-1))) s.skips.pop(); // deleted on the Manage tab
  return s.skips.at(-1) ?? null;
}

// Bring the last skipped term back right away.
function undoSkip() {
  const s = learn.s;
  const key = lastSkip();
  if (!key) return;
  s.skips.pop();
  s.queue = s.queue.filter((k) => k !== key);
  const r = s.round;
  if (s.phase === "asking") {
    const later = r.keys.indexOf(key, r.idx + 1); // already pulled into this round
    if (later !== -1) r.keys.splice(later, 1);
    r.keys.splice(r.idx, 0, key); // ask it now; the current term is next
    askCurrent();
  } else {
    s.queue.unshift(key);
    startRound();
  }
  renderLearn();
}

function undoSkipButton() {
  const key = lastSkip();
  if (!key) return null;
  const item = learn.s.items.get(key);
  return el("button", { class: "link", type: "button", onclick: undoSkip, title: `Bring back “${item.t.term}” now` }, "Undo last skip");
}

function endRound() {
  const s = learn.s;
  // Missed terms lead the next round, the way Quizlet keeps working on them.
  const missed = s.round.keys.filter((k) => s.items.has(k) && !s.round.results.get(k) && s.items.get(k).status !== "mastered");
  s.queue = [...shuffled(missed), ...s.queue];
  s.phase = s.queue.length ? "summary" : "done";
}

// Keep a running session in step with edits made on the Manage tab.
function reconcileLearn() {
  const s = learn.s;
  if (!s) return;
  const all = new Map(state.terms.map((t) => [cardKey(t), t]));
  for (const [k, item] of s.items) {
    if (all.has(k)) item.t = all.get(k);
    else s.items.delete(k);
  }
  if (!s.missedOnly) {
    for (const t of state.terms) {
      const k = cardKey(t);
      if (isSelected(t.category) && !s.items.has(k)) {
        const rec = progress.terms.get(k); // e.g. a card whose text was just edited
        s.items.set(k, { t, status: rec?.status || "new", misses: rec?.misses || 0, firstTry: rec?.firstTry ?? null });
        if (rec?.status !== "mastered") s.queue.push(k);
      }
    }
  }
  if (!s.items.size) { resetLearn(); return; }
  s.queue = s.queue.filter((k) => s.items.has(k));
  if (s.round) {
    const r = s.round;
    const inQuestion = ["asking", "correct", "wrong"].includes(s.phase);
    const currentGone = inQuestion && !s.items.has(r.keys[r.idx]);
    const before = r.keys.slice(0, r.idx).filter((k) => s.items.has(k)).length;
    r.keys = r.keys.filter((k) => s.items.has(k));
    r.idx = before;
    if (currentGone) {
      if (r.idx < r.keys.length) askCurrent(); else endRound();
    }
  }
  if (s.phase === "done" && s.queue.length) s.phase = "summary";
}

// Progress arrived from the phone: update the running session without interrupting the
// current question. Returns true if the Learn screen needs redrawing.
function syncLearnWithProgress() {
  const s = learn.s;
  if (!s || s.missedOnly) return false;
  const inQuestion = ["asking", "correct", "wrong"].includes(s.phase);
  const busy = inQuestion && s.phase !== "asking" ? s.q.key : null; // just answered here, so ours is newest
  let changed = false;
  for (const [k, item] of s.items) {
    if (k === busy) continue;
    const rec = progress.terms.get(k);
    const status = rec?.status || "new";
    if (status === item.status && (rec?.misses || 0) === item.misses) continue;
    Object.assign(item, { status, misses: rec?.misses || 0, firstTry: rec?.firstTry ?? null });
    changed = true;
  }
  if (!changed) return false;
  const r = s.round;
  const from = r ? (inQuestion ? r.idx + 1 : r.keys.length) : 0;
  const notMastered = (k) => s.items.get(k).status !== "mastered";
  // Mastered elsewhere: don't ask again. Reset elsewhere: ask again at the end.
  s.queue = s.queue.filter(notMastered);
  if (r) r.keys = [...r.keys.slice(0, from), ...r.keys.slice(from).filter(notMastered)];
  const scheduled = new Set([...s.queue, ...(r ? r.keys.slice(from) : [])]);
  if (inQuestion) {
    scheduled.add(s.q.key);
    for (const k of r.keys.slice(0, r.idx)) if (!r.results.get(k)) scheduled.add(k); // endRound requeues these
  }
  for (const [k, item] of s.items) if (item.status !== "mastered" && !scheduled.has(k)) s.queue.push(k);
  const phase = s.phase;
  if (phase === "summary" && !s.queue.length) s.phase = "done";
  if (phase === "done" && s.queue.length) startRound();
  return s.phase !== phase || phase === "summary";
}

function accentButtons(getInput) {
  return el("div", { class: "accent-row", "aria-label": "Insert accented letter" }, ACCENTS.map((ch) =>
    el("button", {
      class: "accent-btn",
      type: "button",
      lang: "it",
      onmousedown: (e) => e.preventDefault(), // keep focus (and the caret) in the input
      onclick: () => {
        const input = getInput();
        const { selectionStart: a, selectionEnd: b, value } = input;
        input.value = value.slice(0, a) + ch + value.slice(b);
        input.setSelectionRange(a + 1, a + 1);
        input.focus();
      },
    }, ch)));
}

function sideName(side) { return side === "term" ? "Italian" : "English"; }

function promptBlock(item, q) {
  const promptSide = q.answerSide === "term" ? "definition" : "term";
  const text = answerText(item, promptSide);
  return el("div", {},
    el("div", { class: "learn-head" },
      el("span", { class: "side-label" }, promptSide === "term" ? "Italiano" : "English"),
      el("span", { class: "cat-tag" }, catLabel(item.t.category))),
    el("div", { class: "learn-prompt" },
      el("span", { lang: promptSide === "term" ? "it" : "en" }, text),
      promptSide === "term" ? speakButton(item.t.term, "speak-btn inline") : null));
}

function answerWithAudio(item, side) {
  const text = answerText(item, side);
  return el("span", { class: "answer-text" },
    el("strong", { lang: side === "term" ? "it" : "en" }, text),
    side === "term" ? speakButton(item.t.term, "speak-btn inline small") : null);
}

function renderLearnToolbar() {
  for (const b of document.querySelectorAll("[data-answer]")) b.setAttribute("aria-pressed", String(b.dataset.answer === learn.answerWith));
  $("#learn-audio-btn").setAttribute("aria-pressed", String(learn.autoAudio));
}

function renderLearnProgress() {
  const s = learn.s;
  const items = s ? [...s.items.values()] : [];
  const total = items.length;
  const mastered = items.filter((i) => i.status === "mastered").length;
  const learning = items.filter((i) => i.status === "learning").length;
  const fresh = total - mastered - learning;
  $("#learn-bar-mastered").style.width = total ? `${(mastered / total) * 100}%` : "0";
  $("#learn-bar-learning").style.width = total ? `${(learning / total) * 100}%` : "0";
  $("#learn-stats").replaceChildren(...(total ? [
    el("span", { class: "stat" }, el("i", { class: "dot-mastered" }), `${mastered} mastered`),
    el("span", { class: "stat" }, el("i", { class: "dot-learning" }), `${learning} still learning`),
    el("span", { class: "stat" }, el("i", { class: "dot-new" }), `${fresh} not studied`),
    s.round && s.phase !== "done" ? el("span", { class: "stat round" }, `Round ${s.round.n}`) : null,
    progressSyncStat(),
  ] : []).filter(Boolean));
}

function progressSyncStat() {
  const st = progress.sync;
  if (!st) return null;
  const [text, cls] = !st.enabled ? ["Progress saved on this computer only", "warn"]
    : Object.keys(progress.pending).length || st.state === "syncing" ? ["Saving progress…", ""]
    : st.state === "error" ? ["Progress not synced yet", "warn"]
    : ["Progress synced with iPhone", ""];
  return el("span", { class: "stat sync " + cls, title: st.message || "" }, text);
}

function renderLearn({ keepRetype = null } = {}) {
  renderLearnToolbar();
  const s = ensureSession();
  renderLearnProgress();
  const body = $("#learn-body");
  clearTimeout(learn.autoTimer);
  if (!s) {
    body.replaceChildren(el("div", { class: "empty" },
      el("p", { class: "empty-title" }, "Nothing to learn yet"),
      el("p", {}, "Pick one or more categories on the left.")));
    return;
  }
  let focus = null;
  const item = s.q && s.items.get(s.q.key);

  if (s.phase === "asking") {
    const input = el("input", {
      class: "answer-input", type: "text", autocomplete: "off", autocapitalize: "off", spellcheck: "false",
      lang: s.q.answerSide === "term" ? "it" : "en",
      placeholder: `Type the ${sideName(s.q.answerSide)}`, "aria-label": `Your answer in ${sideName(s.q.answerSide)}`,
    });
    const submit = () => {
      if (!input.value.trim()) { giveUp(); return; } // empty answer = "Don't know"
      submitAnswer(input.value);
    };
    input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.repeat) { e.preventDefault(); submit(); } });
    body.replaceChildren(el("div", { class: "panel learn-card" },
      promptBlock(item, s.q),
      el("label", { class: "answer-label" }, `Your answer (${sideName(s.q.answerSide)})`),
      el("div", { class: "answer-row" }, input, el("button", { class: "btn primary", type: "button", onclick: submit }, "Answer")),
      s.q.answerSide === "term" ? accentButtons(() => input) : null,
      el("div", { class: "learn-foot" },
        el("button", { class: "link", type: "button", onclick: giveUp }, "Don't know?"),
        canSkip() ? el("button", { class: "link", type: "button", onclick: skipQuestion, title: "Move this term to the end" }, "Skip") : null,
        undoSkipButton())));
    focus = input;
  } else if (s.phase === "correct") {
    const cont = el("button", { class: "btn primary", type: "button", onclick: nextQuestion }, "Continue");
    const exact = s.q.grade === "correct" && normalizeAnswer(s.q.given) === normalizeAnswer(answerText(item, s.q.answerSide));
    body.replaceChildren(el("div", { class: "panel learn-card" },
      promptBlock(item, s.q),
      el("div", { class: "feedback good" },
        el("p", { class: "feedback-title" }, s.q.grade === "accent" ? "Correct — but watch the accents!" : pick(["Great job!", "Correct!", "Perfetto!", "Bravo!", "Esatto!"])),
        exact ? null : el("p", { class: "answer-line" }, el("span", { class: "muted" }, "Answer: "), answerWithAudio(item, s.q.answerSide)),
        exact ? el("p", { class: "answer-line" }, answerWithAudio(item, s.q.answerSide)) : null),
      el("div", { class: "learn-foot end" }, el("span", { class: "muted small" }, "Press Enter to continue"), cont)));
    focus = cont;
    // Quizlet-style: move on by itself after a clean answer; wait when there's an accent note to read.
    if (s.q.grade === "correct") {
      const q = s.q;
      learn.autoTimer = setTimeout(() => { if (learn.s === s && s.q === q && s.phase === "correct" && state.view === "learn") nextQuestion(); }, 1400);
    }
  } else if (s.phase === "wrong") {
    const retype = el("input", {
      class: "answer-input" + (s.q.retypeError ? " error" : ""), type: "text", autocomplete: "off", autocapitalize: "off", spellcheck: "false",
      lang: s.q.answerSide === "term" ? "it" : "en", placeholder: "Type the correct answer", "aria-label": "Type the correct answer",
    });
    if (keepRetype != null) retype.value = keepRetype;
    const check = () => {
      if (!retype.value.trim()) { shake(retype); retype.focus(); return; }
      checkRetype(retype.value);
    };
    retype.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.repeat) { e.preventDefault(); check(); } });
    const skipped = s.q.given == null;
    body.replaceChildren(el("div", { class: "panel learn-card" },
      promptBlock(item, s.q),
      el("div", { class: "feedback bad" },
        el("p", { class: "feedback-title" }, skipped ? "No problem — here's the answer. You'll see it again." : "Not quite — you'll see this one again."),
        skipped ? null : el("div", { class: "answer-line" },
          el("span", { class: "muted" }, "You said: "), el("del", {}, s.q.given),
          el("button", { class: "btn override", type: "button", onclick: overrideCorrect, title: "Count this answer as correct" }, "Override: I was right")),
        el("div", { class: "answer-line" }, el("span", { class: "muted" }, "Correct answer: "), answerWithAudio(item, s.q.answerSide))),
      el("label", { class: "answer-label" }, "Type the correct answer to continue"),
      el("div", { class: "answer-row" }, retype, el("button", { class: "btn primary", type: "button", onclick: check }, "Check")),
      s.q.answerSide === "term" ? accentButtons(() => retype) : null,
      s.q.retypeError ? el("p", { class: "retype-error" }, "That doesn't match yet — copy the answer above.") : null));
    focus = retype;
    if (s.q.retypeError) { shake(retype); s.q.retypeError = false; }
  } else if (s.phase === "summary") {
    const r = s.round;
    const right = r.keys.filter((k) => r.results.get(k)).length;
    const total = s.items.size;
    const mastered = [...s.items.values()].filter((i) => i.status === "mastered").length;
    const cont = el("button", { class: "btn primary", type: "button", onclick: () => { startRound(); renderLearn(); } }, "Continue to next round");
    body.replaceChildren(el("div", { class: "panel learn-card" },
      el("p", { class: "summary-title" }, `Round ${r.n} done — ${right} of ${r.keys.length} correct`),
      el("p", { class: "muted" }, `You've mastered ${mastered} of ${total} terms. Keep going!`),
      roundList(r.keys.map((k) => ({ item: s.items.get(k), ok: !!r.results.get(k) }))),
      el("div", { class: "learn-foot end" }, el("span", { class: "muted small" }, "Press Enter to continue"), undoSkipButton(), cont)));
    focus = cont;
  } else if (s.phase === "done") {
    const items = [...s.items.values()];
    const firstTry = items.filter((i) => i.firstTry).length;
    const missed = items.filter((i) => i.misses > 0).sort((a, b) => b.misses - a.misses);
    const again = el("button", { class: "btn primary", type: "button", onclick: restartLearn }, "Learn again");
    const practice = missed.length ? el("button", {
      class: "btn", type: "button",
      onclick: () => { learn.s = newSession(missed.map((i) => i.t), { missedOnly: true }); startRound(); renderLearn(); },
    }, `Practice the ${missed.length} I missed`) : null;
    body.replaceChildren(el("div", { class: "panel learn-card" },
      el("p", { class: "summary-title" }, s.missedOnly ? "You've got the tricky ones now! 🎉" : `You've learned all ${items.length} terms! 🎉`),
      el("p", { class: "muted" }, `${firstTry} of ${items.length} right on the first try (${Math.round((firstTry / items.length) * 100)}%).`),
      missed.length ? el("p", { class: "list-title" }, "Most missed") : el("p", {}, "A perfect run — nothing missed."),
      missed.length ? roundList(missed.slice(0, 12).map((i) => ({ item: i, ok: false, note: `missed ${i.misses}×` }))) : null,
      el("div", { class: "learn-foot end" }, practice, again)));
    focus = practice || again;
  }
  if (focus) focus.focus({ preventScroll: true });
}

function roundList(rows) {
  return el("ul", { class: "round-list" }, rows.map(({ item, ok, note }) =>
    el("li", {},
      el("span", { class: "mark " + (ok ? "ok" : "miss"), "aria-label": ok ? "correct" : "missed" }, ok ? "✓" : "✗"),
      el("span", { class: "rl-term", lang: "it" }, item.t.term),
      el("span", { class: "rl-def" }, item.t.definition),
      note ? el("span", { class: "count" }, note) : null)));
}

function shake(node) {
  node.classList.remove("shake");
  void node.offsetWidth;
  node.classList.add("shake");
}

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

/* ================= manage ================= */

function visibleTerms() {
  const q = state.search.trim().toLowerCase();
  return state.terms.filter((t) =>
    (state.filterCat === "__all__" || t.category === state.filterCat) &&
    (!q || t.term.toLowerCase().includes(q) || t.definition.toLowerCase().includes(q) || catLabel(t.category).toLowerCase().includes(q)));
}

function renderCatOptions() {
  $("#cat-options").replaceChildren(...state.categories.filter(Boolean).map((c) => el("option", { value: c })));
  const sel = $("#filter-cat");
  sel.replaceChildren(
    el("option", { value: "__all__" }, "All categories"),
    ...state.categories.map((c) => el("option", { value: c }, catLabel(c))),
  );
  sel.value = state.filterCat;
}

function termRow(t) {
  if (t.id === state.editingId) return editRow(t);
  const check = el("input", { type: "checkbox", checked: state.selectedIds.has(t.id), "aria-label": `Select ${t.term}` });
  check.addEventListener("change", () => {
    if (check.checked) state.selectedIds.add(t.id); else state.selectedIds.delete(t.id);
    renderTable();
  });
  const editBtn = el("button", { class: "icon-btn", type: "button", title: "Edit", "aria-label": `Edit ${t.term}`, html: ICONS.edit });
  editBtn.addEventListener("click", () => startEdit(t));
  const delBtn = el("button", { class: "icon-btn del", type: "button", title: "Delete", "aria-label": `Delete ${t.term}`, html: ICONS.trash });
  delBtn.addEventListener("click", () => deleteTerms([t]));
  return el("tr", { class: state.selectedIds.has(t.id) ? "selected" : null },
    el("td", {}, check),
    el("td", { class: "term", lang: "it" }, t.term),
    el("td", {}, t.definition),
    el("td", {}, el("span", { class: "cat-pill" + (t.category ? "" : " none") }, catLabel(t.category))),
    el("td", { class: "col-actions" }, el("div", { class: "row-actions" }, speakButton(t.term, "icon-btn"), editBtn, delBtn)),
  );
}

function startEdit(t) {
  state.editingId = t.id;
  state.editDraft = { term: t.term, definition: t.definition, category: t.category };
  state.focusEdit = true;
  renderTable();
}

function editRow(t) {
  const d = state.editDraft;
  const term = el("input", { value: d.term, "aria-label": "Italian", lang: "it" });
  const def = el("input", { value: d.definition, "aria-label": "English" });
  const cat = el("input", { value: d.category, list: "cat-options", placeholder: UNCATEGORIZED, "aria-label": "Category" });
  term.addEventListener("input", () => { d.term = term.value; });
  def.addEventListener("input", () => { d.definition = def.value; });
  cat.addEventListener("input", () => { d.category = cat.value; });
  const save = async () => {
    try {
      await api("/api/terms/update", { items: [{ ...ref(t), term: term.value, definition: def.value, category: cat.value }] });
      toast(`Saved “${term.value.trim()}”.`);
    } catch { /* toast already shown */ }
  };
  const cancel = () => { state.editingId = null; state.editDraft = null; renderTable(); };
  for (const input of [term, def, cat]) {
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); save(); }
      if (e.key === "Escape") { e.preventDefault(); cancel(); }
    });
  }
  if (state.focusEdit) {
    state.focusEdit = false;
    queueMicrotask(() => term.focus());
  }
  return el("tr", { class: "editing" },
    el("td"),
    el("td", {}, term),
    el("td", {}, def),
    el("td", {}, cat),
    el("td", { class: "col-actions" }, el("div", { class: "edit-actions" },
      el("button", { class: "btn primary", type: "button", onclick: save }, "Save"),
      el("button", { class: "btn", type: "button", onclick: cancel }, "Cancel"))),
  );
}

function renderTable() {
  const rows = visibleTerms();
  $("#terms-body").replaceChildren(...rows.map(termRow));
  $("#empty-table").hidden = rows.length > 0;
  $("#result-count").textContent = `${rows.length} of ${state.terms.length} terms`;

  const sel = state.selectedIds.size;
  $("#bulk-bar").hidden = sel === 0;
  $("#bulk-count").textContent = `${sel} selected`;
  const all = $("#check-all");
  const shownSelected = rows.filter((t) => state.selectedIds.has(t.id)).length;
  all.checked = rows.length > 0 && shownSelected === rows.length;
  all.indeterminate = shownSelected > 0 && shownSelected < rows.length;
}

function renderManageCategories() {
  const counts = new Map();
  for (const t of state.terms) counts.set(t.category, (counts.get(t.category) || 0) + 1);
  $("#manage-cat-list").replaceChildren(...state.categories.map((c) => {
    if (state.renamingCat === c) {
      const input = el("input", { value: c, placeholder: "Category name", "aria-label": "New category name" });
      const done = async (commit) => {
        const to = input.value.trim();
        state.renamingCat = null;
        if (!commit || !to || to === c) { renderManageCategories(); return; }
        const merging = state.categories.includes(to);
        const wasDeselected = state.deselected.delete(c);
        if (wasDeselected) state.deselected.add(to);
        try {
          await api("/api/categories/rename", { from: c, to });
          saveSelection();
          syncAddFormCategory(c, to);
          toast(merging ? `Merged “${catLabel(c)}” into “${to}”.` : `Renamed to “${to}”.`);
        } catch {
          if (wasDeselected) { state.deselected.delete(to); state.deselected.add(c); }
          renderManageCategories();
        }
      };
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); done(true); }
        if (e.key === "Escape") { e.preventDefault(); done(false); }
      });
      input.addEventListener("blur", () => { if (state.renamingCat === c) done(true); });
      queueMicrotask(() => { input.focus(); input.select(); });
      return el("li", {}, input);
    }
    const name = el("button", { class: "link name" + (c ? "" : " none"), type: "button", title: "Show these terms" }, catLabel(c));
    name.style.textAlign = "left";
    name.addEventListener("click", () => { state.filterCat = c; $("#filter-cat").value = c; renderTable(); });
    const rename = el("button", { class: "icon-btn", type: "button", title: c ? "Rename" : "Assign a category to all uncategorized terms", "aria-label": `Rename ${catLabel(c)}`, html: ICONS.edit });
    rename.addEventListener("click", () => { state.renamingCat = c; renderManageCategories(); });
    const del = c ? el("button", { class: "icon-btn del", type: "button", title: "Delete category", "aria-label": `Delete ${c}`, html: ICONS.trash }) : null;
    del?.addEventListener("click", () => deleteCategory(c, counts.get(c) || 0));
    return el("li", {}, name, el("span", { class: "count" }, counts.get(c) || 0), rename, del);
  }));
}

function renderManage() {
  renderCatOptions();
  renderTable();
  renderManageCategories();
}

// Keep the "Add a term" category field from resurrecting a renamed/deleted category.
function syncAddFormCategory(from, to) {
  const input = $("#add-form").category;
  if (input.value.trim() === from) input.value = to;
}

async function deleteTerms(terms) {
  const sorted = terms.slice().sort((a, b) => a.id - b.id);
  const restore = sorted.map((t) => ({ term: t.term, definition: t.definition, category: t.category, index: t.id }));
  try {
    await api("/api/terms/delete", { items: sorted.map(ref) });
  } catch { return; }
  const msg = sorted.length === 1 ? `Deleted “${sorted[0].term}”.` : `Deleted ${sorted.length} terms.`;
  toast(msg, {
    action: {
      label: "Undo",
      run: async () => {
        try { await api("/api/terms/add", { items: restore }); toast("Restored."); } catch { /* toast shown */ }
      },
    },
  });
}

async function deleteCategory(c, count) {
  const choice = await confirmDialog(
    `Delete “${c}”?`,
    `This category has ${count} term${count === 1 ? "" : "s"}. You can keep them as uncategorized, or delete them too.`,
    [
      { label: "Keep terms", value: "keep" },
      { label: `Delete ${count} term${count === 1 ? "" : "s"}`, value: "delete", class: "danger-solid" },
    ],
  );
  if (!choice) return;
  try {
    await api("/api/categories/delete", { name: c, deleteTerms: choice === "delete" });
    syncAddFormCategory(c, "");
    toast(choice === "delete" ? `Deleted “${c}” and its terms.` : `Deleted “${c}”; its terms are now uncategorized.`);
  } catch { /* toast shown */ }
}

/* ================= views & wiring ================= */

function setView(view) {
  state.view = view;
  store.set("view", view);
  for (const tab of document.querySelectorAll(".tab")) tab.setAttribute("aria-selected", String(tab.dataset.view === view));
  $("#view-study").hidden = view === "manage";
  $("#pane-cards").hidden = view !== "study";
  $("#pane-learn").hidden = view !== "learn";
  $("#view-manage").hidden = view !== "manage";
  if (view !== "learn") clearTimeout(learn.autoTimer);
  if (view === "manage") pollSync();
  renderAll();
}

function renderAll() {
  if (state.view === "study") renderStudy();
  else if (state.view === "learn") { renderCategoryPanel(); renderLearn(); }
  else renderManage();
}

function wire() {
  for (const tab of document.querySelectorAll(".tab")) tab.addEventListener("click", () => setView(tab.dataset.view));

  // ---- study ----
  $("#card").addEventListener("click", flip);
  $("#prev-btn").addEventListener("click", () => go(-1));
  $("#next-btn").addEventListener("click", () => go(1));
  $("#cat-all").addEventListener("click", () => { state.deselected.clear(); selectionChanged(); });
  $("#cat-none").addEventListener("click", () => { state.deselected = new Set(state.categories); selectionChanged(); });
  for (const b of document.querySelectorAll("[data-front]")) {
    b.addEventListener("click", () => {
      state.front = b.dataset.front;
      store.set("front", state.front);
      state.flipped = false;
      renderStudyToolbar();
      renderCard();
    });
  }
  $("#shuffle-btn").addEventListener("click", () => {
    state.shuffle = !state.shuffle;
    store.set("shuffle", state.shuffle);
    rebuildDeck();
    renderStudy();
    toast(state.shuffle ? "Cards shuffled." : "Cards back in original order.", { ms: 1800 });
  });
  $("#restart-btn").addEventListener("click", () => { rebuildDeck({ reshuffle: true }); renderStudy(); });
  $("#voice-select").addEventListener("change", (e) => {
    speech.voice = speech.voices.find((v) => v.voiceURI === e.target.value) || null;
    store.set("voice", e.target.value);
    e.target.blur();
    if (state.view === "study") speakCurrent(); else speak("Ciao! Come stai?");
  });

  const typing = (t) => t.closest && t.closest("input, select, textarea, [contenteditable]");
  document.addEventListener("keydown", (e) => {
    if (state.view !== "study" || $("#confirm-dialog").open || typing(e.target)) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === " " || (e.key === "Enter" && e.target.id === "card")) {
      e.preventDefault(); // also stops a focused button from being "clicked" by the space bar
      if (!e.repeat) flip();
    } else if (e.key === "ArrowRight") { e.preventDefault(); go(1); }
    else if (e.key === "ArrowLeft") { e.preventDefault(); go(-1); }
    else if (e.key === "p" || e.key === "P") { e.preventDefault(); speakCurrent(); }
  });
  document.addEventListener("keyup", (e) => {
    if (state.view === "study" && e.key === " " && !typing(e.target)) e.preventDefault();
  });

  // ---- learn ----
  for (const b of document.querySelectorAll("[data-answer]")) {
    b.addEventListener("click", () => {
      learn.answerWith = b.dataset.answer;
      store.set("learnAnswer", learn.answerWith);
      // Applies from the current question on (if it hasn't been answered yet).
      if (learn.s?.phase === "asking") askCurrent();
      renderLearn();
    });
  }
  $("#learn-audio-btn").addEventListener("click", () => {
    learn.autoAudio = !learn.autoAudio;
    store.set("learnAudio", learn.autoAudio);
    renderLearnToolbar();
    toast(learn.autoAudio ? "Italian will be read aloud automatically." : "Auto-play audio off.", { ms: 1800 });
  });
  $("#learn-restart-btn").addEventListener("click", async () => {
    const started = state.terms.filter((t) => isSelected(t.category) && (progress.terms.get(cardKey(t))?.status || "new") !== "new").length;
    if (started && await confirmDialog("Restart Learn?",
      `This clears your progress on ${started} selected term${started === 1 ? "" : "s"}, here and in the iPhone app.`,
      [{ label: "Restart", value: "restart", class: "danger-solid" }]) !== "restart") return;
    restartLearn();
  });

  // ---- manage ----
  $("#add-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = e.target;
    const term = f.term.value.trim();
    const definition = f.definition.value.trim();
    const category = f.category.value.trim();
    if (!term || !definition) return;
    const dup = state.terms.find((t) => t.term.toLowerCase() === term.toLowerCase());
    try {
      await api("/api/terms/add", { items: [{ term, definition, category }] });
    } catch { return; }
    f.term.value = "";
    f.definition.value = "";
    f.term.focus();
    toast(dup ? `Added “${term}” (note: there was already a card for it).` : `Added “${term}”${category ? ` to ${category}` : ""}.`);
  });
  $("#search").addEventListener("input", (e) => { state.search = e.target.value; renderTable(); });
  $("#filter-cat").addEventListener("change", (e) => { state.filterCat = e.target.value; renderTable(); });
  $("#check-all").addEventListener("change", (e) => {
    for (const t of visibleTerms()) {
      if (e.target.checked) state.selectedIds.add(t.id); else state.selectedIds.delete(t.id);
    }
    renderTable();
  });
  $("#bulk-clear").addEventListener("click", () => { state.selectedIds.clear(); renderTable(); });
  const selectedTerms = () => state.terms.filter((t) => state.selectedIds.has(t.id));
  $("#bulk-delete").addEventListener("click", () => deleteTerms(selectedTerms()));
  const bulkMove = async () => {
    const category = $("#bulk-cat").value.trim();
    const terms = selectedTerms();
    if (!terms.length) return;
    try {
      await api("/api/terms/update", { items: terms.map((t) => ({ ...ref(t), category })) });
    } catch { return; }
    $("#bulk-cat").value = "";
    toast(`Moved ${terms.length} term${terms.length === 1 ? "" : "s"} to ${catLabel(category)}.`);
  };
  $("#bulk-move").addEventListener("click", bulkMove);
  $("#bulk-cat").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); bulkMove(); } });

  if (speech.supported) {
    loadVoices();
    speechSynthesis.addEventListener?.("voiceschanged", loadVoices);
  } else {
    $("#voice-select").replaceChildren(el("option", {}, "Speech unavailable"));
    $("#voice-select").disabled = true;
  }
}

async function init() {
  wire();
  await loadProgress();
  setView(["study", "learn", "manage"].includes(state.view) ? state.view : "study");
  try {
    await api("/api/terms");
    saveSelection();
  } catch { /* toast shown */ }
  // Pick up progress made on the phone.
  setInterval(() => { if (!document.hidden) loadProgress(); }, 15000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) loadProgress({ refresh: true }); });
  window.addEventListener("focus", () => loadProgress({ refresh: true }));
}

init();
