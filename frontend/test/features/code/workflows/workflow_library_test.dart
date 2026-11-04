import 'dart:io';

import 'package:every_ai/features/code/workflows/workflow_library.dart';
import 'package:every_ai/features/code/workflows/workflow_meta.dart';
import 'package:flutter_test/flutter_test.dart';

// The workflow list: bundled ones in a fixed order, then the project's own
// files, each off until its digest is trusted.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory project;

  setUp(() async => project = await Directory.systemTemp.createTemp('workflow-library'));
  tearDown(() => project.delete(recursive: true));

  void write(String name, String text) {
    File('${project.path}/.everyai/workflows/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  const mine = '''
export const meta = {
  name: 'Release notes', // a comment
  description: "Drafts the notes",
  whenToUse: `Before a release`,
  phases: [{ title: 'Draft', detail: 'one agent' },],
}
return await agent('draft')
''';

  test('bundled workflows come first in a fixed order, with their meta', () async {
    final all = await activeWorkflows(project.path, const WorkflowTrust());
    expect([for (final w in all) w.id], bundledWorkflowIds);
    expect(all.first.title, 'Ultra');
    expect(all.every((w) => w.origin == WorkflowOrigin.bundled && w.whenToUse.isNotEmpty), isTrue);
  });

  test('a project workflow is listed only while its digest is trusted', () async {
    write('Release Notes.js', mine);
    write('notes.md', 'not a workflow');
    final bundled = await loadBundledWorkflows();
    final project0 = await loadProjectWorkflows(project.path);
    final w = project0.single;
    expect(w.id, 'release-notes');
    expect(w.title, 'Release notes');
    expect(w.whenToUse, 'Before a release');
    expect(w.phases.single.title, 'Draft');

    var trust = const WorkflowTrust();
    var lib = workflowLibrary(bundled, project0, trust);
    expect(lib.active.map((w) => w.id), bundledWorkflowIds);
    expect(lib.locked.single.note, 'Came with the project. Review it and trust it to turn it on.');

    trust = trust.withTrust(w, true);
    expect(WorkflowTrust.fromJson(trust.toJson()).trustedNow(w), isTrue);
    lib = workflowLibrary(bundled, project0, trust);
    expect(lib.active.map((w) => w.id), [...bundledWorkflowIds, 'release-notes']);

    // An edit locks it again.
    write('Release Notes.js', '$mine\n// changed');
    lib = workflowLibrary(bundled, await loadProjectWorkflows(project.path), trust);
    expect(lib.active.map((w) => w.id), bundledWorkflowIds);
    expect(lib.locked.single.note, 'Changed since you trusted it. Review it again to turn it on.');
  });

  test("a project file can't replace a bundled workflow, by name or by meta id", () async {
    write('ultra.js', mine);
    write('other.js', "export const meta = { id: 'bugfix', name: 'Sneaky' }\nreturn 1");
    final project0 = await loadProjectWorkflows(project.path);
    expect(project0.map((w) => w.id), ['other', 'ultra']);
    var trust = const WorkflowTrust();
    for (final w in project0) {
      trust = trust.withTrust(w, true);
    }
    final lib = workflowLibrary(await loadBundledWorkflows(), project0, trust);
    expect(lib.active.map((w) => w.id), [...bundledWorkflowIds, 'other']);
    expect(lib.active.where((w) => w.id == 'bugfix').single.origin, WorkflowOrigin.bundled);
    expect(lib.locked.single.note, contains("Can't replace the built-in ultra workflow"));
  });

  test("a deeply nested meta is unreadable, and doesn't hide the other workflows", () async {
    // Untrusted, and read before the trust check: nesting this deep used to overflow the stack.
    write('deep.js', 'export const meta = ${'[' * 200000}');
    write('fine.js', mine);
    expect(parseWorkflowMeta('export const meta = ${'[' * 200000}'), isNull);
    expect(parseWorkflowMeta('export const meta = { a: ${'[' * 30}${']' * 30} }'), isNotNull);
    final project0 = await loadProjectWorkflows(project.path);
    expect(project0.map((w) => w.id), ['deep', 'fine']);
    expect(project0.first.title, 'deep');
    final all = await activeWorkflows(project.path, const WorkflowTrust());
    expect([for (final w in all) w.id], bundledWorkflowIds);
  });

  test('ids are normalised from the file name', () {
    expect(workflowId('My Flow!.v2'), 'my-flow-v2');
    expect(workflowId('--A_b--'), 'a_b');
  });

  test('a meta that is not a plain literal is unreadable, and the file keeps its name', () {
    expect(parseWorkflowMeta('export const meta = { name: NAME }'), isNull);
    expect(parseWorkflowMeta('export const meta = { name: `x\${y}` }'), isNull);
    expect(parseWorkflowMeta('return 1'), isNull);
    expect(parseWorkflowMeta(r"export const meta = { name: 'it\'s', n: 2, ok: true, x: null }")!.name, "it's");
  });
}
