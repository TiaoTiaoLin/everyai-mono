// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

// A workflow is a JavaScript file shaped like this repo's
// `.claude/workflows/lane-batch.js`: `export const meta = {...}`, then a body
// that may `await` and ends with a top-level `return`. It runs in Deno with
// no permissions; its only way out is the bridge on stdin/stdout (the same
// protocol as run_script, `harness/everyai/script_io.dart`):
// - `\x1e{id, fn, args}` lines are calls the app answers with `{id, result|error}`;
// - `\x1e{fn, args}` lines (no id) are notes: phase, log, done, failed.
//
// Resume re-runs the whole script and answers agent() calls the journal
// already holds, matched by their content. A script that builds prompts from
// Date.now() or Math.random() misses the journal and runs those agents again.

/// The globals a workflow gets: `args`, `ctx`, `agent`, `parallel`,
/// `pipeline`, `phase`, `log`, `mergeFindings` (and `console.log` goes to `log`). `__ARGS__`
/// is replaced by the run's arguments; their [workflowCtxKey] entry becomes
/// `ctx` (`{runId, lead, review}`) and is taken out of `args`.
const _prelude = r'''
const __enc = new TextEncoder();
let __id = 0;
const __pending = new Map();
function __write(s) {
  const b = __enc.encode(s);
  let o = 0;
  while (o < b.length) o += Deno.stdout.writeSync(b.subarray(o));
}
function __call(fn, args) {
  const id = ++__id;
  return new Promise((resolve, reject) => {
    __pending.set(id, { resolve, reject });
    __write("\x1e" + JSON.stringify({ id, fn, args }) + "\n");
  });
}
function __note(fn, args) {
  __write("\x1e" + JSON.stringify({ fn, args }) + "\n");
}
(async () => {
  let buf = "";
  for await (const chunk of Deno.stdin.readable.pipeThrough(new TextDecoderStream())) {
    buf += chunk;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line) continue;
      const m = JSON.parse(line);
      const p = __pending.get(m.id);
      if (!p) continue;
      __pending.delete(m.id);
      if (m.error !== undefined) p.reject(new Error(m.error));
      else p.resolve(m.result);
    }
  }
})();
const __text = (a) => a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ");
const __g = globalThis;
const __a = __ARGS__;
__g.ctx = (__a && __a._ctx) || {};
if (__a) delete __a._ctx;
__g.args = __a;
__g.agent = (prompt, opts = {}) => __call("agent", { ...opts, prompt: String(prompt) });
__g.parallel = async (thunks) =>
  (await Promise.allSettled(thunks.map((t) => Promise.resolve().then(t)))).map((r) =>
    r.status === "fulfilled" ? r.value : null
  );
__g.pipeline = async (items, ...stages) =>
  (await Promise.allSettled(
    items.map((item, i) => stages.reduce((p, stage) => p.then((v) => stage(v, item, i)), Promise.resolve(item))),
  )).map((r) => (r.status === "fulfilled" ? r.value : null));
__g.phase = (title) => __note("phase", { title: String(title) });
__g.log = (...a) => __note("log", { msg: __text(a) });
console.log = __g.log;
console.info = __g.log;
console.warn = __g.log;
console.error = __g.log;
__MERGE__
try {
  const result = await (await import("./main.js")).default();
  __note("done", { result: result === undefined ? null : result });
} catch (e) {
  __note("failed", { error: e instanceof Error ? e.message : String(e), stack: e instanceof Error ? e.stack : "" });
  Deno.exit(1);
}
Deno.exit(0);
''';

/// `mergeFindings(findings)`: joins findings from different lenses that say the same thing, with no model call
/// (the outside leads EveryAI spends nothing on get it too). Two findings are one when they name the same file,
/// come from different lenses, and their summaries share most of their words (token overlap 0.6 or more, or one
/// holds the other's words). The merged finding is the most severe of them, lists every lens in `lenses`, keeps the
/// longest scenario and the other summaries in `merged_summaries`. A lens's own findings are never joined.
const mergeFindingsJs = r'''
const __stop = new Set("a an the of to in on at is are was be it its this that and or for with from by as can may not no if when which".split(" "));
const __rank = { blocker: 5, critical: 5, major: 4, high: 4, minor: 3, medium: 3, low: 2, nit: 1 };
const __stem = (w) => (w.length > 4 ? w.replace(/(ing|ed|es|s)$/, "") : w);
const __words = (f) => new Set(String(f.summary || "").toLowerCase().split(/[^a-z0-9_]+/).filter((w) => w.length > 1 && !__stop.has(w)).map(__stem));
function __same(a, b, wa, wb) {
  if (!a.file || a.file !== b.file || a.lens === b.lens) return false;
  let both = 0;
  for (const w of wa) if (wb.has(w)) both++;
  const small = Math.min(wa.size, wb.size);
  if (!small) return false;
  if (both / (wa.size + wb.size - both) >= 0.6) return true;
  return small >= 3 && both === small;
}
__g.mergeFindings = (findings) => {
  const list = Array.isArray(findings) ? findings : [];
  const words = list.map(__words);
  const root = list.map((_, i) => i);
  const find = (i) => (root[i] === i ? i : (root[i] = find(root[i])));
  for (let i = 0; i < list.length; i++) {
    for (let j = i + 1; j < list.length; j++) {
      const ri = find(i);
      const rj = find(j);
      if (ri === rj || !__same(list[i], list[j], words[i], words[j])) continue;
      // A group never holds two findings of one lens, so a third finding can't chain two of them together.
      const lensesOf = (r) => new Set(list.filter((_, k) => find(k) === r).map((f) => f.lens));
      const seen = lensesOf(ri);
      if ([...lensesOf(rj)].some((l) => seen.has(l))) continue;
      root[rj] = ri;
    }
  }
  const groups = new Map();
  list.forEach((f, i) => {
    const r = find(i);
    if (!groups.has(r)) groups.set(r, []);
    groups.get(r).push(f);
  });
  return [...groups.values()].map((g) => {
    if (g.length === 1) return g[0];
    const base = g.reduce((best, f) => ((__rank[f.severity] || 0) > (__rank[best.severity] || 0) ? f : best), g[0]);
    const longest = (k) => g.map((f) => f[k]).filter((v) => typeof v === "string").sort((x, y) => y.length - x.length)[0];
    const merged = { ...base, lenses: [...new Set(g.map((f) => f.lens).filter(Boolean))], merged_from: g.length };
    for (const k of ["failure_scenario", "exploit"]) if (longest(k) !== undefined) merged[k] = longest(k);
    const others = g.filter((f) => f !== base).map((f) => f.summary).filter(Boolean);
    if (others.length) merged.merged_summaries = others;
    return merged;
  });
};
''';

/// The key of the run's arguments the app fills with what the script may
/// know about its session (`ctx`), so it is journalled with them.
const workflowCtxKey = '_ctx';

/// The prelude with [args] in place.
String workflowPrelude(Map<String, Object?> args) =>
    // The marker goes first: the arguments are user text and may hold the marker's name.
    _prelude.replaceFirst('__MERGE__', mergeFindingsJs).replaceFirst('__ARGS__', jsonEncode(args));

/// [source] as a module whose default export runs it: top-level `export`s
/// become plain declarations and the body goes inside an async function, so a
/// top-level `return` (the workflow's result) works.
String workflowModule(String source) {
  final body = source.replaceAll(RegExp(r'^export\s+(?=(const|let|var|async|function|class)\b)', multiLine: true), '');
  return 'export default async function () {\n$body\n}\n';
}
