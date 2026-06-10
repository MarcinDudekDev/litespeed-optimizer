# litespeed-optimizer

**One command to make WordPress on LiteSpeed fast and secure.**

The only optimizer for an *already-running* LiteSpeed/OpenLiteSpeed WordPress server.
`ols1clk` installs, CyberPanel provisions — nobody tunes, audits, or rolls back. This tool does.

Sibling project of [nginx-optimizer](https://github.com/MarcinDudekDev/nginx-optimizer), sharing its CLI conventions, backup/rollback pattern, and bash 3.2 portability.

## Status: v0.4.0 — all v0.1-MVP phases complete

| Command | What it does |
|---|---|
| `detect` | Environment report: OLS vs Enterprise, panel (CyberPanel/cPanel/DirectAdmin/plain), config paths, PHP, WP sites, RAM/CPU tier, firewall, Redis/MariaDB |
| `check` | Pre-flight: root, lswsctrl, restart command, backup dir, wp-cli, panel-managed warnings |
| `analyze` | Weighted 0–100 audit with FIX hints (server / PHP / OPcache / cache / object cache / security); danger findings cap the score at 59; `--json` |
| `optimize` | Backup → apply profile features → verified restart-or-rollback. Profiles: `generic` / `wordpress` / `woocommerce` / `auto` |
| `rollback <ts>` / `--list` | Verified restore: files back, checksum verification, graceful restart, HTTP health check, auto-restore on failure |
| `status` | Which optimizations are applied (registry detect loop) |
| `benchmark <url>` | TTFB ×10 (dns/connect/tls), first-vs-warm median, `x-litespeed-cache: hit` verification, cart no-cache probe, before/after history |

**Features applied by `optimize`**: RAM-tier `tuning{}` · LSAPI sizing with the `maxConns == PHP_LSAPI_CHILDREN` invariant · OPcache drop-in · server-level LSCache safety config (`enableCache 0` — LSCWP drives caching) · LSCWP plugin install + CVE gate (≥6.5.1) + curated option profiles (validated against plugin 7.8.1 source) · Redis object-cache wiring (lifetime 600) · WooCommerce ESI (Enterprise) / warn+fallback (OLS) + crawler · per-client throttling + WordPressProtect.

## Install

```bash
git clone https://github.com/MarcinDudekDev/litespeed-optimizer.git
cd litespeed-optimizer && ./install.sh
```

## Usage

```bash
litespeed-optimizer detect              # what am I running?
litespeed-optimizer check               # safe to optimize?
litespeed-optimizer optimize --dry-run  # preview (Phase 2+)
litespeed-optimizer rollback --list     # list backups
litespeed-optimizer rollback 20260610-143022
```

## Safety model

- **Backup before every change** — timestamped, with manifest, under `~/.litespeed-optimizer/backups/`.
- **OLS has no `nginx -t`** — so the restart *is* the validation: grammar lint → graceful restart → `lswsctrl status` + process check + HTTP health check (3 retries / 15 s) → **automatic restore from the just-made backup on failure**.
- **LSWS Enterprise XML is never edited** — writes go via Apache includes / `.htaccess`.
- **Panel policy**: full automation on plain + CyberPanel; cPanel via Apache include; DirectAdmin/RunCloud get manual steps (panel regeneration clobbers direct edits).
- Transactional multi-file edits with Ctrl-C interrupt safety.

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

- Bash 3.2+ (macOS default works), `rsync`, `curl`, `awk`
- An existing LiteSpeed/OpenLiteSpeed install (use `ols1clk` to install OLS first)
- `wp-cli` optional (needed for LSCWP plugin features, Phase 3)

## License

MIT — see [LICENSE](LICENSE).
