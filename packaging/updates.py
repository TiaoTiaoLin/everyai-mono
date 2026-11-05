#!/usr/bin/env python3
# Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.
"""Update signing for EveryAI releases (one Ed25519 key for Sparkle on macOS and the Linux AppImage updater).

    updates.py keygen KEYFILE              new key: writes the private seed (base64) to KEYFILE, prints the public key
    updates.py public                      the public key of $UPDATE_ED25519_KEY
    updates.py sign FILE                   base64 Ed25519 signature of FILE's bytes (Sparkle's sparkle:edSignature)
    updates.py appcast DMG VERSION BUILD TAG REPO > appcast.xml
                                           a one-item Sparkle appcast for this release's DMG

The private key is the base64 32-byte seed in $UPDATE_ED25519_KEY (a repo secret; the owner's copy lives outside the
repo). The public key is in frontend/macos/Runner/Info.plist (SUPublicEDKey) and frontend/lib/features/updates/
update_key.dart; change all three together. Needs the `cryptography` package (pip install cryptography).
"""

import base64
import os
import sys
from datetime import datetime, timezone
from xml.sax.saxutils import escape

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def _key() -> Ed25519PrivateKey:
    seed = os.environ.get("UPDATE_ED25519_KEY", "").strip()
    if not seed:
        sys.exit("UPDATE_ED25519_KEY is not set")
    raw = base64.b64decode(seed)
    # Sparkle's older export is seed + public key (64 bytes); the seed is the first half.
    return Ed25519PrivateKey.from_private_bytes(raw[:32])


def _public(key: Ed25519PrivateKey) -> str:
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def _sign(path: str) -> str:
    with open(path, "rb") as f:
        return base64.b64encode(_key().sign(f.read())).decode()


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    if cmd == "keygen" and len(argv) == 3:
        key = Ed25519PrivateKey.generate()
        seed = key.private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
        )
        fd = os.open(argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b64encode(seed).decode() + "\n")
        print(_public(key))
    elif cmd == "public":
        print(_public(_key()))
    elif cmd == "sign" and len(argv) == 3:
        print(_sign(argv[2]))
    elif cmd == "appcast" and len(argv) == 7:
        dmg, version, build, tag, repo = argv[2:]
        name = os.path.basename(dmg)
        url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
        notes = f"https://github.com/{repo}/releases/tag/{tag}"
        date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
        print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EveryAI</title>
    <item>
      <title>EveryAI {escape(version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(notes)}</sparkle:fullReleaseNotesLink>
      <enclosure url="{escape(url)}" length="{os.path.getsize(dmg)}" type="application/octet-stream"
        sparkle:edSignature="{_sign(dmg)}"/>
    </item>
  </channel>
</rss>""")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
