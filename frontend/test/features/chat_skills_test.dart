import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/security/untrusted.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/skills/data/skill_store_io.dart' as store;
import 'package:every_ai/features/skills/domain/chat_skills.dart';
import 'package:every_ai/features/skills/domain/skill_catalog.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:flutter_test/flutter_test.dart';

InstalledSkill _installed(
  String name, {
  SkillSource source = SkillSource.library,
  String? projectId,
  String description = 'Does a thing. Use it when asked.',
  String extra = '',
  List<SkillEntry> entries = const [SkillEntry('SKILL.md', size: 10)],
  List<String> files = const [],
}) {
  final md = '---\nname: $name\ndescription: $description\n$extra---\nBody of $name.\n';
  final c = checkSkill(dirName: name, skillMd: md, entries: entries);
  return InstalledSkill(
    dirName: name,
    dir: '/skills/${source.name}/$name',
    source: source,
    projectId: projectId,
    manifest: c.manifest,
    report: c.report,
    digest: 'd',
    files: files,
  );
}

ToolCallPart _call(String tool, Map<String, Object?> args, {SkillToolResult? result}) => ToolCallPart(
  toolName: tool,
  argumentsJson: jsonEncode(args),
  callId: 'c1',
  resultJson: result == null ? null : jsonEncode({'text': result.text, 'error': result.isError}),
);

