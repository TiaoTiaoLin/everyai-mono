import 'package:flutter/widgets.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/brand.dart';
import '../domain/model_catalog.dart';

/// Provider logo (or a monogram for vendors without one), clipped to the
/// design language's avatar shape: the Expressive cookie on Material, a
/// squircle on Apple, a circle elsewhere. EveryAI · Auto keeps its round avatar.
class ModelAvatar extends StatelessWidget {
  const ModelAvatar(this.provider, {super.key, this.size = 28});

  final ModelProvider provider;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (provider == ModelProvider.everyai) return BrandAvatar(size: size);
    final theme = EveryTheme.of(context);
    final asset = provider.asset;
    final image = asset != null
        ? Image.asset(asset, width: size, height: size, fit: BoxFit.cover)
        : _Monogram(provider, size: size);
    final clipped = switch (theme.design) {
      DesignLanguage.material => ClipPath(clipper: _PolygonClipper(MaterialShapes.cookie9Sided), child: image),
      DesignLanguage.cupertino ||
      DesignLanguage.macos => ClipRSuperellipse(borderRadius: BorderRadius.circular(size * 0.28), child: image),
      _ => ClipOval(child: image),
    };
    return Semantics(
      label: provider.label,
      image: true,
      child: SizedBox.square(dimension: size, child: clipped),
    );
  }
}

/// The vendor's initial on a color derived from its slug.
class _Monogram extends StatelessWidget {
  const _Monogram(this.provider, {required this.size});

  final ModelProvider provider;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = (provider.slug.codeUnits.fold(7, (h, c) => (h * 31 + c) & 0xffff) % 360).toDouble();
    return ColoredBox(
      color: HSLColor.fromAHSL(1, hue, 0.45, 0.42).toColor(),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: Text(
            provider.label.isEmpty ? '?' : provider.label[0].toUpperCase(),
            style: TextStyle(
              color: const Color(0xFFFFFFFF),
              fontSize: size * 0.48,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _PolygonClipper extends CustomClipper<Path> {
  const _PolygonClipper(this.polygon);

  final RoundedPolygon polygon;

  @override
  Path getClip(Size size) {
    final path = polygon.toPath();
    final bounds = path.getBounds();
    final scale = Matrix4.identity()
      ..scaleByDouble(size.width / bounds.width, size.height / bounds.height, 1, 1)
      ..translateByDouble(-bounds.left, -bounds.top, 0, 1);
    return path.transform(scale.storage);
  }

  @override
  bool shouldReclip(_PolygonClipper old) => old.polygon != polygon;
}
