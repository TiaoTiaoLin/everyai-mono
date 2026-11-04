import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/script_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/harness/harness.dart' show ScriptCaps;
import 'package:every_ai/features/code/settings/agent_prompt.dart' show HarnessTier;
import 'package:every_ai/features/code/settings/script_caps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Real Deno (tool/fetch_deno.sh) with a fake gateway: skipped without it.
void main() {
  final deno = findDeno();
  late Directory tmp;
  late List<Map<String, Object?>> sent;

  ScriptRunner runner() {
    final gateway = GatewayClient(
      baseUrl: 'http://gw/v1',
      apiKey: 'k',
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, Object?>;
        sent.add({'path': req.url.path, ...body});
        if (req.url.path.endsWith('/aux/decide')) {
          final qs = (body['questions']! as List).cast<Map<String, Object?>>();
          return http.Response(
            jsonEncode({
              'answers': [
                for (final (n, q) in qs.indexed)
                  {'id': q['id'], 'value': q['kind'] == 'score' ? (n.isEven ? 0.9 : 0.1) : true},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'summary of ${(body['messages'] as List).length} msgs'},
              },
            ],
          }),
          200,
        );
      }),
    );
    return ScriptRunner(
      deno: deno!,
      dir: '${tmp.path}/.scripts',
      root: '${tmp.path}/repo',
      tools: ToolRunner(
        root: '${tmp.path}/repo',
        shell: SessionShell(root: '${tmp.path}/repo', sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
        gateway: gateway,
        sessionTag: 't',
      ),
      gateway: gateway,
      sessionTag: 't',
    );
  }

  test('levels: Efficient decides only, Thorough queries and scores compaction', () {
    const claude = 'anthropic/claude-sonnet-5.5';
    final efficient = scriptCapsFor(HarnessTier.efficient, claude);
    expect((efficient.enabled, efficient.queries, efficient.smartCompaction), (true, 0, false));
    final thorough = scriptCapsFor(HarnessTier.thorough, claude);
    expect((thorough.queries, thorough.depth, thorough.smartCompaction), (20, 1, true));
    // Weaker families keep plain tool calls unless the user set a level.
    expect(scriptCapsFor(HarnessTier.thorough, 'qwen/qwen3-coder').enabled, isFalse);
    expect(scriptCapsFor(HarnessTier.thorough, 'qwen/qwen3-coder', level: ScriptLevel.decide).enabled, isTrue);
    final off = scriptCapsFor(HarnessTier.thorough, claude, level: ScriptLevel.off);
    expect((off.enabled, off.smartCompaction), (false, true));
    expect(ScriptCaps.fromJson(thorough.toJson()), thorough);
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('script').absolute;
    tmp = Directory(tmp.resolveSymbolicLinksSync());
    Directory('${tmp.path}/repo/lib').createSync(recursive: true);
    File('${tmp.path}/repo/lib/a.dart').writeAsStringSync('void a() {}\n');
    File('${tmp.path}/repo/lib/b.dart').writeAsStringSync('void b() {}\n');
    File('${tmp.path}/repo/.env').writeAsStringSync('SECRET=1');
    File('${tmp.path}/outside.txt').writeAsStringSync('nope');
    sent = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a program reads project files, prints, and its calls are logged', () async {
    final budget = ScriptBudget(const ScriptCaps());
    final r = await runner().run(r'''
const files = await glob("lib/*.dart");
for (const f of files.sort()) console.log(f, (await readFile(f)).trim());
''', budget: budget);
    expect(r.exitCode, 0, reason: r.output);
    expect(r.output, contains('lib/a.dart void a() {}'));
    expect(r.output, contains('lib/b.dart void b() {}'));
    expect(r.calls.map((c) => c.fn), containsAll(['glob', 'readFile']));
  }, skip: deno == null ? 'no deno' : false);

  test('the sandbox: no files, network or env of its own; bridge refuses outside and secrets', () async {
    final r = await runner().run(r'''
for (const f of [() => Deno.readTextFile("/etc/hosts"), () => fetch("https://example.com"), async () => Deno.env.get("HOME")]) {
  try { await f(); console.log("ALLOWED"); } catch (e) { console.log("blocked", e.name); }
}
for (const p of ["../outside.txt", ".env"]) {
  try { await readFile(p); console.log("READ", p); } catch (e) { console.log("refused", p, e.message); }
}
''', budget: ScriptBudget(const ScriptCaps()));
    expect(r.output, isNot(contains('ALLOWED')));
    expect(r.output, isNot(contains('READ')));
    expect('blocked'.allMatches(r.output).length, 3);
    expect(r.output, contains('refused ../outside.txt'));
    expect(r.output, contains('refused .env'));
  }, skip: deno == null ? 'no deno' : false);

  test('decide and rank go to the decider; caps throw; llmQuery is off on the lowest tier', () async {
    final budget = ScriptBudget(const ScriptCaps(decides: 2));
    final r = await runner().run(r'''
const a = await decide("some text", [{ id: "x", kind: "bool", prompt: "?" }]);
console.log("x", a.x);
const top = await rank(["one", "two", "three"], "numbers", 2);
console.log("top", top.map((t) => t.item).join(","));
try { await decide("t", [{ id: "y", kind: "bool", prompt: "?" }]); } catch (e) { console.log("cap:", e.message); }
try { await llmQuery("hi"); } catch (e) { console.log("query:", e.message); }
''', budget: budget);
    expect(r.exitCode, 0, reason: r.output);
    expect(r.output, contains('x true'));
    expect(r.output, contains('top one,three'));
    expect(r.output, contains('cap: decide limit reached'));
    expect(r.output, contains('query: llmQuery is off'));
    expect(budget.decides, 2);
    expect(sent.where((s) => '${s['path']}'.endsWith('/aux/decide')), hasLength(2));
  }, skip: deno == null ? 'no deno' : false);

  test('llmQuery calls the cheap model with the text fenced; a thrown error fails the run', () async {
    final r = await runner().run(r'''
console.log(await llmQuery("Summarise", { text: "big text" }));
throw new Error("boom");
''', budget: ScriptBudget(const ScriptCaps(queries: 3)));
    expect(r.output, contains('summary of 2 msgs'));
    expect(r.exitCode, isNot(0));
    expect(r.output, contains('boom'));
    final q = sent.singleWhere((s) => s['model'] == scriptQueryModel);
    expect(jsonEncode(q['messages']), contains('<text>\\nbig text\\n</text>'));
  }, skip: deno == null ? 'no deno' : false);

  test('a runaway program is stopped at its timeout', () async {
    final r = await runner().run(
      'while (true) {}',
      budget: ScriptBudget(const ScriptCaps()),
      timeout: const Duration(seconds: 2),
    );
    expect(r.timedOut, isTrue);
  }, skip: deno == null ? 'no deno' : false);
}