void main() {
  group('which skills Chat offers', () {
    test('script skills and runtime-bound skills need Code; instruction skills do not', () {
      expect(skillNeedsCode(_installed('plain')), isFalse);
      final scripted = _installed(
        'pdf-fill',
        entries: const [
          SkillEntry('SKILL.md', size: 10),
          SkillEntry('scripts', kind: SkillEntryKind.directory),
          SkillEntry('scripts/fill.py', size: 10),
        ],
      );
      expect(skillNeedsCode(scripted), isTrue);
      expect(skillNeedsCode(_installed('py', extra: 'compatibility: Requires Python 3.11 and pip\n')), isTrue);
      expect(skillNeedsCode(_installed('bash', extra: 'allowed-tools: Bash(git:*) Read\n')), isTrue);
      expect(skillNeedsCode(_installed('web', extra: 'compatibility: Any chat app\n')), isFalse);
    });

    test('active library and shared skills only, sorted; project skills stay in Code', () {
      final all = [
        _installed('zeta'),
        _installed('alpha', source: SkillSource.shared),
        _installed('off'),
        _installed('repo', source: SkillSource.project, projectId: 'p1'),
      ];
      const settings = SkillSettings(disabled: {'library:off'}, trusted: {'project:p1:repo': 'd'});
      expect(chatSkills(all, settings).map((s) => s.name), ['alpha', 'zeta']);
    });
  });

  group('catalog block', () {
    const a = ChatSkill(name: 'make-deck', description: 'Plan a deck.\n  Use for slides.', body: 'b', dir: '/a');
    const b = ChatSkill(name: 'fill-pdf', description: 'Fill PDF forms.', body: 'b', dir: '/b', needsCode: true);

    test('none without skills', () => expect(skillCatalogBlock(const []), isNull));

    test('sorted, one line each, needs Code marked, the same bytes whatever the order', () {
      final block = skillCatalogBlock(const [a, b])!;
      expect(block, startsWith('<skills>\n'));
      expect(block, endsWith('</skills>'));
      expect(block.indexOf('- fill-pdf (needs Code): Fill PDF forms.'), lessThan(block.indexOf('- make-deck: ')));
      expect(block, contains('- make-deck: Plan a deck. Use for slides.'));
      expect(skillCatalogBlock(const [b, a]), block);
    });

    test('capped, with a count of what was left out', () {
      final many = [
        for (var i = 0; i < 100; i++)
          ChatSkill(name: 'skill-${i.toString().padLeft(3, '0')}', description: 'x' * 400, body: '', dir: '/'),
      ];
      final block = skillCatalogBlock(many)!;
      expect(block.length, lessThanOrEqualTo(skillCatalogMax));
      expect(block, contains('more not listed'));
    });
  });

  group('load_skill and read_skill_file', () {
    final files = <String, List<int>>{
      'references/style.md': utf8.encode('# Style\nShort titles.'),
      'assets/logo.png': [0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe],
    };
    final deck = ChatSkill(
      name: 'make-deck',
      description: 'Plan a deck.',
      body: '# Make a deck\nOne idea per slide.',
      dir: '/lib/make-deck',
      files: files.keys.toList()..sort(),
    );
    const fill = ChatSkill(
      name: 'fill-pdf',
      description: 'Fill PDFs.',
      body: 'Run scripts/fill.py',
      dir: '/f',
      needsCode: true,
    );
    final reads = <String>[];
    final tools = SkillChatTools(
      [fill, deck],
      readFile: (dir, rel) async {
        reads.add('$dir/$rel');
        return files[rel];
      },
    );

    test('loads the instructions and lists the files', () async {
      final r = await tools.run(loadSkillTool, {'name': 'make-deck'});
      expect(r.isError, isFalse);
      expect(
        r.text,
        startsWith('<skill_content name="make-deck">\n# Make a deck\nOne idea per slide.\n</skill_content>'),
      );
      expect(r.text, contains('- references/style.md'));
      // Names match case-insensitively as a fallback.
      expect((await tools.run(loadSkillTool, {'name': 'Make-Deck'})).isError, isFalse);
    });

    test('unknown names list the real ones; script skills refuse with a pointer to Code', () async {
      final unknown = await tools.run(loadSkillTool, {'name': 'make-slides'});
      expect(unknown.isError, isTrue);
      expect(unknown.text, contains('fill-pdf, make-deck'));
      final script = await tools.run(loadSkillTool, {'name': 'fill-pdf'});
      expect(script.isError, isTrue);
      expect(script.text, contains('Code session'));
      expect((await tools.run(loadSkillTool, const {})).isError, isTrue);
      final none = await const SkillChatTools([], readFile: _noFile).run(loadSkillTool, {'name': 'x'});
      expect(none.text, contains('no skills turned on'));
    });

    test('a skill loaded earlier in the chat is not sent again', () async {
      final r = await tools.run(loadSkillTool, {'name': 'make-deck'}, loaded: {'make-deck'});
      expect(r.isError, isFalse);
      expect(r.text, contains('already loaded'));
      expect(r.text, isNot(contains('One idea per slide')));
    });

    test('reads listed text files only, inside the folder', () async {
      reads.clear();
      final ok = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': './references//style.md'});
      expect(ok.isError, isFalse);
      expect(
        ok.text,
        '<skill_file skill="make-deck" path="references/style.md">\n# Style\nShort titles.\n</skill_file>',
      );
      expect(reads, ['/lib/make-deck/references/style.md']);

      for (final bad in ['../other/SKILL.md', '/etc/passwd', r'references\style.md', 'C:/x', '']) {
        final r = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': bad});
        expect(r.isError, isTrue, reason: bad);
      }
      final missing = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': 'references/none.md'});
      expect(missing.text, contains('Its files: assets/logo.png, references/style.md'));
      final binary = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': 'assets/logo.png'});
      expect(binary.text, contains('not a text file'));
      expect(reads, ['/lib/make-deck/references/style.md', '/lib/make-deck/assets/logo.png']);
      // SKILL.md itself is the instructions.
      final md = await tools.run(readSkillFileTool, {'skill': 'make-deck', 'path': 'SKILL.md'});
      expect(md.text, startsWith('<skill_content'));
      final script = await tools.run(readSkillFileTool, {'skill': 'fill-pdf', 'path': 'scripts/fill.py'});
      expect(script.isError, isTrue);
    });

    test('hidden characters never reach the model', () async {
      final md = '---\nname: sly\ndescription: Does\u200B a thing.\n---\nStep one.\u202E\nStep two.\n';
      final c = checkSkill(dirName: 'sly', skillMd: md, entries: const [SkillEntry('SKILL.md', size: 10)]);
      final skill = ChatSkill.of(
        InstalledSkill(
          dirName: 'sly',
          dir: '/lib/sly',
          source: SkillSource.library,
          manifest: c.manifest,
          report: c.report,
          digest: 'd',
          files: const ['references/a.md'],
        ),
      );
      final hidden = SkillChatTools([skill], readFile: (dir, rel) async => utf8.encode('Read this.\nThen\u200B that.'));
      final load = await hidden.run(loadSkillTool, {'name': 'sly'});
      expect(load.text, contains('Step one.\nStep two.'));
      expect(skill.description, 'Does a thing.');
      expect(hiddenIn(load.text), isEmpty);
      final read = await hidden.run(readSkillFileTool, {'skill': 'sly', 'path': 'references/a.md'});
      expect(
        read.text,
        '<skill_file skill="sly" path="references/a.md">\nRead this.\nThen that.\n</skill_file>\n'
        '[Hidden characters removed (zero-width characters) on line 2.]',
      );
      // Still recognised as a skill read in later turns.
      expect(skillCallNote(_call(readSkillFileTool, const {}, result: read)), read.text);
    });

    test('normalizeSkillPath', () {
      expect(normalizeSkillPath(' a/./b.md '), 'a/b.md');
      expect(normalizeSkillPath('a/../b.md'), isNull);
      expect(normalizeSkillPath('/a'), isNull);
    });
  });

  group('history', () {
    const loaded = (text: '<skill_content name="make-deck">\nBody\n</skill_content>', isError: false);

    test('loaded skills are found by name; failed loads and "already loaded" do not count', () {
      final calls = [
        _call(loadSkillTool, {'name': 'make-deck'}, result: loaded),
        _call(loadSkillTool, {'name': 'other'}, result: (text: 'Error: no skill', isError: true)),
        _call(loadSkillTool, {'name': 'again'}, result: (text: 'The skill "again" is already loaded', isError: false)),
        _call(loadSkillTool, {'name': 'pending'}),
      ];
      expect(loadedSkillsIn(calls), {'make-deck'});
    });

    test('later turns get the skill text back', () {
      final m = Message(
        id: 'm1',
        conversationId: 'c',
        role: Role.assistant,
        parts: [
          _call(loadSkillTool, {'name': 'make-deck'}, result: loaded),
          _call(readSkillFileTool, {'skill': 'make-deck', 'path': 'x'}, result: (text: 'Error: nope', isError: true)),
          const TextPart('Here is the deck.'),
        ],
        createdAt: DateTime(2026),
      );
      expect(toolOutputsByMessage([m])['m1'], contains('<skill_content name="make-deck">\nBody\n</skill_content>'));
      expect(toolOutputsByMessage([m])['m1'], isNot(contains('nope')));
    });

    test('the chip says what happened', () {
      final d = describeSkillCall(_call(loadSkillTool, {'name': 'make-deck'}), pending: false, failed: false);
      expect((d.label, d.detail), ('Used a skill', 'make-deck'));
      final f = describeSkillCall(
        _call(readSkillFileTool, {'skill': 'make-deck', 'path': 'a.md'}),
        pending: true,
        failed: false,
      );
      expect((f.label, f.detail), ('Reading a skill file…', 'make-deck/a.md'));
    });
  });

  group('reading from disk', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('chat_skills'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('files inside the folder only, no links out, size-capped', () async {
      final dir = Directory('${tmp.path}/deck')..createSync();
      File('${dir.path}/SKILL.md').writeAsStringSync('---\nname: deck\ndescription: d\n---\nBody\n');
      Directory('${dir.path}/references').createSync();
      File('${dir.path}/references/a.md').writeAsStringSync('hello');
      File('${tmp.path}/secret.txt').writeAsStringSync('secret');
      Link('${dir.path}/references/out.md').createSync('${tmp.path}/secret.txt');

      expect(utf8.decode((await store.readFile(dir.path, 'references/a.md', 1024))!), 'hello');
      expect(await store.readFile(dir.path, 'references/out.md', 1024), isNull);
      expect(await store.readFile(dir.path, '../secret.txt', 1024), isNull);
      expect(await store.readFile(dir.path, 'references/a.md', 2), isNull);

      final scanned = await store.scan((library: tmp.path, shared: null, projects: const []));
      final deck = scanned.singleWhere((s) => s.dirName == 'deck');
      expect(deck.files, ['references/a.md']);
    });
  });
}

Future<List<int>?> _noFile(String dir, String rel) async => null;
