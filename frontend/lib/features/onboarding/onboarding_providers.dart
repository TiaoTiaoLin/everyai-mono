import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/version.dart';
import '../../core/preferences.dart';

/// Whether the user went through the pre-alpha entry screen for this build.
/// Stored per version: a new build asks again.
final onboardingAcceptedProvider = NotifierProvider<OnboardingAccepted, bool>(OnboardingAccepted.new);

final class OnboardingAccepted extends Notifier<bool> {
  static const key = 'onboarding.accepted';

  @override
  bool build() => ref.watch(preferencesProvider)[key] == appVersion;

  void accept() {
    ref.read(preferencesProvider)[key] = appVersion;
    state = true;
  }
}
