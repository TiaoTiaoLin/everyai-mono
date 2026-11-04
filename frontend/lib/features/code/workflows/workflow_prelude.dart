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
/// `pipeline`, `phase`, `log` (and `console.log` goes to `log`). `__ARGS__`
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
try {
  const result = await (await import("./main.js")).default();
  __note("done", { result: result === undefined ? null : result });
} catch (e) {
  __note("failed", { error: e instanceof Error ? e.message : String(e), stack: e instanceof Error ? e.stack : "" });
  Deno.exit(1);
}
Deno.exit(0);
''';

/// The key of the run's arguments the app fills with what the script may
/// know about its session (`ctx`), so it is journalled with them.
const workflowCtxKey = '_ctx';

/// The prelude with [args] in place.
String workflowPrelude(Map<String, Object?> args) => _prelude.replaceFirst('__ARGS__', jsonEncode(args));

/// [source] as a module whose default export runs it: top-level `export`s
/// become plain declarations and the body goes inside an async function, so a
/// top-level `return` (the workflow's result) works.
String workflowModule(String source) {
  final body = source.replaceAll(RegExp(r'^export\s+(?=(const|let|var|async|function|class)\b)', multiLine: true), '');
  return 'export default async function () {\n$body\n}\n';
}
