// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:http/http.dart' as http;

import '../domain/releases.dart';
import 'install.dart';

/// Web: no updater (the page is the latest version).
InstallKind linuxInstallKind() => InstallKind.none;

bool get isMacOS => false;

String? get releasesApiOverride => null;

Future<void> stageAppImage(Release release, {required http.Client client, void Function(double)? onProgress}) =>
    throw UnsupportedError('no AppImage here');

Future<void> restartAppImage() => throw UnsupportedError('no AppImage here');
