#!/usr/bin/env python3
"""Minimal App Store Connect API client (stdlib + the openssl CLI, no pip packages).

Usage: asc.py METHOD PATH [JSON_BODY]
  asc.py GET '/v1/bundleIds?filter[identifier]=dev.alidirect.everyai'
Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the AuthKey_*.p8). Prints the JSON reply.
Used to register the bundle id and create/renew the Developer ID provisioning profile.
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    # ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } -> r||s, 32 bytes each.
    def read_int(buf, i):
        assert buf[i] == 0x02
        n = buf[i + 1]
        return int.from_bytes(buf[i + 2 : i + 2 + n], "big"), i + 2 + n

    i = 2 if der[1] < 0x80 else 3
    r, i = read_int(der, i)
    s, _ = read_int(der, i)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def token() -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(claims).encode())}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
        input=signing_input.encode(), capture_output=True, check=True,
    ).stdout
    return f"{signing_input}.{b64(der_to_raw(der))}"


def main() -> int:
    method, path = sys.argv[1], sys.argv[2]
    body = sys.argv[3].encode() if len(sys.argv) > 3 else None
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path, data=body, method=method,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            sys.stdout.write(resp.read().decode() or "{}")
            return 0
    except urllib.error.HTTPError as e:
        sys.stdout.write(e.read().decode())
        return 1


if __name__ == "__main__":
    sys.exit(main())
