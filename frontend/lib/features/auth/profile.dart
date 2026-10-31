import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'auth_providers.dart';

/// Who is signed in (`GET /v1/me`).
final class Profile {
  const Profile({required this.id, required this.name, required this.email, required this.plan});

  static Profile? fromJson(Map<String, Object?> json) => switch (json) {
    {'id': final String id, 'name': final String name, 'email': final String email, 'plan': final String plan} =>
      Profile(id: id, name: name.trim(), email: email.trim(), plan: plan),
    _ => null,
  };

  final String id;
  final String name;
  final String email;

  /// The plan id: free, pro or max.
  final String plan;

  /// "Pro plan".
  String get planLabel => plan.isEmpty ? '' : '${plan[0].toUpperCase()}${plan.substring(1)} plan';

  /// The name to show: the name given at sign-up, else the email's local part.
  String get displayName => name.isNotEmpty ? name : email.split('@').first;
}

/// The signed-in user's profile; null while signed out or when the backend
/// can't be reached (the account row then shows placeholders). Refetched
/// whenever the sign-in state changes.
final profileProvider = FutureProvider<Profile?>((ref) async {
  if (!ref.watch(authProvider).canUseApp) return null;
  final authenticated = !ref.watch(appConfigProvider).devSkipAuth;
  try {
    return Profile.fromJson(await ref.watch(apiClientProvider).getJson('v1/me', authenticated: authenticated));
  } on Object {
    return null;
  }
});
