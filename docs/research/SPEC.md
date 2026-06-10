# litespeed-optimizer — v0.1 MVP Implementation Spec

Blueprint for an implementation agent. Mirrors `~/Tools/nginx-optimizer` architecture and CLI conventions. All parameter values come from `SYNTHESIS.md` (same directory) — this spec inlines the load-bearing ones so it is self-contained.

Positioning (from landscape report): **the only "optimizer for an already-running LiteSpeed/OLS WordPress server"** — ols1clk installs, CyberPanel provisions, nobody tunes/audits/rolls back. Tagline parity with nginx-optimizer: "One command to make WordPress on LiteSpeed fast and secure."

---

## 1. Repo layout

```
litespeed-optimizer/
├── litespeed-optimizer.sh        # entrypoint: arg parse, lock, dispatch (mirror nginx-optimizer.sh)
├── install.sh
├── README.md  CHANGELOG.md  ROADMAP.md  CLAUDE.md  LICENSE  SECURITY.md
├── lib/
│   ├── registry.sh               # COPY nginx-optimizer's lib/registry.sh verbatim (bash-3.2-safe
│   │                             #   semicolon-record feature registry; it is server-agnostic)
│   ├── core/
│   │   ├── helpers.sh            # logging, validation, run_cmd dry-run wrapper (port from nginx-opt)
│   │   ├── sysinfo.sh            # PORT nginx-optimizer lib/core/sysinfo.sh (RAM/CPU tiers) + add
│   │   │                         #   sysinfo_lsphp_rss() → avg RSS from `ps -ylC lsphp --sort:rss`
│   │   ├── detect-env.sh         # edition + panel + paths detection (see §4)
│   │   ├── confedit.sh           # OLS plain-text config read/write primitives (see §5)
│   │   └── templates.sh          # template deploy helpers (port, paths adjusted)
│   └── features/                 # one file per feature, feature_register at end (nginx-opt pattern)
│       ├── server-tuning.sh      # tuning{} block
│       ├── lsapi-tuning.sh       # extprocessor / External App
│       ├── opcache.sh
│       ├── lscache.sh            # server-side cache module / CacheRoot directives
│       ├── http3.sh              # verify/enable QUIC + firewall check
│       ├── redis.sh
│       ├── mariadb.sh
│       ├── os-limits.sh          # systemd LimitNOFILE + sysctl
│       ├── lscwp.sh              # plugin install + profile import via wp-cli
│       ├── woocommerce.sh        # ESI, crawler, Woo checks (depends on lscwp)
│       └── security.sh           # perClientConnLimit, headers, xmlrpc, CVE checks
├── litespeed-optimizer-lib/      # workflow modules (mirror nginx-optimizer-lib/)
│   ├── detector.sh               # detect_all_features loop over registry
│   ├── analyzer.sh               # scored audit (NEW vs nginx-opt: weighted score 0–100)
│   ├── optimizer.sh              # transaction pattern + feature_apply loop
│   ├── backup.sh                 # timestamped backup/restore (see §7)
│   ├── validator.sh              # config validation + verified restart-or-rollback
│   ├── benchmark.sh              # curl TTFB ×10 median, cached/uncached, cache-hit header
│   └── ui.sh
├── templates/
│   ├── ols/                     # OLS native-format include snippets
│   │   ├── tuning.conf.tpl              # tuning{} overrides, @RAM_TIER@ placeholders
│   │   ├── lsphp-extapp.conf.tpl        # extprocessor block
│   │   ├── cache-vhost.conf.tpl         # module cache { storagePath $VH_ROOT/lscache ... }
│   │   ├── throttling.conf.tpl          # perClientConnLimit block
│   │   └── modsec.conf.tpl              # (placeholder, v0.2)
│   ├── lsws/                    # Apache-style includes for Enterprise
│   │   ├── cache-global.conf.tpl        # <IfModule Litespeed> CacheRoot /home/lscache/ ; CacheEngine on esi crawler
│   │   ├── cache-htaccess.tpl           # CacheLookup public on
│   │   ├── wp-protect.conf.tpl          # WordPressProtect drop, 10
│   │   └── security-headers.tpl
│   ├── php/opcache.ini.tpl
│   ├── redis/99-litespeed-optimizer.conf.tpl
│   ├── mariadb/99-woocommerce.cnf.tpl
│   ├── os/99-litespeed.sysctl.tpl  +  lsws-override.conf.tpl (systemd)
│   └── lscwp/                   # the differentiator: curated litespeed-option import profiles
│       ├── profile-woocommerce.txt
│       ├── profile-wordpress.txt
│       └── profile-generic.txt
└── tests/
    ├── run-tests.sh              # mirror nginx-optimizer tests/run-tests.sh sections
    ├── test-with-ols-docker.sh   # optional litespeedtech/openlitespeed container
    ├── configs/                  # fixture httpd_config.conf corpora (plain, cyberpanel-like, edge)
    └── golden/                   # expected generated configs per RAM tier (golden tests)
```

