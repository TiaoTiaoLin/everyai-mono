import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:uuid/uuid.dart';

import 'attachment.dart';
import 'image_normalize.dart';
import 'local_file.dart';

/// Opens the system file picker. With [allowed], only those kinds can be
/// picked (the rest are greyed out in the native dialog); text and code are
/// always allowed. Without it, any file.
Future<List<XFile>> pickAttachmentFiles({Set<AttachmentKind>? allowed}) {
  if (allowed == null) return openFiles();
  return openFiles(
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Text and code', extensions: textExtensions, uniformTypeIdentifiers: ['public.text']),
      if (allowed.contains(AttachmentKind.image))
        const XTypeGroup(label: 'Images', extensions: imageExtensions, uniformTypeIdentifiers: ['public.image']),
      if (allowed.contains(AttachmentKind.pdf))
        const XTypeGroup(label: 'PDFs', extensions: pdfExtensions, uniformTypeIdentifiers: ['com.adobe.pdf']),
      if (allowed.contains(AttachmentKind.audio))
        const XTypeGroup(label: 'Audio', extensions: audioExtensions, uniformTypeIdentifiers: ['public.audio']),
    ],
  );
}

String _extOf(String name) => name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';

/// Reads picked or dropped files. Files over a size limit (per kind, or the
/// message total on top of [alreadyBytes]) are left out and reported to
/// [onError]; nothing is truncated. With [shrinkImages], big photos are scaled down first (see [normalizeImage]);
/// the Code agent gets the originals.
Future<List<Attachment>> readAttachments(
  Iterable<XFile> files, {
  int alreadyBytes = 0,
  required void Function(String message) onError,
  bool shrinkImages = false,
}) async {
  final out = <Attachment>[];
  var total = alreadyBytes;
  for (final f in files) {
    Uint8List bytes;
    try {
      bytes = await f.readAsBytes();
    } on Object {
      // A folder, a vanished file or one we may not read.
      onError("Couldn't read ${f.name.isEmpty ? f.path : f.name}.");
      continue;
    }
    var name = f.name;
    var mime = f.mimeType;
    if (shrinkImages && imageExtensions.contains(_extOf(name))) {
      final small = await normalizeImage(bytes, _extOf(name));
      if (small != null) {
        bytes = small.bytes;
        name = '${name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name}.${small.extension}';
        mime = null;
      }
    }
    final (:attachment, :error) = Attachment.from(id: const Uuid().v4(), name: name, bytes: bytes, mime: mime);
    if (error != null) {
      onError(error);
      continue;
    }
    if (total + bytes.length > maxMessageBytes) {
      onError('${f.name} would take this message past ${formatBytes(maxMessageBytes)}.');
      continue;
    }
    total += bytes.length;
    out.add(attachment!);
  }
  return out;
}

/// Files or an image on the system clipboard, as files ready for [readAttachments]. Empty when the clipboard
/// holds text (or nothing): copied cells or rich text often carry a picture of themselves too, and the text is what
/// was meant. Copied files still win, though Finder puts their names on the clipboard as text. The readers are
/// injectable for tests.
Future<List<XFile>> clipboardFiles({
  Future<List<String>> Function()? readFiles,
  Future<Uint8List?> Function()? readImage,
  Future<String?> Function()? readText,
  bool Function(String path)? isFile,
}) async {
  try {
    final paths = await (readFiles ?? (kIsWeb ? () async => <String>[] : Pasteboard.files))();
    // Android hands out content URIs, which dart:io can't open; some Mac apps put `/` or a folder there along
    // with copied text. Only real files count, or the text would never paste.
    final real = [
      for (final p in paths)
        if (!p.contains('://') && (isFile ?? isRegularFile)(p)) p,
    ];
    if (real.isNotEmpty) return [for (final p in real) XFile(p)];
    final text = await (readText ?? _clipboardText)();
    if (text != null && text.trim().isNotEmpty) return const [];
    final raw = await (readImage ?? (() => Pasteboard.image))();
    if (raw == null || raw.isEmpty) return const [];
    // Windows: the plugin saves the clipboard bitmap as a BMP, which models don't take; re-encode it as PNG.
    final bmp = raw.length > 2 && raw[0] == 0x42 && raw[1] == 0x4D;
    final image = bmp ? await compute<Uint8List, Uint8List?>(bmpToPng, raw) : raw;
    if (image == null) return const [];
    final png = image.length > 4 && image[0] == 0x89 && image[1] == 0x50;
    final jpeg = image.length > 3 && image[0] == 0xFF && image[1] == 0xD8;
    final (ext, mime) = png ? ('png', 'image/png') : (jpeg ? ('jpg', 'image/jpeg') : ('tiff', 'image/tiff'));
    // Unknown formats are not images the models accept; leave them to the text paste.
    if (!png && !jpeg) return const [];
    return [XFile.fromData(image, name: 'Pasted image.$ext', path: 'Pasted image.$ext', mimeType: mime)];
  } catch (_) {
    return const [];
  }
}

/// A BMP as PNG, or null when it doesn't decode. The Windows clipboard bitmap is XRGB (its fourth byte is not
/// alpha and often 0), so the result keeps only the colour channels, or the picture would come out transparent.
@visibleForTesting
Uint8List? bmpToPng(Uint8List bmp) {
  final decoded = img.decodeBmp(bmp);
  if (decoded == null) return null;
  return img.encodePng(decoded.numChannels == 3 ? decoded : decoded.convert(numChannels: 3));
}

Future<String?> _clipboardText() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;

/// Takes over paste (Cmd/Ctrl+V and the Edit menu) in the text field below it: files and images on the clipboard
/// become attachments, anything else pastes as text as before.
class _PasteAction extends Action<PasteTextIntent> {
  _PasteAction(this.onFiles);

  final ValueChanged<List<XFile>> onFiles;

  @override
  Future<void> invoke(PasteTextIntent intent) async {
    // The text field's own paste action is only set while invoke runs synchronously; take it before awaiting.
    final textPaste = callingAction;
    final files = await clipboardFiles();
    if (files.isNotEmpty) {
      onFiles(files);
    } else {
      textPaste?.invoke(intent);
    }
  }
}

/// Accepts files dragged onto [child], highlighting it while they hover, and files or images pasted into a text
/// field inside it.
class AttachmentDropZone extends StatefulWidget {
  const AttachmentDropZone({super.key, required this.onFiles, required this.child, this.enabled = true});

  final ValueChanged<List<XFile>> onFiles;
  final Widget child;
  final bool enabled;

  @override
  State<AttachmentDropZone> createState() => _AttachmentDropZoneState();
}

class _AttachmentDropZoneState extends State<AttachmentDropZone> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        if (details.files.isNotEmpty) widget.onFiles(details.files);
      },
      child: Actions(
        actions: {if (widget.enabled) PasteTextIntent: _PasteAction(widget.onFiles)},
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _hovering ? 0.7 : 1,
          child: widget.child,
        ),
      ),
    );
  }
}
