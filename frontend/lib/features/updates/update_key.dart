// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// The Ed25519 public key release files are signed with (base64, 32 bytes). The same key is Sparkle's
/// `SUPublicEDKey` in `macos/Runner/Info.plist`; the private half is the `UPDATE_ED25519_KEY` repo secret
/// (`packaging/updates.py`). Change all three together.
const updatePublicKey = 'cZ6H/Jhi7RyDULxBkpQv6GXNPPcpiGxGAXgdV2s1uc4=';

/// Where releases are published.
const releasesRepo = 'xuckless/everyai-mono';
