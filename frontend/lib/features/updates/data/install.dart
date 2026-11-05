// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

export 'install_stub.dart' if (dart.library.io) 'install_io.dart';

/// How this copy of the app was installed, which decides how it updates.
enum InstallKind {
  /// A development, web or mobile build, or a store install (the store updates it): no checks.
  none,

  /// The signed macOS release (DMG or Homebrew): Sparkle.
  sparkle,

  /// A Linux AppImage: it replaces its own file.
  appImage,

  /// The Linux .deb under /opt/everyai: needs root, so the app only offers the download.
  deb,
}
