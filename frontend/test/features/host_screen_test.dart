import 'package:every_ai/features/code/host/host_screen.dart';
import 'package:flutter_test/flutter_test.dart';

ScreenWindow _w(int id, int pid, String owner, {String title = '', int width = 800, int height = 600}) =>
    (id: id, pid: pid, owner: owner, title: title, width: width, height: height);

void main() {
  group('pickWindow', () {
    final windows = [
      _w(1, 10, 'Safari', title: 'News'),
      _w(2, 20, 'counter', title: 'Counter'),
      _w(3, 20, 'counter', title: 'Settings'),
      _w(4, 20, 'counter', width: 20, height: 20),
      _w(5, 30, 'Notes', title: 'Groceries'),
    ];
    bool own(ScreenWindow w) => w.pid == 20;

    test("the session's frontmost window, with how many more there are", () {
      final pick = pickWindow(windows, own: own) as OwnWindow;
      expect((pick.window.id, pick.others), (2, 1));
    });

    test('app matches the owner or the title, any case', () {
      expect((pickWindow(windows, own: own, app: 'settings') as OwnWindow).window.id, 3);
      expect((pickWindow(windows, own: own, app: 'COUNTER') as OwnWindow).window.id, 2);
    });

    test("another app's window is foreign only when app or window_id names it", () {
      expect((pickWindow(windows, own: own, app: 'notes') as ForeignWindow).window.id, 5);
      expect((pickWindow(windows, own: own, app: 'groceries') as ForeignWindow).window.id, 5);
      expect((pickWindow(windows, own: own, windowId: 1) as ForeignWindow).window.owner, 'Safari');
      expect(pickWindow(windows, own: (_) => false), isA<NoWindow>());
      expect(pickWindow(windows, own: own, app: 'mail'), isA<NoWindow>());
    });

    test('window_id picks that window; tiny ones never count', () {
      expect((pickWindow(windows, own: own, windowId: 3) as OwnWindow).window.title, 'Settings');
      expect(pickWindow(windows, own: own, windowId: 4), isA<NoWindow>());
      expect(pickWindow(windows, own: own, windowId: 99), isA<NoWindow>());
    });

    test('a granted window counts as the session\'s own', () async {
      final pick = await pickSessionWindow(
        windows,
        pids: const {},
        root: '/p',
        executableOf: (pid) async => pid == 10 ? '/p/build/app' : '/Applications/x',
        granted: (w) => w.id == 5,
        app: 'notes',
      );
      expect((pick as OwnWindow).window.id, 5);
      // Run from inside the project: its own.
      final built = await pickSessionWindow(windows, pids: const {}, root: '/p', executableOf: (pid) async => '/p/x');
      expect((built as OwnWindow).window.id, 1);
    });
  });

  group('sensitive windows', () {
    final windows = [
      _w(1, 10, '1Password', title: 'Vault'),
      _w(2, 20, 'Safari', title: 'Chase Online Banking'),
      _w(3, 30, 'counter', title: 'Checkout'),
      _w(4, 40, 'Schlüsselbundverwaltung', title: 'Login'),
      _w(5, 50, 'System Settings', title: 'Passwords'),
      _w(6, 60, 'Notes', title: 'Banking ideas'),
    ];

    test('a password manager is skipped even when granted or picked by id', () {
      final byName = pickWindow(windows, own: (_) => true, app: '1password') as NoWindow;
      expect(byName.skipped, ['1Password (a password manager)']);
      final byId = pickWindow(windows, own: (_) => true, windowId: 1) as NoWindow;
      expect(byId.skipped, ['1Password (a password manager)']);
      expect((pickWindow(windows, own: (w) => w.pid == 50, windowId: 5) as NoWindow).skipped, hasLength(1));
    });

    test("a foreign browser's banking page is skipped; the session's own checkout and a note are not", () {
      expect((pickWindow(windows, own: (_) => false, app: 'banking') as ForeignWindow).window.id, 6);
      expect((pickWindow(windows, own: (_) => false, windowId: 2) as NoWindow).skipped, [
        'Safari (looks like a banking or payment page)',
      ]);
      expect((pickWindow(windows, own: (w) => w.pid == 30, app: 'checkout') as OwnWindow).window.id, 3);
    });

    test('a keychain app is known by its bundle when its name is localized', () async {
      Future<WindowPick> pick(int id) => pickSessionWindow(
        windows,
        pids: const {},
        root: '/p',
        executableOf: (pid) async => pid == 40
            ? '/System/Applications/Utilities/Keychain Access.app/Contents/MacOS/Keychain Access'
            : '/Applications/x.app/Contents/MacOS/x',
        granted: (_) => true,
        windowId: id,
      );
      expect(((await pick(4)) as NoWindow).skipped, ['Schlüsselbundverwaltung (a password manager)']);
      expect(await pick(6), isA<OwnWindow>());
    });

    test('a granted browser window turned to a bank is skipped', () async {
      Future<WindowPick> pick({bool Function(ScreenWindow)? granted}) => pickSessionWindow(
        windows,
        pids: const {},
        root: '/p',
        executableOf: (pid) async => '/Applications/Safari.app/Contents/MacOS/Safari',
        granted: granted,
        windowId: 2,
      );
      expect(((await pick(granted: (w) => w.id == 2)) as NoWindow).skipped, [
        'Safari (looks like a banking or payment page)',
      ]);
      expect(((await pick()) as NoWindow).skipped, hasLength(1));
    });

    test('a password manager the session started is known by its bundle, whatever its name', () async {
      final pick = await pickSessionWindow(
        windows,
        pids: const {40},
        root: '/p',
        executableOf: (pid) async => pid == 40
            ? '/System/Applications/Passwords.app/Contents/MacOS/Passwords'
            : '/Applications/x.app/Contents/MacOS/x',
        windowId: 4,
      );
      expect((pick as NoWindow).skipped, ['Schlüsselbundverwaltung (a password manager)']);
    });

    test('an own window still says which named windows were skipped', () {
      final pick = pickWindow(windows, own: (w) => w.pid == 30, app: 'o') as OwnWindow;
      expect(pick.window.id, 3);
      expect(pick.skipped, [
        '1Password (a password manager)',
        'Safari (looks like a banking or payment page)',
        'System Settings (a password manager)',
      ]);
      expect(skippedText(const []), '');
    });
  });

  group('detectRunCommands', () {
    List<String> detect(Map<String, String> files, {List<String> dirs = const ['']}) =>
        detectRunCommands(exists: files.containsKey, read: (p) => files[p], os: 'macos', dirs: dirs);

    test('a Flutter pubspec runs on this desktop; a Dart one with dart run', () {
      expect(detect({'pubspec.yaml': 'name: a\ndependencies:\n  flutter:\n    sdk: flutter\n'}), [
        'flutter run -d macos',
      ]);
      expect(detect({'pubspec.yaml': 'name: a\nflutter:\n  uses-material-design: true\n'}), ['flutter run -d macos']);
      expect(detect({'pubspec.yaml': 'name: a\ndependencies:\n  args: ^2.0.0\n'}), ['dart run']);
    });

    test('package.json: dev, then start, then serve, run by the lockfile\'s package manager', () {
      String pkg(List<String> scripts) => '{"scripts": {${scripts.map((s) => '"$s": "x"').join(',')}}}';
      expect(
        detect({
          'package.json': pkg(['start', 'dev']),
        }),
        ['npm run dev'],
      );
      expect(
        detect({
          'package.json': pkg(['serve', 'start']),
        }),
        ['npm run start'],
      );
      expect(
        detect({
          'package.json': pkg(['serve']),
        }),
        ['npm run serve'],
      );
      expect(
        detect({
          'package.json': pkg(['build']),
        }),
        isEmpty,
      );
      expect(
        detect({
          'package.json': pkg(['dev']),
          'pnpm-lock.yaml': '',
        }),
        ['pnpm run dev'],
      );
      expect(
        detect({
          'package.json': pkg(['dev']),
          'yarn.lock': '',
        }),
        ['yarn dev'],
      );
      expect(
        detect({
          'package.json': pkg(['dev']),
          'bun.lockb': '',
        }),
        ['bun run dev'],
      );
      expect(detect({'package.json': 'not json'}), isEmpty);
    });

    test('cargo, go, swift and make run', () {
      expect(detect({'Cargo.toml': ''}), ['cargo run']);
      expect(detect({'go.mod': ''}), ['go run .']);
      expect(detect({'Package.swift': ''}), ['swift run']);
      expect(detect({'Makefile': 'build:\n\tcc a.c\nrun: build\n\t./a.out\n'}), ['make run']);
      expect(detect({'Makefile': 'build:\n\tcc a.c\n'}), isEmpty);
    });

    test('nothing found; a subfolder\'s command starts with cd', () {
      expect(detect({'README.md': ''}), isEmpty);
      expect(detect({'app/pubspec.yaml': 'flutter:\n', 'Cargo.toml': ''}, dirs: ['', 'app']), [
        'cargo run',
        'cd app && flutter run -d macos',
      ]);
    });

    test('a subfolder name is quoted as one word, never run', () {
      expect(detect({'My App/Cargo.toml': ''}, dirs: ['My App']), ["cd 'My App' && cargo run"]);
      expect(detect({r'web$(open -a Calculator)/go.mod': ''}, dirs: [r'web$(open -a Calculator)']), [
        r"cd 'web$(open -a Calculator)' && go run .",
      ]);
      expect(detect({"it's/go.mod": ''}, dirs: ["it's"]), [r"cd 'it'\''s' && go run ."]);
    });
  });
}
