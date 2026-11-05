# EveryAI Privacy Policy

Effective 2026-11-04. Applies to the EveryAI apps (macOS, Windows, Linux, iOS, Android, web) and the EveryAI server.
EveryAI is published by Ali Direct (contact: xuckless@gmail.com).

## The short version

- Your chats, coding sessions, memory and settings are stored **on your device**, not on our server.
- Messages you send to an AI model pass **through** our server to the model provider you picked and are **not
  stored** there.
- Your own API keys stay in your operating system's keychain. When a request uses one, the app sends it for that
  request only; the server never stores or logs it.
- No ads, no tracking, no analytics SDKs, and we never sell your data.

## What stays on your device

Chat history, attachments, artifacts, Code sessions and their transcripts, project notes, memory, skills, settings
and your API keys (in the system keychain). Deleting the app or its data folder removes them.

## What reaches the EveryAI server

- **Your account** (when sign-in is on): name, email address, a salted password hash (Argon2), or the Google account
  id if you sign in with Google; sign-in tokens.
- **AI requests:** the messages, attachments and tool results of a request, forwarded to the model provider (OpenRouter
  or Anthropic) and to web search when you use Search or Research. We don't keep the content.
- **Usage records:** for each model call, the model, token counts, cost and the chat or session id it belongs to, so we
  can show usage and bill fairly.
- **Remote control:** names and public keys of paired devices. What travels between your devices is end-to-end
  encrypted; the server relays it and can't read it.
- **Payments** (when billing is on) are handled by Stripe; we keep the plan, balance and Stripe ids, never card
  details.
- **Technical data:** IP addresses are used briefly for rate limiting and abuse protection.

## Third parties

When you use a model, your request is processed by its provider under their terms and privacy policy: OpenRouter
(and the model vendor it routes to), Anthropic, and the web search provider for Search/Research. Coding agents you
run from EveryAI (Claude Code, Codex, Gemini CLI, OpenCode and others) run on your computer under their own terms
and accounts. Anything a coding agent or tool reads in folders you open may be sent to the model you chose.

## Your choices

- Use your own API keys, and the provider bills and handles your requests directly.
- Ask us to delete your account at xuckless@gmail.com (an in-app button is coming). Deleting an account removes it,
  its tokens, devices and usage records from the server.
- Ask us for a copy of your data at the same address.

## Children

EveryAI is not directed at children under 13, and we don't knowingly collect their data.

## AI content

AI answers can be wrong or inappropriate. Report problematic output at
https://github.com/xuckless/everyai-mono/issues (leave out private data) or by email.

## Changes

We'll update this page and its date when this policy changes.
