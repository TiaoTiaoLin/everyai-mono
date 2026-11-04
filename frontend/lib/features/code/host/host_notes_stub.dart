// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'host.dart' show HostResult;

const HostResult _none = (text: 'Error: project notes need the desktop app.', isError: true);

HostResult hostMemory(String root, Map<String, Object?> args) => _none;

HostResult hostSavedPlans(String root, Map<String, Object?> args) => _none;

bool hostSavePlan(String root, String markdown) => false;

Future<String> hostProjectNotes(String root) async => '';
