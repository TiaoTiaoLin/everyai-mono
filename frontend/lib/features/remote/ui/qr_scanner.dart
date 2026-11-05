import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/every_theme.dart';
import '../domain/remote_protocol.dart';

/// The camera view that reads a host's pairing QR code. [onScanned] gets the
/// first payload that parses as a pairing (once).
class QrScanner extends StatefulWidget {
  const QrScanner({super.key, required this.onScanned});

  final ValueChanged<String> onScanned;

  @override
  State<QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<QrScanner> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null && PairingPayload.parse(raw) != null) {
        _done = true;
        widget.onScanned(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MobileScanner(
      controller: _controller,
      onDetect: _detect,
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            "The camera isn't available (${error.errorCode.name}). Type the code instead.",
            textAlign: TextAlign.center,
            style: theme.type.body.tint(theme.textMuted),
          ),
        ),
      ),
    );
  }
}
