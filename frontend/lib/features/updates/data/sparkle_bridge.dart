// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/services.dart';

/// What Sparkle reports back (`UpdaterBridge` in `macos/Runner/MainFlutterWindow.swift`).
sealed class SparkleEvent {
  const SparkleEvent();
}

/// Downloaded and verified; the install waits for [SparkleBridge.installNow] (or the next quit).
final class SparkleReady extends SparkleEvent {
  const SparkleReady(this.version);
  final String version;
}

/// The appcast had nothing newer for this build (its build number is the same or lower).
final class SparkleNone extends SparkleEvent {
  const SparkleNone();
}

final class SparkleFailed extends SparkleEvent {
  const SparkleFailed(this.message);
  final String message;
}

/// Sparkle on the signed macOS release: it downloads, checks the EdDSA and code signatures, and swaps the app.
final class SparkleBridge {
  SparkleBridge([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('everyai/updater') {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'ready':
          _events.add(SparkleReady('${(call.arguments as Map?)?['version'] ?? ''}'));
        case 'none':
          _events.add(const SparkleNone());
        case 'error':
          _events.add(SparkleFailed('${call.arguments}'));
      }
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<SparkleEvent>.broadcast();

  Stream<SparkleEvent> get events => _events.stream;

  /// True only in the release build signed by our team (local and dev builds never update).
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Check [feed] (one release's appcast) in the background; a newer build downloads quietly.
  Future<void> check(String feed) => _channel.invokeMethod<Object?>('check', {'feed': feed});

  /// Install the downloaded update now: Sparkle quits, swaps the app and relaunches it. False when nothing waits.
  Future<bool> installNow() async => await _channel.invokeMethod<bool>('installNow') ?? false;
}