Data dir: `~/.litespeed-optimizer/{backups,logs,cache}` — same shape as `~/.nginx-optimizer/`.
Conventions carried over from nginx-optimizer: `set -euo pipefail`, bash 3.2 compatible (no `declare -A`, no `flock`, no GNU-only flags), mkdir-based lock file, shellcheck-clean (`--severity=warning`), NO_COLOR support, `[DRY RUN] Would ...` logging everywhere.

---

## 2. CLI commands (v0.1)

```
litespeed-optimizer.sh detect                      # environment report: edition, panel, paths, versions,
                                                   #   RAM/CPU tier, WP sites found, redis/mariadb presence
litespeed-optimizer.sh check                       # pre-flight: root?, lswsctrl works?, backup dir writable?,
                                                   #   wp-cli present?, panel-managed warnings
litespeed-optimizer.sh analyze [site]              # scored audit 0–100 (see §3); --json supported
litespeed-optimizer.sh optimize [site] [flags]     # apply features
    --dry-run                                      # preview, no writes
    --profile woocommerce|wordpress|generic        # default: auto (woocommerce if Woo plugin active)
    --feature <id>     --exclude <id>              # single feature / skip feature
    --force  --quiet  --json  --no-color
litespeed-optimizer.sh rollback <timestamp>        # restore backup, restart, verify
litespeed-optimizer.sh rollback --list
litespeed-optimizer.sh status [site]               # which optimizations applied (registry detect loop)
litespeed-optimizer.sh benchmark <url>             # before/after TTFB + cache-hit verification
litespeed-optimizer.sh help | --version
```

