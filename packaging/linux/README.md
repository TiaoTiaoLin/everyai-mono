# Linux packages

`package.sh` turns a `flutter build linux --release` bundle into `EveryAI-<version>-x86_64.AppImage` and
`everyai_<version>_amd64.deb` (Deno bundled next to the binary), writes `SHA256SUMS`, and signs each file with the
release key. `.github/workflows/release.yml` runs it on Ubuntu 22.04 for every `v*` tag.

Verify a download:

```sh
curl -fsSL https://raw.githubusercontent.com/xuckless/everyai-mono/main/packaging/linux/everyai-release-key.asc | gpg --import
gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
```

Release key: `EveryAI Release Signing`, ed25519, fingerprint `970F F427 42E8 F2DB 941C  C2D3 FFA1 060B BEB3 84CE`,
expires 2029-11-04.
