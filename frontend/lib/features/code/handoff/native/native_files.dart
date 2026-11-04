// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'native_files_stub.dart' if (dart.library.io) 'native_files_io.dart' as impl;

// What the native importers read from the machine: none of it is there on the web, where nothing is imported.

/// Whether this platform can import at all (it runs the CLIs).
bool get canImport => impl.canImport;

/// [path] with symbolic links resolved (as the CLIs see their folder); [path] when that fails.
Future<String> realPath(String path) => impl.realPath(path);

/// A variable of the login shell's environment (the one the CLIs run with), or null.
Future<String?> envVar(String name) => impl.envVar(name);
