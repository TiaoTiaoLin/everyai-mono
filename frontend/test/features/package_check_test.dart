import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/package_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// What [command] installs, as `ecosystem:name` keys.
  List<String> keys(
    String command, {
    Map<String, String> files = const {},
    Map<String, String> env = const {},
    Map<String, List<String>> dirs = const {},
  }) => installsIn(
    command,
    cwd: '/p',
    env: env,
    readFile: (path) => files[path],
    listDir: (d) => dirs[d] ?? const [],
  ).packages.map((p) => p.key).toList();

  group('installsIn', () {
    test('JavaScript managers, scoped, versioned and aliased names', () {
      expect(keys('npm install lodash'), ['npm:lodash']);
      expect(keys('npm i -D @types/node@^20 typescript@5.4'), ['npm:@types/node', 'npm:typescript']);
      expect(keys('pnpm add -g esbuild'), ['npm:esbuild']);
      expect(keys('yarn add left-pad@npm:right-pad@1'), ['npm:right-pad']);
      expect(keys('bun add Zod'), ['npm:zod']);
      expect(keys('npm install --registry https://npm.example.com foo'), ['npm:foo']);
      expect(keys('npx create-vite@latest my-app --template react'), ['npm:create-vite']);
      expect(keys('pnpm dlx degit user/repo app'), ['npm:degit']);
      expect(keys('npx -p cowsay -y cowsay hi'), ['npm:cowsay']);
    });

    test('Python: pip in its forms, uv, uvx, pipx and poetry', () {
      expect(keys("python3 -m pip install 'requests[socks]>=2'"), ['pypi:requests']);
      expect(keys('.venv/bin/python -m pip install Flask_Login==0.6'), ['pypi:flask-login']);
      expect(keys('pip3 install -U numpy pandas'), ['pypi:numpy', 'pypi:pandas']);
      expect(keys('uv pip install httpx'), ['pypi:httpx']);
      expect(keys('uv add --dev pytest'), ['pypi:pytest']);
      expect(keys('uvx ruff check .'), ['pypi:ruff']);
      expect(keys('uvx --from httpie http GET x'), ['pypi:httpie']);
      expect(keys('pipx install black'), ['pypi:black']);
      expect(keys('poetry add -G dev mypy'), ['pypi:mypy']);
      expect(keys('pip install -i https://example.com/simple x'), ['pypi:x']);
    });

    test('Rust, Ruby, Dart, Go and Homebrew', () {
      expect(keys('cargo add serde@1 --features derive,std'), ['crates:serde']);
      expect(keys('cargo install ripgrep'), ['crates:ripgrep']);
      expect(keys('cargo install --git https://github.com/a/b'), isEmpty);
      expect(keys('gem install rails -v 7.1'), ['gems:rails']);
      expect(keys('flutter pub add dev:mocktail http:^1.2.0'), ['pub:mocktail', 'pub:http']);
      expect(keys('go get github.com/spf13/cobra@v1.8.0'), ['go:github.com/spf13/cobra']);
      expect(keys('go install ./...'), isEmpty);
      final brew = installsIn('brew install wget someone/tools/thing');
      expect(brew.packages, isEmpty);
      expect(brew.notes.single, contains('someone/tools'));
    });

    test('prefixes and chains', () {
      expect(keys('cd app && npm i axios'), ['npm:axios']);
      expect(installsIn('cd app && npm i axios', cwd: '/p').dirs, ['/p/app']);
      expect(keys('sudo pip install requests'), ['pypi:requests']);
      expect(keys('sudo -u me npm i -g pnpm'), ['npm:pnpm']);
      expect(keys('CI=1 npm i ky && npm test'), ['npm:ky']);
      expect(keys('env FOO=1 pip install rich'), ['pypi:rich']);
    });

    test('commands that install nothing', () {
      for (final c in ['npm test', 'npm view lodash', 'pip list', 'pip show requests', 'cargo build', 'ls -la']) {
        expect(keys(c), isEmpty, reason: c);
      }
      expect(installsIn('npm test').runsManager, isFalse);
      expect(installsIn('cargo build && go test ./...').runsManager, isFalse);
      expect(installsIn('make setup').runsManager, isFalse);
      for (final c in ['npm ci', 'yarn', 'pnpm -r update', 'bundle', 'go mod tidy', 'uv sync', 'flutter pub get']) {
        expect(installsIn(c).runsManager, isTrue, reason: c);
      }
    });

    test('specs that are not registry names', () {
      for (final c in [
        'npm i .',
        'npm i ./dir',
        'npm i git+https://github.com/a/b.git',
        'npm i github:a/b',
        'npm i a/b',
        'npm i ./pkg.tgz',
        'pip install ./dist/x-1.0-py3-none-any.whl',
        'pip install -e .',
        'pip install git+https://github.com/a/b',
        'pip install "x @ https://example.com/x.zip"',
      ]) {
        expect(keys(c), isEmpty, reason: c);
      }
      expect(installsIn('npm i github:a/b').notes.single, contains('git or a URL'));
      expect(installsIn('pip install -e .').notes, isEmpty);
    });

    test('value flags are not taken for names', () {
      expect(keys('npm i --registry https://r.example --tag next foo'), ['npm:foo']);
      expect(keys('pip install --index-url https://x --target out six'), ['pypi:six']);
      expect(keys('gem install -s https://g.example -i out rake'), ['gems:rake']);
    });

    test('pip -r reads the file, once nested, from the folder the command ran in', () {
      final tmp = Directory.systemTemp.createTempSync('pkgcheck');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File('${tmp.path}/req.txt').writeAsStringSync('# deps\nrequests>=2  # http\n-r more.txt\nnumpy==1.26\n');
      File('${tmp.path}/more.txt').writeAsStringSync('reqests\n');
      final scan = installsIn(
        'pip install -r req.txt',
        cwd: tmp.path,
        readFile: (p) => File(p).existsSync() ? File(p).readAsStringSync() : null,
      );
      expect(scan.packages.map((p) => p.name), ['requests', 'reqests', 'numpy']);
    });

    test('a bare npm install checks package.json names the lockfile lacks', () {
      final files = {
        '/p/package.json': '{"dependencies": {"react": "^18", "reactt": "^1", "local": "file:../x"}}',
        '/p/package-lock.json': '{"packages": {"node_modules/react": {}}}',
      };
      expect(keys('npm install', files: files), ['npm:reactt']);
      expect(keys('npm ci', files: files), isEmpty);
    });

    test('only lockfiles make a name known: the model can write a manifest itself', () {
      final files = {
        '/p/package.json': '{"dependencies": {"lodahs": "1"}}',
        '/p/requirements.txt': 'Flask_Login\n',
        '/p/yarn.lock': 'left-pad@^1:\n  version "1.3.0"\n',
        '/p/poetry.lock': '[[package]]\nname = "flask_login"\n',
      };
      PackageRef one(String c) => installsIn(c, cwd: '/p', readFile: (p) => files[p]).packages.single;
      expect(one('npm i lodahs').known, isFalse);
      expect(one('npm i left-pad').known, isTrue);
      expect(one('pip install flask-login').known, isTrue);
      expect(one('pip install -r requirements.txt').known, isTrue);
      final fromFile = one('npm install');
      expect((fromFile.known, fromFile.source), (false, 'package.json'));
    });

    test('shapes the shell parser gives up on are still scanned', () {
      for (final c in [
        'npm install reactt > install.log 2>&1',
        '(cd web && npm install reactt)',
        r'cd $(git rev-parse --show-toplevel) && npm install reactt',
        'bash -c "npm install reactt"',
        "sh -lc 'cd web && npm i reactt'",
        'npm install reactt && echo ok &',
        'echo `date` && npm i reactt',
        'bash <<EOF\nnpm i reactt\nEOF',
      ]) {
        expect(keys(c), ['npm:reactt'], reason: c);
      }
      expect(keys(r'npm i $PKG > log'), isEmpty);
      expect(keys("cat > notes.md <<'EOF'\nRun pip install reqests\nEOF\nls > out"), isEmpty);
      expect(installsIn('(cd web && npm install reactt) > log', cwd: '/p').dirs, ['/p/web']);
      expect(installsIn(r'cd $(pwd)/x && npm i reactt > log', cwd: '/p').dirs, ['/p']);
      expect(installsIn('bash -c "cd web && npm i a" && npm i b', cwd: '/p').dirs, ['/p/web', '/p']);
    });

    test('flags before the subcommand, workspaces and toolchains', () {
      expect(keys('pnpm --filter web add reactt'), ['npm:reactt']);
      expect(keys('pnpm add -D -w reactt'), ['npm:reactt']);
      expect(keys('yarn workspace web add reactt'), ['npm:reactt']);
      expect(keys('npm -w web install reactt'), ['npm:reactt']);
      expect(keys('pip -q install requestss'), ['pypi:requestss']);
      expect(keys('pip --timeout 5 install six'), ['pypi:six']);
      expect(keys('cargo +nightly install ripgrp'), ['crates:ripgrp']);
      expect(keys('cargo -Z unstable-options add serde'), ['crates:serde']);
      expect(keys('go get -modfile alt.mod corp.dev/x'), ['go:corp.dev/x']);
      final prefixed = installsIn('npm --prefix web install reactt', cwd: '/p');
      expect(prefixed.packages.single.name, 'reactt');
      expect(prefixed.dirs, ['/p/web']);
      expect(keys('yarn', files: {'/p/package.json': '{"dependencies": {"reactt": "^1"}}'}), ['npm:reactt']);
    });

    test('a bare install skips the project\'s own workspace packages', () {
      final files = {
        '/p/package.json': '{"workspaces": ["packages/*", "tools"], "dependencies": {"@acme/ui": "*", "my-tool": "^1", "reactt": "1"}}',
        '/p/packages/ui/package.json': '{"name": "@acme/ui"}',
        '/p/tools/package.json': '{"name": "my-tool"}',
      };
      expect(
        keys(
          'npm install',
          files: files,
          dirs: {
            '/p/packages': ['ui'],
          },
        ),
        ['npm:reactt'],
      );
    });

    test('npx runs a command the project installed without a lookup', () {
      final bins = {
        '/p/node_modules/.bin': ['corp-gen'],
      };
      expect(keys('npx corp-gen --check', dirs: bins), isEmpty);
      expect(keys('npx create-thing', dirs: bins), ['npm:create-thing']);
      expect(keys('pnpm dlx corp-gen', dirs: bins), ['npm:corp-gen']);
    });

    test('values of flags we know and numbers are not taken for names', () {
      expect(keys('pip install --default-timeout 100 numpy'), ['pypi:numpy']);
      expect(keys('pip install --timeout 60 --retries 5 requests'), ['pypi:requests']);
      expect(keys('uv add --prerelease allow httpx'), ['pypi:httpx']);
      expect(keys('uv pip install --python-platform linux foo'), ['pypi:foo']);
      expect(keys('npm install --before 2024-01-01 x'), ['npm:x']);
      expect(keys('yarn add --network-timeout 100000 lodash'), ['npm:lodash']);
      expect(keys('npm install --some-new-flag 60000 left-pad'), ['npm:left-pad']);
    });

    test('private indexes: flags, environment and .npmrc', () {
      bool private(String c, {Map<String, String> files = const {}, Map<String, String> env = const {}}) =>
          installsIn(c, cwd: '/p', env: env, readFile: (p) => files[p]).packages.single.privateIndex;
      expect(private('npm i foo'), isFalse);
      expect(private('npm i --registry=https://r.example foo'), isTrue);
      expect(private('pip install --extra-index-url https://x foo'), isTrue);
      expect(private('pip install foo', env: {'PIP_INDEX_URL': 'https://x'}), isTrue);
      expect(private('PIP_INDEX_URL=https://x pip install foo'), isTrue);
      expect(private('npm i @acme/ui', files: {'/p/.npmrc': '@acme:registry=https://npm.acme.dev\n'}), isTrue);
      expect(private('npm i lodash', files: {'/p/.npmrc': '@acme:registry=https://npm.acme.dev\n'}), isFalse);
      const home = {'HOME': '/h'};
      expect(private('go get corp.dev/lib', env: home), isFalse);
      expect(private('go get corp.dev/lib', env: home, files: {'/h/.config/go/env': 'GOPRIVATE=corp.dev/*\n'}), isTrue);
      expect(private('pip install foo', env: home, files: {'/h/.config/uv/uv.toml': '[[index]]\nurl = "x"\n'}), isTrue);
      expect(private('pip install foo', files: {'/etc/pip.conf': '[global]\nindex-url = https://x\n'}), isTrue);
    });
  });

  group('typoTargetOf', () {
    String? typo(Ecosystem e, String n) => typoTargetOf(PackageRef(e, n));

    test('look-alikes of popular names', () {
      expect(typo(Ecosystem.pypi, 'reqests'), 'requests');
      expect(typo(Ecosystem.npm, 'lodahs'), 'lodash');
      expect(typo(Ecosystem.npm, 'expresss'), 'express');
      expect(typo(Ecosystem.npm, 'react2'), 'react');
      expect(typo(Ecosystem.npm, 'colour-name'), 'color-name');
      expect(typo(Ecosystem.npm, 'types-node'), '@types/node');
      expect(typo(Ecosystem.npm, 'dom-react'), 'react-dom');
      expect(typo(Ecosystem.pypi, 'python-dateutils'), 'python-dateutil');
      expect(typo(Ecosystem.pypi, 'beautifulsoup-4'), 'beautifulsoup4');
    });

    test('popular names, unrelated and short names', () {
      expect(typo(Ecosystem.npm, 'preact'), isNull);
      expect(typo(Ecosystem.npm, 'react-dom'), isNull);
      expect(typo(Ecosystem.pypi, 'requests'), isNull);
      expect(typo(Ecosystem.npm, 'wsx'), isNull);
      expect(typo(Ecosystem.npm, 'my-own-thing'), isNull);
      expect(typo(Ecosystem.go, 'github.com/a/b'), isNull);
    });

    test('PEP 503 names', () {
      expect(pep503('Flask_Login'), 'flask-login');
      expect(pep503('zope.interface'), 'zope-interface');
      expect(pep503('A__B--c'), 'a-b-c');
    });
  });

  group('verdictOf', () {
    final now = DateTime.utc(2026, 11, 5);
    PackageVerdict v(PackageRef p, PackageInfo? info) => verdictOf(p, info, now: now);
    const npm = Ecosystem.npm;

    test('a missing name is refused, with the likely name when there is one', () {
      final a = v(const PackageRef(Ecosystem.pypi, 'reqests'), PackageInfo.missing);
      expect(a.kind, VerdictKind.refuse);
      expect(a.text, contains('Did you mean `requests`'));
      final b = v(const PackageRef(npm, 'fastjsonfix-utils'), PackageInfo.missing);
      expect(b.kind, VerdictKind.refuse);
      expect(b.text, contains('made-up name'));
    });

    test('missing on a private index only warns', () {
      final a = v(const PackageRef(npm, 'internal-ui', privateIndex: true), PackageInfo.missing);
      expect(a.kind, VerdictKind.warn);
      expect(a.text, contains('private index'));
    });

    test('a new or little-used look-alike is refused; a popular one passes', () {
      final young = v(const PackageRef(npm, 'lodahs'), PackageInfo(created: DateTime.utc(2026, 11, 1), downloads: 0));
      expect(young.kind, VerdictKind.refuse);
      expect(young.text, contains('typo of the popular `lodash`'));
      final popular = v(const PackageRef(npm, 'expresss'), const PackageInfo(downloads: 900000));
      expect(popular.kind, VerdictKind.pass);
    });

    test('new, little-used and install scripts warn', () {
      final young = v(const PackageRef(npm, 'my-own-thing'), PackageInfo(created: DateTime.utc(2026, 10, 30)));
      expect(young.kind, VerdictKind.warn);
      expect(young.text, contains('6 days ago'));
      expect(v(const PackageRef(Ecosystem.gems, 'tiny'), const PackageInfo(downloads: 40)).kind, VerdictKind.warn);
      final script = v(const PackageRef(npm, 'my-own-thing'), const PackageInfo(downloads: 5000, installScript: true));
      expect(script.kind, VerdictKind.warn);
      expect(script.text, contains('install script'));
      final old = v(const PackageRef(npm, 'my-own-thing'), PackageInfo(created: DateTime.utc(2020), downloads: 5000));
      expect(old.kind, VerdictKind.pass);
    });

    test('a name read from a file says which file', () {
      final a = v(const PackageRef(npm, 'fastjsonfix-utils', source: 'package.json'), PackageInfo.missing);
      expect(a.text, startsWith("`fastjsonfix-utils` (listed in package.json) doesn't exist on npm."));
    });

    test('a failed lookup is unknown, a known name always passes', () {
      expect(v(const PackageRef(npm, 'lodahs'), null).kind, VerdictKind.unknown);
      expect(v(const PackageRef(npm, 'lodahs', known: true), PackageInfo.missing).kind, VerdictKind.pass);
    });
  });
}
