import 'dart:async';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/features/attachments/attachment.dart';
import 'package:every_ai/features/attachments/attachment_input.dart';
import 'package:every_ai/features/attachments/image_normalize.dart';
import 'package:every_ai/features/attachments/ui/image_viewer.dart';
import 'package:every_ai/features/chat/data/chat_cleanup.dart';
import 'package:every_ai/features/chat/data/chat_repository.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('clipboard', () {
    testWidgets('Cmd+V still pastes text inside the drop zone', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'hello'};
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final controller = TextEditingController();
      final got = <XFile>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentDropZone(
              onFiles: got.addAll,
              child: TextField(controller: controller, autofocus: true),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      // The clipboard plugins answer on real async.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(got, isEmpty);
      expect(controller.text, 'hello');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    test('files on the clipboard win over an image', () async {
      final files = await clipboardFiles(
        readFiles: () async => ['/tmp/a.pdf', 'content://x/1'],
        readImage: () async => Uint8List.fromList([0x89, 0x50, 1, 2, 3, 4]),
        readText: () async => 'a.pdf',
        isFile: (p) => p == '/tmp/a.pdf',
      );
      expect(files.map((f) => f.path), ['/tmp/a.pdf']);
    });

    test('a "/" or folder path next to copied text is not a file: the text pastes', () async {
      final files = await clipboardFiles(
        readFiles: () async => ['/', '/Users'],
        readImage: () async => null,
        readText: () async => 'const x = 1;',
      );
      expect(files, isEmpty);
    });

    test('an unreadable path is reported, not thrown', () async {
      final errors = <String>[];
      final out = await readAttachments([XFile('/')], onError: errors.add);
      expect(out, isEmpty);
      expect(errors.single, contains("Couldn't read"));
    });

    test('an image becomes a named png or jpg file', () async {
      final png = await clipboardFiles(
        readFiles: () async => [],
        readImage: () async => Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0]),
        readText: () async => null,
      );
      expect((png.single.name, png.single.mimeType), ('Pasted image.png', 'image/png'));
      final jpg = await clipboardFiles(
        readFiles: () async => [],
        readImage: () async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0]),
        readText: () async => '',
      );
      expect(jpg.single.name, 'Pasted image.jpg');
    });

    test('text-only or failing clipboards give nothing', () async {
      Future<String?> none() async => null;
      expect(await clipboardFiles(readFiles: () async => [], readImage: () async => null, readText: none), isEmpty);
      expect(
        await clipboardFiles(readFiles: () async => [], readImage: () async => Uint8List(0), readText: none),
        isEmpty,
      );
      expect(
        await clipboardFiles(
          readFiles: () async => throw StateError('no'),
          readImage: () async => null,
          readText: none,
        ),
        isEmpty,
      );
    });

    test('text with a picture of itself (copied cells, rich text) pastes as text', () async {
      final files = await clipboardFiles(
        readFiles: () async => [],
        readImage: () async => Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0]),
        readText: () async => 'A1\tB1\nA2\tB2',
      );
      expect(files, isEmpty);
    });
  });

  test('blob GC keeps referenced blobs and drops the rest', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = ChatRepository(db);
    await repo.createConversationWithId(id: 'c', title: 't', model: const ModelId('m'));
    await repo.saveMessage(
      Message(
        id: 'm1',
        conversationId: 'c',
        role: Role.user,
        createdAt: DateTime(2026),
        parts: [
          AttachmentPart(
            name: 'a.png',
            mimeType: 'image/png',
            kind: AttachmentKind.image,
            size: 3,
            bytes: Uint8List(3),
          ),
        ],
      ),
    );
    await db.into(db.blobs).insert(BlobsCompanion.insert(id: 'orphan', bytes: Uint8List(2), mimeType: 'image/png'));
    expect(await collectBlobGarbage(db), 1);
    expect((await db.select(db.blobs).get()).map((b) => b.id), isNot(contains('orphan')));
    expect(await db.select(db.blobs).get(), hasLength(1));
    // Deleting the chat orphans the rest.
    await repo.delete('c');
    expect(await collectBlobGarbage(db), 1);
    expect(await db.select(db.blobs).get(), isEmpty);
  });

  group('normalizeImage', () {
    test('big photos shrink to the edge limit, small ones are kept', () async {
      final noisy = img.Image(width: 3000, height: 1500);
      var seed = 7;
      for (final p in noisy) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        p.setRgb(seed & 255, (seed >> 8) & 255, (seed >> 16) & 255);
      }
      final big = Uint8List.fromList(img.encodePng(noisy));
      expect(big.length, greaterThan(keepImageBytes));
      final out = await normalizeImage(big, 'png');
      expect(out, isNotNull);
      expect(out!.extension, 'jpg');
      expect(out.bytes.length, lessThan(big.length));
      final decoded = img.decodeJpg(out.bytes)!;
      expect((decoded.width, decoded.height), (maxImageEdge, 1024));

      expect(await normalizeImage(Uint8List(100), 'png'), isNull);
      expect(await normalizeImage(big, 'gif'), isNull);
    });

    test('a rotated portrait photo is capped on its long side as shown', () {
      // Stored landscape (3000x2000) with EXIF orientation 6: shown as a 2000x3000 portrait.
      final stored = img.Image(width: 3000, height: 2000);
      stored.exif.imageIfd.orientation = 6;
      final out = uprightWithin(stored, maxImageEdge);
      expect((out.width, out.height), (1365, maxImageEdge));
      // Already upright and small: left alone.
      final small = img.Image(width: 800, height: 600);
      expect(identical(uprightWithin(small, maxImageEdge), small), isTrue);
    });
  });

  testWidgets('the image viewer opens and closes on escape', (tester) async {
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.dark), child: child!),
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    unawaited(showImageViewer(ctx, png, label: 'pic'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
