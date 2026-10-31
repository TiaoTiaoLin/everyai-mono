import 'sample_project_stub.dart' if (dart.library.io) 'sample_project_io.dart' as impl;

/// Creates a small git repo (a Dart `Counter` with one test) to try the agent
/// on, and returns its path. Each call makes a fresh copy.
Future<String> createSampleProject() => impl.createSampleProject();
