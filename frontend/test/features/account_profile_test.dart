import 'package:every_ai/features/auth/domain/auth_state.dart';
import 'package:every_ai/features/auth/profile.dart';
import 'package:every_ai/features/settings/ui/account_menu.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads /v1/me and names the plan', () {
    final p = Profile.fromJson({'id': 'u1', 'name': 'Ada Lovelace', 'email': 'ada@example.com', 'plan': 'pro'})!;
    expect(p.displayName, 'Ada Lovelace');
    expect(p.planLabel, 'Pro plan');
    expect(Profile.fromJson({'id': 'u1'}), isNull);

    final unnamed = Profile.fromJson({'id': 'u2', 'name': ' ', 'email': 'grace@example.com', 'plan': 'free'})!;
    expect(unnamed.displayName, 'grace');
  });

  test('the account row shows the profile, else placeholders', () {
    final p = Profile.fromJson({'id': 'u1', 'name': 'Ada', 'email': 'ada@example.com', 'plan': 'max'});
    expect(accountSummary(const SignedIn(), p), ('Ada', 'Max plan'));
    expect(accountSummary(const SignedIn()), ('Account', 'Signed in'));
    expect(accountSummary(const Bypassed(), p), ('Ada', 'Max plan · Developer mode'));
    expect(accountSummary(const Bypassed()), ('Guest', 'Developer mode'));
    expect(accountSummary(const SignedOut(), p), ('Signed out', ''));
  });
}
