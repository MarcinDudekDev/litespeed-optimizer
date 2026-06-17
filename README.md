# litespeed-optimizer

**One command to make WordPress on LiteSpeed fast and secure.**

The only optimizer for an *already-running* LiteSpeed/OpenLiteSpeed WordPress server.
`ols1clk` installs, CyberPanel provisions — nobody tunes, audits, or rolls back. This tool does.

Sibling project of [nginx-optimizer](https://github.com/MarcinDudekDev/nginx-optimizer), sharing its CLI conventions, backup/rollback pattern, and bash 3.2 portability.

[![CI](https://github.com/MarcinDudekDev/litespeed-optimizer/actions/workflows/ci.yml/badge.svg)](https://github.com/MarcinDudekDev/litespeed-optimizer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![lint: shellcheck](https://img.shields.io/badge/lint-shellcheck-brightgreen.svg)](https://www.shellcheck.net/)
[![bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-lightgrey.svg)](#requirements)

**v0.7.0** — phases 1–4 complete (detect · tune · WordPress/WooCommerce · security/analyze/benchmark) plus the no-SSH workflows (`analyze --remote`, `export-profile`) and the web-SAPI probes (`probe-redis`, `probe-opcache`). Runs on a live server today; see the [roadmap](ROADMAP.md) for what's next.

**Contents:** [Commands](#commands) · [Compatibility](#compatibility) · [Benchmarks](#benchmarks--live-demo) · [Install](#install) · [Usage](#usage) · [Example output](#example-output) · [Safety model](#safety-model) · [Troubleshooting](#troubleshooting) · [Uninstall](#uninstall) · [Testing](#testing) · [Requirements](#requirements) · [Security & contributing](#security--contributing)

## Commands

| Command | What it does |
|---|---|
| `detect` | Environment report: OLS vs Enterprise, panel (CyberPanel/cPanel/DirectAdmin/plain), config paths, PHP, WP sites, RAM/CPU tier, firewall, Redis/MariaDB |
| `check` | Pre-flight: root, lswsctrl, restart command, backup dir, wp-cli, panel-managed warnings |
| `analyze` | Weighted 0–100 audit with FIX hints (server / PHP / OPcache / cache / object cache / security); danger findings cap the score at 59; `--json` |
| `optimize` | Backup → apply profile features → verified restart-or-rollback. Profiles: `generic` / `wordpress` / `woocommerce` / `auto` |
| `rollback <ts>` / `--list` | Verified restore: files back, checksum verification, graceful restart, HTTP health check, auto-restore on failure |
| `status` | Which optimizations are applied (registry detect loop) |
| `benchmark <url>` | TTFB ×10 (dns/connect/tls), first-vs-warm median, `x-litespeed-cache: hit` verification, cart no-cache probe, before/after history |
| `probe-redis [url]` | Verifies the `redis` PHP extension in the **actual web SAPI** (not CLI/wp-cli php) via a token-guarded one-shot probe dropped in the docroot, fetched over HTTP, self-deleting. Catches "redis-server is up but the serving lsphp lacks the ext → LSCWP object cache silently falls back to MySQL". `--json`, `--basic-auth` |
| `probe-opcache [url]` | Reads **runtime** OPcache stats from the web SAPI (hit-rate/pool-fill/interned/key-table/oom — unreadable via CLI/wp-cli) over the same token-guarded probe; undersized verdict with warm-gated hit-rate and **host-aware** remediation (writable php.ini → sizing snippet, else "contact host" since `opcache.*` is `PHP_INI_SYSTEM`). `--json`, `--basic-auth` |
| `analyze --remote <url>` | HTTP-only remote audit (no server access): cache/TTFB/HTTP3/compression/security + Woo cart-safety probes incl. two-session isolation. GET-only, anonymous, rate-limited — only on sites you own/manage |
| `export-profile` | LSCWP-native `.data` settings file for wp-admin Toolbox import (no SSH) — verified against plugin 7.8.1 |

**Features applied by `optimize`** (7 registered: scope with `--feature`/`--exclude`): RAM-tier `tuning{}` · LSAPI sizing with the `maxConns == PHP_LSAPI_CHILDREN` invariant · OPcache drop-in · server-level LSCache safety config (`enableCache 0` — LSCWP drives caching) · LSCWP plugin install + CVE gate (≥6.5.1) + curated option profiles (validated against plugin 7.8.1 source), incl. Redis object-cache wiring (lifetime 600) when a Redis socket is present · WooCommerce ESI (Enterprise) / warn+fallback (OLS) + crawler · per-client throttling + WordPressProtect.

## Compatibility

Read-only commands (`detect` / `analyze` / `status` / `benchmark`) work on **any** LiteSpeed server; `optimize` write-depth varies by platform:

| Platform | detect / analyze / benchmark | `optimize` (writes) |
|---|---|---|
| Plain OpenLiteSpeed | ✅ | ✅ full automation |
| CyberPanel | ✅ | ✅ full automation |
| cPanel (LiteSpeed) | ✅ | ⚠️ via Apache include |
| DirectAdmin / RunCloud | ✅ | ⚠️ prints manual steps (panel regen clobbers direct edits) |
| LiteSpeed Enterprise (LSWS) | ✅ | ⚠️ server tuning is **report-only** (XML never edited); LSCWP / WooCommerce / `.htaccess` changes still apply |
| No SSH (any host) | ✅ via `analyze --remote` + `export-profile` | — |

Non-standard install path → set `LSO_LSWS_ROOT`. **Exercised against:** the `litespeedtech/openlitespeed` Docker image (E2E), a real OpenLiteSpeed 1.9 + lsphp 8.3 + MariaDB box (benchmark + live demo), a production WooCommerce restore (mltools.pl pilot), and detection fixtures for plain-OLS / CyberPanel / cPanel-Enterprise / DirectAdmin. LSCWP features require plugin ≥6.5.1 (CVE gate). Bash 3.2 (macOS) through 5.x (Linux).

## Benchmarks & live demo

LiteSpeed (OpenLiteSpeed + LSCache + lsphp 8.3 + MariaDB) was benchmarked head-to-head against a matched **FrankenPHP/Caddy** WooCommerce stack on equivalent hardware. Even with FrankenPHP in worker mode, **LiteSpeed was ~25% faster on uncached render and ~6.6× faster on the cart path** — the gap is engine/SAPI-level, not a process-model artifact. Methodology + per-pass probes:

- [Pass-2 report](docs/reports/litespeed-vs-frankenphp-pass2.html) · [Pass-3 report — matched worker mode](docs/reports/litespeed-vs-frankenphp-pass3.html)

**Live LiteSpeed reference:** [litespeed-demo.marcindudek.dev](https://litespeed-demo.marcindudek.dev) — a 500-product WooCommerce store on the real stack (LSCWP full-page cache + Redis); cached pages return in single-digit milliseconds (`x-litespeed-cache: hit`).

## Install

```bash
git clone https://github.com/MarcinDudekDev/litespeed-optimizer.git
cd litespeed-optimizer && ./install.sh
```

## Usage

```bash
litespeed-optimizer --version           # litespeed-optimizer version 0.5.0
litespeed-optimizer detect              # what am I running?
litespeed-optimizer check               # safe to optimize?
litespeed-optimizer optimize --dry-run  # preview all changes
litespeed-optimizer optimize --profile auto        # detect Woo, apply the right profile
litespeed-optimizer analyze --remote https://client-site.example   # no-SSH audit
litespeed-optimizer export-profile --profile woocommerce           # wp-admin import file
litespeed-optimizer rollback --list     # list backups
litespeed-optimizer rollback 20260610-143022
```

You can also run it straight from the clone without installing: `./litespeed-optimizer.sh detect`. `optimize` / `rollback` need **root** (they restart LiteSpeed); read-only commands don't.

## Example output

`analyze` prints scored, actionable findings (illustrative shape):

```text
$ litespeed-optimizer analyze
  [PASS] server  tuning{} matches 4G tier
  [FAIL] php     OPcache drop-in not deployed          FIX: optimize --feature opcache
  [FAIL] cache   LSCWP object cache off                FIX: optimize --feature lscwp
  [WARN] sec     X-Frame-Options header missing        FIX: optimize --feature security
  [DANGER] woo   cart page served from cache           FIX: see remote-analyzer hint
  ----------------------------------------------------------------
  SCORE: 58/100   (a DANGER finding caps the score at 59 until fixed)
```

Add `--json` for machine-readable output (`analyze`, `status`). `benchmark <url>` reports first-vs-warm TTFB and verifies `x-litespeed-cache: hit`.

## Safety model

- **Backup before every change** — timestamped, with manifest, under `~/.litespeed-optimizer/backups/`.
- **OLS has no `nginx -t`** — so the restart *is* the validation: grammar lint → graceful restart → `lswsctrl status` + process check + HTTP health check (3 retries / 15 s) → **automatic restore from the just-made backup on failure**.
- **LSWS Enterprise XML is never edited** — writes go via Apache includes / `.htaccess`.
- **Panel policy**: full automation on plain + CyberPanel; cPanel via Apache include; DirectAdmin/RunCloud get manual steps (panel regeneration clobbers direct edits).
- Transactional multi-file edits with Ctrl-C interrupt safety.

**What it never touches:** LSWS Enterprise `httpd_config.xml`; server-wide `enableCache 1` (cross-vhost cache-poisoning guard); your credentials (none are stored). No telemetry or outbound calls except the explicit `analyze --remote`/`benchmark` HTTP requests you point at a URL you own.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `must run as root` on `optimize` | `optimize`/`rollback` restart LiteSpeed — run with `sudo`. Read-only commands don't need root. |
| LSCWP step refuses to proceed | Installed LSCWP is below the CVE gate (≥6.5.1). The tool auto-updates when it can; otherwise update the plugin first. |
| `enableCache` still 1 after optimize | Expected on Enterprise (XML never edited) / managed panels — apply the LSCache safety block via the printed manual step, or fix in the panel. |
| Optimize reverted itself | The post-change HTTP health check failed, so the auto-restore kicked in. Check `lswsctrl status` and the lint output, then retry with `--feature` to isolate. |
| `analyze` says OPcache stats unreadable | CLI php has `opcache.enable_cli=0`; runtime hit-rate is web-SAPI-only. The score still completes; a web-context probe is on the roadmap. |
| DirectAdmin/RunCloud changes don't stick | Panel regeneration overwrites direct edits — apply the manual steps the tool prints, in the panel. |
| LSCWP cache/vary acting odd | The vhost may have rewrite disabled; LSCWP relies on `.htaccess`/mod_rewrite. Enable rewrite for the vhost. |
| `analyze --remote` rate-limited / 401 | It's intentionally throttled and GET-only; for gated staging pass `--basic-auth user:pass` (or `LSO_HTTP_AUTH`). |

## Uninstall

```bash
# 1. FIRST revert any optimizations you applied (removing the CLI does NOT undo server changes):
litespeed-optimizer rollback --list
litespeed-optimizer rollback <timestamp>

# 2. Then remove the symlink + data dir:
sudo rm -f /usr/local/bin/litespeed-optimizer
rm -rf ~/.litespeed-optimizer      # backups + state (only after you're done rolling back)
rm -rf ~/Tools/litespeed-optimizer # the clone
```

> ⚠️ Deleting the CLI does **not** revert config it wrote. Roll back first, or your tuning/LSCWP/security changes stay in place.

## Testing

```bash
tests/run-tests.sh
```

Plain-bash suite (no bats): shellcheck gate, bash 3.2 syntax + portability checks, detection tests against 5 fixture environment trees (`tests/configs/`), confedit unit tests, backup/rollback round-trip with `diff -r` verification, golden configs per RAM tier, mock-wp-cli LSCWP tests, profile key lint against the vendored LSCWP 7.8.1 option list, analyze/benchmark tests. No real LiteSpeed server needed.

```bash
tests/test-with-ols-docker.sh   # E2E against a real litespeedtech/openlitespeed container
```

Skips cleanly when Docker is absent (CI target). Runs detect/check/dry-run plus a **real** optimize with graceful restart + health check.

## Environment overrides

| Variable | Purpose |
|---|---|
| `LSO_LSWS_ROOT` | Override LiteSpeed root (default `/usr/local/lsws`, fallback `/opt/lsws`) |
| `LSO_FS_ROOT` | Prefix for all absolute paths — points the whole tool at a fixture tree |
| `LSO_DATA_DIR` | Override `~/.litespeed-optimizer` |
| `LSO_RAM_MB` / `LSO_CORES` | Force RAM/CPU values (golden tests) |
| `LSO_SKIP_RESTART=1` | Skip restart/health-check (test mode) |

## Requirements

- **An existing LiteSpeed/OpenLiteSpeed install** (use `ols1clk` to install OLS first) — this tool tunes, it does not install the server.
- **Bash 3.2+** (macOS default works) and standard userland: `awk`, `sed`, `grep`, `curl`, `rsync`, `tar`/`gzip`, `stat`, plus a checksum tool (`sha256sum` or `shasum`).
- **`lswsctrl`** (ships with LiteSpeed) and a service manager (`systemctl`/`service`) for the restart/health-check step.
- **`wp-cli` + a CLI PHP** — required for the WordPress/WooCommerce features (LSCWP install, CVE gate, option get/set, `--profile auto` Woo detection). Override the binary with `LSO_WP_BIN` (e.g. run via the vhost's lsphp). Not needed for server-only tuning or `analyze --remote`.
- **Optional:** `redis-cli` (object-cache detection), `mariadb`/`mysql` client (DB checks), `jq` (nicer `--json` handling).

## Security & contributing

- **Security policy / reporting:** see [SECURITY.md](SECURITY.md).
- **Contributing:** every `.sh` must pass `shellcheck --severity=error` and stay bash 3.2 compatible (no `declare -A`, `flock`, `${var,,}`, `find -printf`). Run `tests/run-tests.sh` (must be green) before a PR; features live in `lib/features/` with a `feature_register` at the end. Canonical spec: [`docs/research/SPEC.md`](docs/research/SPEC.md).

## License

MIT — see [LICENSE](LICENSE).
