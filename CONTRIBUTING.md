# Contributing

Thanks for helping with EveryAI. It is a pre-alpha prototype, so expect rough edges and fast changes.
[`AGENTS.md`](AGENTS.md) has the working notes (rules, the `/v1` contract, decisions, progress); read it before a
larger change, and if you use a coding agent, point it there.

## Branches and pull requests

- `main` only takes pull requests, and every PR needs the owner's review.
- Collaborators branch off `main` (`feat/…`, `fix/…`, `docs/…`) and open a PR. Everyone else forks the repo and opens
  a PR from the fork.
- Keep a PR to one change, and keep files outside it untouched (editor whitespace included). `backend/` is frozen.
- Describe what changed and how you checked it, including what you didn't test.

## Commits

- Commit under your own name. No AI tool credits in commits or PRs (no `Co-Authored-By` for a tool, no "Generated
  with", no session links).
- Never commit `.env` files or keys; `.env.example` is the template.
- Code copied from elsewhere must be MIT, Apache-2.0 or BSD licensed, with an entry in
  [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Prompts are always written in our own words.

## Running it

**Just the app**, against the deployed dev server (you only need Flutter; the script installs it on macOS):

```sh
scripts/launch.sh               # this computer (macOS, Linux, Windows via Git Bash)
scripts/launch.sh web           # or: ios-sim · ios · android · <device id>
scripts/launch.sh build macos   # an unsigned build (also: linux · windows · web · apk)
```

`EVERYAI_API` points it at another server. Windows and Linux builds also come from the
[Dev builds](.github/workflows/dev-builds.yml) workflow (push a `builds/*` branch or run it from the Actions tab).

**Everything locally** (backend + app). You need Flutter 3.47 and Zig 0.17; [Anole](https://github.com/xuckless/anole)
0.5.1 is fetched by `zig build`. Code's browser tool needs Chrome, Chromium, Edge or Brave.

```sh
scripts/dev.sh macos            # or: web · ios-sim · ios · <device id>
```

`dev.sh` starts `backend-exp` on `:8080` (or reuses a running one), fetches Deno for `run_script` and workflows,
writes the right `API_BASE_URL` for the target, and runs the app. Then add an OpenRouter or Anthropic key in
**Settings → API keys**; no `.env` is needed.

<details>
<summary><b>Run the pieces by hand</b></summary>

```sh
# Backend (http://localhost:8080, API docs at /docs)
cd backend-exp && zig build run
zig build test

# App
cd frontend && flutter pub get
flutter run -d macos --dart-define-from-file=config/example.json
```

</details>

<details>
<summary><b>Configuration</b></summary>

- **Secrets (optional):** one `.env` at the repo root (template `.env.example`). Without `OPENROUTER_API_KEY` the
  server runs on the keys users add in the app; without `JWT_SECRET` (development only) it makes a random one per run.
- **`DEV_AUTH=true`:** no sign-in; anonymous requests act as a dev user.
- **`RATE_LIMIT_PER_MINUTE`** (600): requests per minute per client address (0 turns it off).
- **`TLS_CERT_PATH` / `TLS_KEY_PATH`:** serve HTTPS from PEM files (reloaded on SIGHUP), as the dev deployment does.
- **Firebase / Google Sign-In files** (`GoogleService-Info.plist`, `google-services.json`) are gitignored; put them in
  the platform folders locally.

</details>

## Checks before a PR

```sh
cd frontend && flutter analyze && flutter test
dart format -l 120 <changed files>     # the project's width; plain `dart format lib` rewraps to 80
cd backend-exp && zig build test        # only when the backend changed
```

Tests that need Deno skip without `DENO_BIN`; `tool/agent_eval/` holds live checks that call real models and only run
when asked.
