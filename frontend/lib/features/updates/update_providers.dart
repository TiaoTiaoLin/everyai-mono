// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// In-app updates without a reinstall. Each launch (and "Check now") asks GitHub for the newest release the channel
// allows; then, by how the app was installed:
//   macOS release (DMG, Homebrew)  Sparkle downloads and verifies it quietly; "Restart to update" installs it
//   Linux AppImage                 downloads beside itself, checks the signed SHA256SUMS, replaces its file
//   Linux .deb                     can't replace itself (root): offers the .deb download
//   Microsoft Store, dev builds    nothing (the Store updates its own installs)

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/config/version.dart';
import '../../core/preferences.dart';
import 'data/install.dart';
import 'data/sparkle_bridge.dart';
import 'domain/releases.dart';
import 'update_key.dart';

/// Preferences key: offer GitHub pre-releases too ('1'), not only the latest release.
const prereleasesPref = 'updates.prereleases';

enum UpdatePhase {
  /// Not checked yet, or this install doesn't update in the app.
  idle,
  checking,
  upToDate,

  /// Fetching (and verifying) the new version.
  downloading,

  /// Downloaded and verified: restart to use it.
  ready,

  /// A new version this install can't apply itself (the .deb, a release without our update files).
  manual,
  failed,
}

@immutable
final class UpdateState {
  const UpdateState({
    this.kind = InstallKind.none,
    this.phase = UpdatePhase.idle,
    this.release,
    this.progress,
    this.error,
    this.dismissed = false,
    this.checkedAt,
  });

  final InstallKind kind;
  final UpdatePhase phase;
  final Release? release;

  /// 0–1 while downloading, when the size is known.
  final double? progress;
  final String? error;

  /// "Later": the banner stays hidden until the next launch (Settings → About still shows it).
  final bool dismissed;
  final DateTime? checkedAt;

  /// Whether this install updates (or offers updates) at all.
  bool get supported => kind != InstallKind.none;

  /// The banner shows a ready or manual update the user hasn't put off.
  bool get showBanner => !dismissed && (phase == UpdatePhase.ready || phase == UpdatePhase.manual);

  UpdateState copyWith({
    InstallKind? kind,
    UpdatePhase? phase,
    Release? release,
    double? progress,
    String? error,
    bool? dismissed,
    DateTime? checkedAt,
    bool clearProgress = false,
  }) => UpdateState(
    kind: kind ?? this.kind,
    phase: phase ?? this.phase,
    release: release ?? this.release,
    progress: clearProgress ? null : progress ?? this.progress,
    error: phase == null || phase == UpdatePhase.failed ? error ?? this.error : error,
    dismissed: dismissed ?? this.dismissed,
    checkedAt: checkedAt ?? this.checkedAt,
  );
}

/// What the controller talks to; tests swap it.
final class UpdateEnv {
  UpdateEnv({
    required this.detect,
    required this.client,
    required this.current,
    SparkleBridge? sparkle,
    this.stage = stageAppImage,
    this.restartImage = restartAppImage,
    this.launchCheckAfter,
    String? releasesApi,
  }) : releasesApi = releasesApi ?? 'https://api.github.com/repos/$releasesRepo/releases',
       _sparkle = sparkle; // ignore: prefer_initializing_formals

  final Future<InstallKind> Function(SparkleBridge sparkle) detect;
  final http.Client Function() client;
  final ReleaseVersion current;
  final Future<void> Function(Release, {required http.Client client, void Function(double)? onProgress}) stage;
  final Future<void> Function() restartImage;

  /// GitHub's releases endpoint for the repo (`/latest` is appended for the stable channel).
  final String releasesApi;

  /// The check each launch makes, this long after start; null makes none (tests).
  final Duration? launchCheckAfter;
  SparkleBridge? _sparkle;
  SparkleBridge get sparkle => _sparkle ??= SparkleBridge();

  /// The real one: release builds only (a `flutter run` never updates itself).
  static UpdateEnv real() => UpdateEnv(
    detect: (sparkle) async {
      if (kIsWeb || !kReleaseMode) return InstallKind.none;
      if (isMacOS) return await sparkle.available() ? InstallKind.sparkle : InstallKind.none;
      return linuxInstallKind();
    },
    client: http.Client.new,
    current: ReleaseVersion.tryParse(appVersion)!,
    // Debug and profile builds never update: no launch check (and no timer in widget tests).
    launchCheckAfter: kReleaseMode ? const Duration(seconds: 3) : null,
    releasesApi: releasesApiOverride,
  );
}

final updateEnvProvider = Provider<UpdateEnv>((ref) => UpdateEnv.real());

final updateProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

final class UpdateController extends Notifier<UpdateState> {
  StreamSubscription<SparkleEvent>? _sparkleEvents;
  Future<void>? _running;

  UpdateEnv get _env => ref.read(updateEnvProvider);

