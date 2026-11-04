# Dev deployment (0.1.0-dev-nonsigned)

The dev backend runs on the `ttt-server` VM (GCP project `ttt-ultimate-b7097a`, us-east1-b) as a container,
at `https://everyai.136-108-68-64.sslip.io:8443`.

- **No sign-in, no server keys.** `DEV_AUTH=true`: every request is the dev user. No `OPENROUTER_API_KEY` or
  `ANTHROPIC_API_KEY`: users add their own keys in the app (BYOK), or use local models and the local harness.
  The image holds only the binary (`deploy.sh` sends only the binary), so no `.env` reaches it.
- **Rate limit:** `RATE_LIMIT_PER_MINUTE` (600) per client address across the API, plus the tighter `/v1/auth`
  and pairing limits.
- **TLS:** Anole serves HTTPS on 8443 itself. Caddy (the ttt stack, which owns 80/443) obtains and renews the
  certificate for the hostname through a site block that serves nothing else; the container mounts Caddy's
  certificate folder read-only, and `everyai-cert-reload.timer` sends SIGHUP daily.
- **Data:** SQLite in the `everyai_data` volume.

## Deploy or update

```sh
backend-exp/deploy/deploy.sh   # cross-compiles here, builds the image on the VM, restarts it
```

`deploy.sh` also installs the compose file (`/opt/everyai`) and the reload timer. Done once by hand: the Caddy block
below in `/opt/ttt/Caddyfile` (backup `Caddyfile.bak-everyai`), and TCP 8443 open (firewall rule `everyai-api`,
network tag `everyai-api` on the VM).

```caddy
# EveryAI dev backend: Caddy only obtains and renews this certificate; Anole serves the API on :8443.
everyai.136-108-68-64.sslip.io {
	respond "EveryAI API: https://everyai.136-108-68-64.sslip.io:8443" 404
}
```