Same UX as nginx-optimizer (`analyze`/`check`/`optimize --dry-run`/`rollback <ts>`/`status`/`benchmark`); `detect` is new (environment matrix is far hairier than nginx's). Feature aliases validated against `ALLOWED_FEATURES` array exactly like nginx-optimizer.

Profile differences:
- `generic`: server-tuning, lsapi, opcache, os-limits, http3, security(throttling+headers).
- `wordpress`: + lscache, lscwp(profile-wordpress), redis, mariadb.
- `woocommerce`: + lscwp(profile-woocommerce), woocommerce module (ESI/crawler/Woo checks), mariadb woo extras.

---

## 3. `analyze` — scored audit (the lead-gen hook; no competitor has it)

Weighted checks → 0–100 + letter grade + per-check FIX hints. Categories/weights:

| Category (weight) | Checks |
|---|---|
| Page cache (25) | LSCache module/CacheRoot configured; `x-litespeed-cache: hit` on 2nd curl of homepage; LSCWP active + version ≥ 6.5.1; Serve Stale on; crawler enabled |
| PHP capacity (20) | ProcessGroup mode; `maxConns == PHP_LSAPI_CHILDREN`; children within ±40% of RAM-formula value; AVOID_FORK sane for tier (flag bare `=1` with <1 GB free); `LSAPI_PGRP_MAX_IDLE ≥ 3600` on ≥4 GB |
| OPcache (10) | enabled; memory ≥ tier value; `max_accelerated_files ≥ 20000`; `save_comments=1`; hit rate >99% if queryable |
| Object cache (10) | Redis running; LSCWP object cache on; lifetime ≥ 600; `evicted_keys == 0`; `maxmemory-policy allkeys-lru` |
| Database (10) | buffer pool ≥ tier minimum; slow log on; autoload < 1 MB (if wp-cli); Action Scheduler rows < 50k |
| Security (15) | throttling block present with dynReqPerSec ≤ 5; LSCWP CVE-version check; debug log off; crawler role-sim off; xmlrpc handled; WebAdmin 7080 not world-open; headers present |
| Protocol/static (10) | HTTP/3 answers (`curl --http3` if available, else UDP 443 + listener check + CSF UDPFLOOD warning); brotli on; `gzipAutoUpdateStatic 1`; keepAliveTimeout 2–5 |

Danger findings (red, score-capping at 59 regardless): `enableCache 1` server-wide; `woocommerce_items_in_cart` in Do-Not-Cache Cookies; Cloudflare cache-everything in front (detect `cf-cache-status: HIT` on HTML); Guest Optimization + UCSS on a Woo store; debug log world-readable.

---

## 4. Detection module (`lib/core/detect-env.sh`)

Exports globals consumed by all features:
```
LSO_LSWS_ROOT      /usr/local/lsws (fallback /opt/lsws)
LSO_EDITION        ols | enterprise
LSO_PANEL          cyberpanel | cpanel | directadmin | runcloud | plain
LSO_MAIN_CONF      httpd_config.conf (ols) | httpd_config.xml (enterprise; read-only!)
LSO_APACHE_INCLUDE /etc/apache2/conf.d/includes/pre_main_global.conf (cpanel) | "" otherwise
LSO_VHOSTS_DIR, LSO_PHP_BIN, LSO_PHP_INI, LSO_PHP_VER
LSO_RESTART_CMD    per-panel: /scripts/restartsrv_lsws | systemctl restart lsws | lswsctrl restart
LSO_PHP_RESTART    "touch $LSO_LSWS_ROOT/admin/tmp/.lsphp_restart.txt"
LSO_RAM_MB, LSO_CORES, LSO_RAM_TIER (1g/2g/4g/8g), LSO_LSPHP_RSS_MB
LSO_WP_SITES[]     docroots containing wp-config.php; LSO_HAS_WPCLI, LSO_HAS_WOO (per site)
LSO_FIREWALL       csf|ufw|firewalld|none ; LSO_HAS_REDIS ; LSO_HAS_MARIADB
```
Logic order (synthesis §4): lswsctrl exists → edition via `httpd_config.xml` presence + `lshttpd -v` grep + `serial.no` → panel via dir markers (CyberCP, cpanel, directadmin, runcloud) → resolve php.ini via `$LSO_PHP_BIN -i | grep 'Loaded Configuration File'` (never hardcode — DA uses `/usr/local/phpXX`).

**Panel policy v0.1:** full automation on `plain` and `cyberpanel` OLS. On `cpanel` Enterprise: server tuning via Apache include + .htaccess, LSAPI via `<IfModule LiteSpeed> LSPHP_Workers N` + suEXEC note. On `directadmin`/`runcloud`: analyze fully, but `optimize` only applies php.ini/redis/mariadb/os modules and **prints exact manual steps** for server config (panel regeneration clobbers direct edits).

---

## 5. Config-edit primitives (`lib/core/confedit.sh`) — OLS path

OLS `httpd_config.conf` is line-oriented `block { key value }`. Primitives (awk-based, like nginx-optimizer's `inject_server_includes`):
- `ols_get <file> <block> <key>` / `ols_set <file> <block> <key> <value>` — edit key inside a named top-level block; create block if absent.
- `ols_ensure_include <file> <include-path>` — preferred strategy: write our settings into `$LSWS_ROOT/conf/litespeed-optimizer/*.conf` and add a single `include` line to the main config. Survives manual edits; uninstall = remove one line. (Caveat: `tuning{}`/`extprocessor` keys must live in the main blocks on some versions — when include can't express it, fall back to in-place `ols_set` on the main file.)
- All writes: `cp -a` to temp, edit, `chown lsadm:lsadm`-preserving install, then validate.
- Validation: OLS has no `-t`; validation = restart-and-verify (§7). Pre-check with a grammar lint (balanced braces, known keys) in bash/awk to catch garbage before touching the live file.

LSWS Enterprise path: never edit the XML. Writes go to `$LSO_APACHE_INCLUDE` (cPanel) or per-site `.htaccess` blocks delimited `# BEGIN litespeed-optimizer` / `# END litespeed-optimizer` (idempotent replace, placed AFTER LSCWP's block, before WordPress block).

---

## 6. Per-module breakdown

| Module | Touches | OLS path | LSWS path | Key values (per RAM tier — full table in SYNTHESIS §2) |
|---|---|---|---|---|
| `server-tuning` | main conf `tuning{}` | ols_set on tuning block | report-only v0.1 (WebAdmin/XML territory) — print recommended values | maxConnections 2000/5000/10000/10000; connTimeout 30–60; keepAliveTimeout 2–5; maxKeepAliveReq ≥1000; sndBuf/rcvBuf 0; brotli 2–4; gzipAutoUpdateStatic 1; inMem/MMap cache per tier |
| `lsapi-tuning` | `extprocessor lsphp` block (OLS); `<IfModule LiteSpeed>` LSPHP_Workers + env (LSWS) | ols_set on extprocessor | Apache include | **maxConns == PHP_LSAPI_CHILDREN** 10/15–25/35/60; AVOID_FORK 0/200M/500M/1; MAX_REQS 1000→10000; MAX_IDLE 60→3600; PGRP_MAX_IDLE 3600 (≥2 GB); ACCEPT_NOTIFY 1; SLOW_REQ_MSECS 5000; memSoft/Hard per tier |
| `opcache` | drop-in ini next to detected php.ini (scan-dir) or php.ini edit; then `$LSO_PHP_RESTART` | same | same (ea-php / DA paths) | memory 64/128/192–256/256; max_accelerated_files 20000–50000; interned 16–32; validate=1 revalidate=60; save_comments=1; enable_cli=0; JIT off |
| `lscache` | per-vhost cache config + storage dir | vhost `module cache { storagePath $VH_ROOT/lscache; ignoreRespCacheCtrl 0; enableCache 0; checkPublicCache 1; ... }` | global `CacheRoot /home/lscache/` + `CacheEngine on esi crawler` (include) + `.htaccess` `CacheLookup public on` | **NEVER `enableCache 1` server-wide.** LSCWP drives caching via headers |
| `http3` | listener conf + firewall | verify `enableQuic`/listener UDP; `ufw allow 443/udp`; CSF: warn UDPFLOOD must be 0 (don't auto-edit csf.conf v0.1) | same | verify via `curl --http3 -I` when curl supports it |
| `redis` | `/etc/redis/redis.conf` or drop-in dir; LSCWP object settings via wp-cli | same both | same | maxmemory 64m/128m/256–512m/512m–1g; allkeys-lru; unix socket where suEXEC user can join `redis` group, else 127.0.0.1; save "" appendonly no |
| `mariadb` | `/etc/mysql/mariadb.conf.d/99-woocommerce.cnf` (or `/etc/my.cnf.d/`) | same both | same | buffer pool 256M/512M/1–1.5G/2.5–3G; log_file 25% of pool; O_DIRECT; trx_commit=1 always; slow log 0.5s; restart mariadb only with `--force` or off-peak warning |
| `os-limits` | `/etc/systemd/system/lsws.service.d/override.conf` (LimitNOFILE=65535) + `/etc/sysctl.d/99-litespeed.conf` | same both | same | somaxconn 4096, syn_backlog 8192, fin_timeout 15, tw_reuse 1, swappiness 10, bbr+fq if available |
| `lscwp` | WP plugin + options | `wp plugin install litespeed-cache --activate` (if missing); `wp litespeed-option import templates/lscwp/profile-<X>.txt`; `wp litespeed-purge all` | same | profile contents in SYNTHESIS §5: TTLs 604800/1800, Serve Stale on, minify on, combine/UCSS/defer OFF, Guest Mode on / Guest Optimization OFF, object cache redis lifetime ≥600, debug OFF |
| `woocommerce` | LSCWP ESI/Woo options + server crawler + app hygiene | ESI **skipped + warned** (OLS has none; suggest QUIC.cloud); Vary-for-Mini-Cart fallback if theme needs it | enable ESI (esi=1, admin bar, comment form) — requires `CacheEngine on esi` from lscache module | crawler: enable, sitemap autodetect, threads 3, load limit 1.0, role-sim OFF; checks: items_in_cart NOT in do-not-cache cookies, multi-currency cookie in Vary Cookies, Woo page IDs sane; optional (flag-gated `--db-hygiene`): `wp wc palt regenerate`, AS purge, transient purge, autoload report |
| `security` | OLS `perClientConnLimit` block; LSWS .htaccess/include | ols_set | include: throttling note + `WordPressProtect drop, 10` + headers | dynReqPerSec 2, staticReqPerSec 40, softLimit 15, hardLimit 20, gracePeriod 15, banPeriod 300, blockBadReq 1; headers nosniff/SAMEORIGIN/referrer/HSTS-when-https; xmlrpc 403 unless --keep-xmlrpc; LSCWP version CVE gate |

---

## 7. Backup / rollback design

Mirror nginx-optimizer `backup.sh` (rsync, timestamped) with LiteSpeed targets:

```
~/.litespeed-optimizer/backups/<YYYYmmdd-HHMMSS>/
├── manifest.txt            # what was backed up, edition, panel, tool version, applied features
├── lsws-conf/              # rsync -a /usr/local/lsws/conf/   (covers main+vhosts, OLS & LSWS)
├── apache-includes/        # cPanel: /etc/apache2/conf.d/includes/
├── htaccess/<site>/        # any .htaccess we touch
├── php/                    # touched php.ini / drop-ins
├── redis/  mariadb/  sysctl/  systemd/
└── lscwp/<site>.json       # `wp litespeed-option export` pre-change snapshot
```

**Verified restart-or-rollback** (validator.sh) — OLS lacks `nginx -t`, so the restart IS the validation:
1. snapshot `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/` baseline (and one real vhost URL).
2. apply file changes inside transaction (`transaction_start/add_file/commit/rollback` — port nginx-optimizer optimizer.sh pattern; each add_file records the pre-image).
3. `$LSO_RESTART_CMD` (graceful).
4. health check: `lswsctrl status` says running AND pgrep lshttpd AND baseline URL returns same-or-better status within 15 s (3 retries).
5. failure ⇒ automatic restore from the just-made backup + restart + re-health-check + exit 1 with log path. Ctrl-C trap does the same (interrupt safety, as in nginx-optimizer).
6. `rollback <timestamp>` replays step 5 from any stored backup; `--list` shows manifests. Validate timestamp with `_validate_input_name` pattern (no traversal).

wp-cli changes roll back via `wp litespeed-option import <backup>/lscwp/<site>.json`.

---

## 8. RAM-aware sizing (lib/core/sysinfo.sh additions)

```bash
# tier: 1g(<1536MB) 2g(<3072) 4g(<6144) 8g(>=6144)
lso_children() {           # the one computed value; everything else is tier lookup
  local ram=$1 cores=$2 rss=${3:-80}            # rss measured or 80MB woo / 50MB wp default
  local reserve=$(( ram*12/100 )); [ $reserve -lt 512 ] && reserve=512
  local pool=$(lso_innodb_pool $ram) redis=$(lso_redis_mb $ram) opcache=$(lso_opcache_mb $ram)
  local avail=$(( ram - reserve - pool - redis - opcache - 150 ))   # 150MB lsws+misc
  local n=$(( avail / rss ))
  local cpu_cap=$(( cores * 8 ))
  [ $n -gt $cpu_cap ] && n=$cpu_cap
  [ $n -lt 8 ] && n=8
  echo $n
}
```
Tier-lookup functions return the SYNTHESIS §2 table values (`lso_innodb_pool`: 256/512/1280/2816 MB; `lso_redis_mb`: 64/128/384/768; `lso_opcache_mb`: 64/128/256/256; AVOID_FORK 0/200M/500M/1; etc.). If lsphp processes are running, measured avg RSS overrides the default. Sanity assertion printed in analyze/optimize: `reserve+pool+redis+opcache+children*rss ≤ 0.9*RAM`.

---

## 9. Out of scope for v0.1

- ModSecurity/OWASP CRS install (detect+report only) — false-positive risk on checkout.
- reCAPTCHA/CAPTCHA auto-config (needs user keys) — report with instructions.
- QUIC.cloud CDN onboarding (`wp litespeed-online ...`), image optimization, UCSS/CCSS.
- LSWS Enterprise `tuning{}` editing (XML) — report recommended values only.
- DirectAdmin/RunCloud server-config writes (manual-steps output only).
- HPOS migration execution (report `wp wc hpos status`, print commands; too stateful to auto-run).
- fail2ban setup, honeypot/tarpit, bad-bot blocker (nginx-optimizer parity features → v0.2+).
- Multi-server, LiteSpeed Web ADC, Plesk, Enhance panel.
- k6/wrk load benchmarking (curl TTFB only in v0.1).
- Installing LiteSpeed itself (that's ols1clk's job — require existing install).

---

## 10. Test strategy

Mirror nginx-optimizer's plain-bash `tests/run-tests.sh` (no bats — keep toolchain identical to the sibling project):
1. **Static**: shellcheck severity=error gate (+warning count informational); bash 3.2 `bash -n`; portability greps (no `declare -A`, `flock`, `find -printf`).
2. **Functional, no server needed**: `--version`, `help`, `detect` on a fixture tree. Use `LSO_LSWS_ROOT` overridable env so tests point at `tests/configs/<fixture>/usr/local/lsws/` fake trees (plain-OLS, cyberpanel-marker, cpanel-marker, enterprise-xml, broken-edge-cases). Assert edition/panel/paths.
3. **Golden config-generation tests** (the core safety net without a real server): run `optimize --dry-run`-internals against fixtures with `LSO_RAM_MB`/`LSO_CORES` forced (1024/1, 2048/2, 4096/4, 8192/8); generated include files + edited fixture configs diffed against `tests/golden/<fixture>-<tier>/`. Covers formulas, the maxConns==CHILDREN invariant (explicit assertion), enableCache never 1 at server level (explicit grep assertion).
4. **confedit unit tests**: ols_set/ols_get round-trip on fixture configs incl. nested blocks, missing blocks, comments, CRLF.
5. **Backup/rollback test**: apply to fixture tree, corrupt, rollback, `diff -r` equals original.
6. **Optional Docker integration** (`test-with-ols-docker.sh`, skipped when docker absent — same pattern as nginx-optimizer's `test-with-nginx.sh`): `docker run litespeedtech/openlitespeed:latest`, copy tool in, run `detect`/`analyze`/`optimize --dry-run` then real `optimize` for server-tuning+lsapi, assert lswsctrl status running and WebAdmin 7080 responds. LSWS Enterprise cannot be docker-tested freely → Enterprise code paths covered by fixtures/golden only (document this).
7. **LSCWP profile lint**: parse `templates/lscwp/*.txt` keys against a vendored snapshot of `wp litespeed-option all` key list; fail on unknown keys.

---

## 11. Phased task breakdown (delegation-ready)

**Phase 1 — scaffold + detect + backup (foundation, no live edits)**
- T1.1 Repo scaffold, entrypoint with arg parsing/lock/logging/help (port nginx-optimizer.sh skeleton), CLAUDE.md, shellcheck CI.
- T1.2 Port `lib/registry.sh`, `lib/core/{helpers,sysinfo,templates}.sh`; add `lso_children` + tier lookups (§8).
- T1.3 `detect-env.sh` + `detect` command + fixtures for 5 environments + tests.
- T1.4 `confedit.sh` OLS primitives + unit tests.
- T1.5 `backup.sh` + `rollback` + `validator.sh` restart-or-rollback + `check` command + tests.
- Exit criteria: `detect`, `check`, `rollback --list` work on fixtures; test suite green.

**Phase 2 — server tuning (OLS write path, LSWS report path)**
- T2.1 `server-tuning` feature + OLS templates + golden tests for 4 tiers.
- T2.2 `lsapi-tuning` (incl. invariant assertion + AVOID_FORK tier logic) + golden tests.
- T2.3 `opcache`, `os-limits` features; `$LSO_PHP_RESTART` plumbing.
- T2.4 `http3` verify feature; `optimize --dry-run/--profile generic` end-to-end; `status` command.
- T2.5 Docker OLS integration test for the above.
- Exit criteria: `optimize --profile generic` on docker OLS passes health check; rollback verified.

**Phase 3 — WordPress/WooCommerce (LSCWP + cache)**
- T3.1 `lscache` feature: OLS vhost cache module + LSWS CacheRoot/CacheEngine/CacheLookup includes; danger-guard asserting `enableCache 0` server level.
- T3.2 LSCWP profiles (`templates/lscwp/*.txt`) authored from SYNTHESIS §5 + profile lint test.
- T3.3 `lscwp` feature: plugin install/version gate (≥6.5.1), option export (backup) → import → purge.
- T3.4 `redis` + `mariadb` features + golden tests.
- T3.5 `woocommerce` feature: ESI-on-Enterprise / warn-on-OLS, crawler setup, cookie-trap + multi-currency checks, optional `--db-hygiene`.
- Exit criteria: against a wp-test-style WP+Woo on docker OLS, `optimize --profile woocommerce` yields `x-litespeed-cache: hit` on product page, `no-cache` on cart/checkout.

**Phase 4 — security + analyze + benchmark + polish**
- T4.1 `security` feature (throttling, headers, xmlrpc, WordPressProtect include, CVE gate).
- T4.2 `analyzer.sh` scored audit (§3) + `--json`; danger findings cap.
- T4.3 `benchmark.sh` (curl ×10 median: dns/connect/tls/ttfb; cached vs uncached vs cart URL; cache-hit-ratio header check; before/after store in data dir).
- T4.4 README (mirror nginx-optimizer README structure), install.sh, ROADMAP (v0.2: ModSec, CAPTCHA, fail2ban, QUIC.cloud, DA/RunCloud write paths, k6).
- Exit criteria: full test suite + docker E2E green; shellcheck clean; `analyze` produces a defensible score on an untuned vs tuned box.
