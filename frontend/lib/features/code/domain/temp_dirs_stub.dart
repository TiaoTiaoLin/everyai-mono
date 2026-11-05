// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// No temp folders off the native platforms.
List<String> systemTempDirs() => const [];

/// Nothing on disk to look at.
bool isSymlink(String path) => false;
