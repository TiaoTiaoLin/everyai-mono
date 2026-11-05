import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/domain/message.dart';
import '../../attachments/ui/image_viewer.dart';
import '../artifact_providers.dart';
import 'download_button.dart';
import 'renderers/svg_view.dart';

/// A raster image, scaled to fit.
class RasterImageView extends StatelessWidget {
  const RasterImageView({super.key, required this.bytes, this.maxHeight = 512});

  final Uint8List? bytes;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final b = bytes;
    if (b == null) return Text('[Image unavailable]', style: theme.type.body.tint(theme.textMuted));
    return MouseRegion(
      cursor: SystemMouseCursors.zoomIn,
      child: GestureDetector(
        onTap: () => showImageViewer(context, b, label: 'Generated image'),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(theme.radius),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Image.memory(b, fit: BoxFit.contain, semanticLabel: 'Generated image'),
          ),
        ),
      ),
    );
  }
}

/// A generated image in the chat. SVG ones draw like `render_svg`. Images
/// with an id are versioned artifacts: the caption says which version this
/// is, and the side panel steps through them.
class GeneratedImageView extends ConsumerWidget {
  const GeneratedImageView({super.key, required this.image, required this.conversationId});

  final ImagePart image;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final bytes = image.bytes;
    final picture = image.isSvg
        ? SvgView(svg: bytes == null ? '' : utf8.decode(bytes, allowMalformed: true), maxHeight: 512)
        : RasterImageView(bytes: bytes);
    final id = image.imageId;
    if (id == null) return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: picture);

    final artifacts = ref.watch(conversationArtifactsProvider(conversationId));
    final artifact = artifacts.where((a) => a.versions.any((v) => v.callId == id)).firstOrNull;
    final version = artifact?.versions.indexWhere((v) => v.callId == id) ?? -1;
    final visual = artifact != null && version >= 0 ? artifact.versions[version] : null;
    final caption = [
      image.isSvg ? 'Vector image' : 'Image',
      if (artifact != null && artifact.versions.length > 1) 'version ${version + 1} of ${artifact.versions.length}',
      id,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 512),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: artifact == null
                  ? null
                  : () => ref
                        .read(artifactPanelProvider(conversationId).notifier)
                        .openArtifact(artifact.id, version: version),
              child: MouseRegion(cursor: SystemMouseCursors.click, child: picture),
            ),
            Row(
              children: [
                Expanded(child: Text(caption, style: theme.type.caption.tint(theme.textMuted))),
                if (visual != null && !kIsWeb) DownloadButton(visual: visual),
                if (artifact != null)
                  AdaptiveIconButton(
                    icon: EveryIcon.openPanel,
                    tooltip: 'Open in side panel',
                    onPressed: () => ref
                        .read(artifactPanelProvider(conversationId).notifier)
                        .openArtifact(artifact.id, version: version),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
