# QuotaBar

**English** | [中文](README.zh-CN.md)

A macOS menu bar monitor for **AI coding plans, coding agents & API quotas** across cloud providers — Volcengine Ark, Zhipu GLM, DeepSeek, Moonshot Kimi, Tencent, Alibaba, and any other provider you add later.

> Inspired by ClaudeBar. One bar to watch all your AI coding spend.

## Features

- **Menu bar status with signal icon** — Shows the higher of the last-5-hours / last-week usage (`5H 100.0%` / `W 6.9%`). A 3-bar signal icon (fixed shape) changes color by usage tier: green <50%, yellow 50–75%, orange 75–90%, red ≥90%. Auto-refresh every 10 minutes.
- **Multi-plan tab switching** — Switch active plans right from the menu; data refreshes instantly. Ships with sensible defaults and lets you add unlimited plans (any cloud provider's Coding Plan / Agent / API key).
- **Quota windows with progress bars** — Last 5 hours / day / week / month usage percentages, human-friendly reset times ("today 21:31", "tomorrow 00:44", "Oct 5 00:00"), and a 10-segment color-coded progress bar per window.
- **Settings panel** — Add, edit or delete plans; configure per-plan credentials:
  - `arkcli (local login)` — reuse your local `arkcli` login session (simplest for Volcengine plans)
  - `AK/SK (direct API)` — query Agent Plan quotas via the official OpenAPI `GetAFPUsage` with Volcengine Access Key / Secret Key — no local `arkcli` login needed, works on any machine
- **Model price & capability chart** (⌘P) — Official API prices for 16 models (log scale, blue = input / orange = output), modality badges (image+text / video / text-only), three leaderboard scores (LMArena ELO / LiveBench Coding / SWE-bench Verified) with rank numbers, Opus 4.8 (coding baseline) & Sonnet (daily baseline) highlighted, sortable by score or price.
- ⌘R refresh now, ⌘Q quit.

## Requirements

- macOS 11.0+
- For Volcengine plans: `arkcli` installed & logged in (`npm i -g @volcengine/ark-cli && arkcli auth login`), or an AK/SK pair from Volcengine console → Access Control → Access Keys.

## Run

```bash
open /Applications/QuotaBar.app
# or build from source (see below)
```

## Configure & share

- Config is stored in `~/Library/Application Support/QuotaBar/config.json` — a single JSON file holding all plans & credentials.
- To share with others: copy the app and that config file. For Agent Plan, prefer the **AK/SK** auth mode so the recipient doesn't need your `arkcli` login.
- Credentials never leave your machine; the app talks directly to official provider APIs.

## Build from source

```bash
git clone https://github.com/liuchang5/quotabar.git
cd quotabar
swiftc -O -swift-version 5 -o QuotaBar main.swift -framework AppKit -framework Foundation -framework CryptoKit
mkdir -p /Applications/QuotaBar.app/Contents/MacOS
cp QuotaBar /Applications/QuotaBar.app/Contents/MacOS/QuotaBar
# (create /Applications/QuotaBar.app/Contents/Info.plist from the Info.plist in this repo)
open /Applications/QuotaBar.app
```

Single-file Swift (AppKit), no external dependencies.

## Data source notes

- Coding Plan (personal) has **no public usage OpenAPI**; the app queries your local `arkcli` (SSO session).
- Agent Plan (personal) supports both `arkcli` and the official OpenAPI `GetAFPUsage` (POST `https://ark.cn-beijing.volcengineapi.com/?Action=GetAFPUsage&Version=2024-01-01`, HMAC-SHA256 signed).

## Screenshots

(TBD)

## License

MIT