  @override
  UpdateState build() {
    ref.onDispose(() => _sparkleEvents?.cancel());
    // Once per launch, after the first frame's work.
    if (_env.launchCheckAfter case final delay?) {
      final timer = Timer(delay, () => ref.mounted ? check() : null);
      ref.onDispose(timer.cancel);
    }
    return const UpdateState();
  }

  bool get prereleases => ref.read(preferencesProvider)[prereleasesPref] == '1';

  Future<void> setPrereleases(bool on) async {
    ref.read(preferencesProvider)[prereleasesPref] = on ? '1' : null;
    await check();
  }

  /// Looks for a newer release and, where the install can, fetches it. One check at a time; a finished download
  /// isn't fetched again.
  Future<void> check() => _running ??= _check().whenComplete(() => _running = null);

  Future<void> _check() async {
    if (state.phase == UpdatePhase.ready || state.phase == UpdatePhase.downloading) return;
    final env = _env;
    final kind = state.kind == InstallKind.none ? await env.detect(env.sparkle) : state.kind;
    if (!ref.mounted) return;
    if (kind == InstallKind.none) {
      state = state.copyWith(kind: kind, phase: UpdatePhase.idle);
      return;
    }
    state = state.copyWith(kind: kind, phase: UpdatePhase.checking);
    final client = env.client();
    try {
      final release = pickUpdate(await _releases(client), env.current, prereleases: prereleases);
      if (!ref.mounted) return;
      if (release == null) {
        state = state.copyWith(phase: UpdatePhase.upToDate, checkedAt: DateTime.now());
        return;
      }
      state = state.copyWith(release: release, checkedAt: DateTime.now());
      switch (kind) {
        case InstallKind.sparkle when release.appcast != null:
          _listenSparkle(env.sparkle);
          state = state.copyWith(phase: UpdatePhase.downloading, clearProgress: true);
          await env.sparkle.check(release.appcast!.url);
        case InstallKind.appImage when release.appImage != null && release.checksumsSignature != null:
          state = state.copyWith(phase: UpdatePhase.downloading, progress: 0);
          await env.stage(
            release,
            client: client,
            onProgress: (p) {
              if (ref.mounted) state = state.copyWith(progress: p);
            },
          );
          if (ref.mounted) state = state.copyWith(phase: UpdatePhase.ready, clearProgress: true);
        default:
          state = state.copyWith(phase: UpdatePhase.manual);
      }
    } on Object catch (e) {
      if (ref.mounted) state = state.copyWith(phase: UpdatePhase.failed, error: _message(e), clearProgress: true);
    } finally {
      // Sparkle downloads in its own process; only our client closes here.
      client.close();
    }
  }

  void _listenSparkle(SparkleBridge bridge) {
    _sparkleEvents ??= bridge.events.listen((e) {
      if (!ref.mounted) return;
      state = switch (e) {
        SparkleReady() => state.copyWith(phase: UpdatePhase.ready),
        SparkleNone() => state.copyWith(phase: UpdatePhase.upToDate),
        SparkleFailed(:final message) => state.copyWith(phase: UpdatePhase.failed, error: message),
      };
    });
  }

  /// Restart into the new version (only when it is ready).
  Future<void> restart() async {
    if (state.phase != UpdatePhase.ready) return;
    switch (state.kind) {
      case InstallKind.sparkle:
        if (!await _env.sparkle.installNow()) {
          state = state.copyWith(phase: UpdatePhase.failed, error: 'The update is no longer waiting; check again.');
        }
      case InstallKind.appImage:
        await _env.restartImage();
      case InstallKind.deb || InstallKind.none:
        break;
    }
  }

  /// Hide the banner until the next launch.
  void later() => state = state.copyWith(dismissed: true);

  /// Where the user gets the file by hand: the .deb, else the release page.
  String? get manualUrl => switch (state.kind) {
    InstallKind.deb => state.release?.deb?.url ?? state.release?.pageUrl,
    _ => state.release?.pageUrl,
  };

  Future<List<Release>> _releases(http.Client client) async {
    final headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'EveryAI-updater'};
    final api = _env.releasesApi;
    final res = await client
        .get(Uri.parse(prereleases ? '$api?per_page=30' : '$api/latest'), headers: headers)
        .timeout(const Duration(seconds: 20));
    // No published release yet.
    if (res.statusCode == 404) return const [];
    if (res.statusCode != 200) throw UpdateError("Couldn't reach GitHub (HTTP ${res.statusCode}).");
    final body = jsonDecode(res.body);
    final list = body is List ? body : [body];
    return [
      for (final r in list)
        if (r is Map<String, Object?>) ?Release.fromJson(r),
    ];
  }

  static String _message(Object e) => switch (e) {
    UpdateError(:final message) => message,
    TimeoutException() => "Couldn't reach GitHub (timed out).",
    _ => 'Update failed: $e',
  };
}
