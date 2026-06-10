# litespeed-optimizer — Consolidated Research Synthesis

Synthesized 2026-06-10 from 7 research reports (`01-server-tuning.md`, `02-lscache-woocommerce.md`, `03-stack-tuning.md`, `04-landscape.md`, `05-grok-research.md`, `06-gemini-research.md`, `07-openrouter-research.md`).
Where reports conflicted, the claim verified against shipped defaults / official docs (reports 01–03, which cite `httpd_config.conf.in` and docs.litespeedtech.com) wins over LLM-generated reports (05, 06).

---

## 1. Conflicts found & resolutions

| # | Topic | Conflicting claims | Resolution |
|---|---|---|---|
| C1 | `maxConnections` per tier | 06 (Gemini): 500–1000 on 1 GB, license caps 500/800 always apply. 01: shipped default 10000 is fine; only *legacy* licenses are capped, current LSWS licenses (Free Starter/Site Owner/Web Host) have **no connection cap**; bottleneck is lsphp workers, not connections | **Follow 01** (verified vs shipped config + license docs). Use 2000/5000/10000/10000 per tier; never present maxConnections as the PHP-capacity lever |
| C2 | `maxKeepAliveReq` | 06: 100–150. 01: keep ≥1000 (WP pages load dozens of assets; 0/1 disables keep-alive) | **Follow 01**: ≥1000, default 10000 OK |
| C3 | `LSAPI_AVOID_FORK=0` semantics | 06: "CHILDREN effectively divided by 3, so set 3× desired". 01/03: that's a garbled reference to `LSAPI_MAX_IDLE_CHILDREN` defaulting to CHILDREN/3; AVOID_FORK only controls idle-kill vs keep-resident | **Follow 01** (doc-verified). Critical extra fact (01, 07): bare `AVOID_FORK=1` requires ≥1 GB *free* RAM or silently behaves like 0 — use size form `=200M`/`=500M` on small boxes |
| C4 | `woocommerce_items_in_cart` cookie | 05 (Grok): add `woocommerce_cart_hash;woocommerce_items_in_cart` to "Do Not Cache Cookies". 02: **never do that** — LSCWP already varies on it; excluding disables caching for everyone with a cart (LiteSpeed's own blog calls this out) | **Follow 02**. The tool must actively *check for and warn about* this misconfiguration, not apply it |
| C5 | `opcache.validate_timestamps` | 05: `=0` in prod. 03: `=1` + `revalidate_freq=60` — WP auto-updates/wp-admin plugin updates serve stale code with 0 | **Follow 03** for a tool targeting arbitrary client sites; `0` only behind a `--i-deploy-via-pipeline` style flag (out of scope v0.1) |
| C6 | `opcache.enable_cli` | 06: `1`. 03: `0` | **Follow 03** (`0`); CLI opcache buys little and costs RAM per invocation |
| C7 | LSWS Enterprise main config path | 05/06: "frequently `httpd_config.conf` or Apache `httpd.conf`". 01: Enterprise = **XML** `httpd_config.xml`, plus the ability to read Apache configs; XML is GUI-managed, don't script it | **Follow 01**: detect XML; automate Enterprise via Apache-style include files / .htaccess, never edit the XML |
| C8 | Throttling param names | 06 uses `connectionSoftLimit`, `dynamicReqPerSec`, `bannedPeriod`. 01 (verified vs shipped config) uses `softLimit`, `hardLimit`, `dynReqPerSec`, `staticReqPerSec`, `gracePeriod`, `banPeriod`, `blockBadReq` | **Follow 01's names** — these are what the shipped `perClientConnLimit { }` block actually uses |
| C9 | wp-cli purge subcommands | 06 invents `wp litespeed-purge woocommerce/ccss/opcache/object`. 02 lists the doc-verified set (`all`, `url`, `post_id`, `category`, `tag`, `blog`) | **Follow 02's command list**; treat anything else as unverified — probe with `--help` at runtime |
| C10 | "Cache Logged-in Users" | 05: usually OFF. 02: ON with ESI / OFF on low-RAM or OLS | **Merge**: ON only when ESI available (Enterprise/QUIC.cloud) and RAM ≥ 4 GB; OFF otherwise. Matches both |
| C11 | PHP worker RSS assumption | 06 assumes 120 MB/child flat; 01: 30–60 MB vanilla WP, 80–150 MB Woo; 03: use 70–80 MB Woo planning figure, measure with `ps` | **Follow 03**: plan with 80 MB for Woo profile, 50 MB for WordPress profile, then correct from measured `ps -ylC lsphp --sort:rss` when lsphp procs exist |

Reports 04 and 07 contained no conflicts (landscape + summary of 01).

---

## 2. Master tuning table per RAM tier

Assumes single-box stack: LSWS/OLS + lsphp + MariaDB + Redis, WordPress/WooCommerce, LSCache enabled. Memory budget rule (03): **OS reserve → InnoDB buffer pool → lsphp pool → Redis + opcache**, sanity check `reserve + buffer_pool + redis + opcache + children×80MB ≤ 0.9 × RAM`.

### 2.1 LiteSpeed server (`tuning { }` block / WebAdmin Tuning)

| Param | 1 GB / 1 vCPU | 2 GB / 2 vCPU | 4 GB / 2–4 vCPU | 8 GB+ / 4–8 vCPU |
|---|---|---|---|---|
| `maxConnections` | 2000 | 5000 | 10000 (default) | 10000 |
| `maxSSLConnections` | = maxConnections | = | = | = |
| `connTimeout` | 30 | 30 | 60 | 60 |
| `keepAliveTimeout` | 2 | 3 | 5 | 5 (2–3 + `smartKeepAlive 1` if very busy) |
| `maxKeepAliveReq` | 1000 | 5000 | 10000 (default) | 10000 |
| `smartKeepAlive` | 0 | 0 | 0 | 0 (1 only near maxConnections) |
| `sndBufSize` / `rcvBufSize` | 0 (OS default) | 0 | 0 | 0 |
| `totalInMemCacheSize` | 20M | 32M | 64M | 128M–256M |
| `maxCachedFileSize` | 4096 | 4096 | 16K | 64K |
| `totalMMapCacheSize` | 40M | 40M | 80M | 160M |
| `useSendfile` | 1 | 1 | 1 | 1 |
| `enableGzipCompress` | 1 | 1 | 1 | 1 |
| `enableBrCompress` (dynamic) | 2 | 2 | 4 | 4 |
| `gzipCompressLevel` (dynamic) | 6 | 6 | 6 | 6 |
| `gzipAutoUpdateStatic` | 1 | 1 | 1 | 1 |
| `gzipStaticCompressLevel` / `brStaticCompressLevel` | 6 / 5 | 6 / 5 | 9 / 6 | 9 / 8 |
| `maxReqBodySize` | 100M | 100M | 100M | 100M (WP media) |

### 2.2 LSAPI / lsphp (`extprocessor lsphp` block / External App)

**Invariant: `maxConns` == `PHP_LSAPI_CHILDREN`. Always. Mismatch ⇒ 508s or zombie children.**
Mode: ProcessGroup (`instances 1`, CHILDREN > 1) — shares one opcache SHM across children.

| Param | 1 GB | 2 GB | 4 GB | 8 GB+ |
|---|---|---|---|---|
| `maxConns` = `PHP_LSAPI_CHILDREN` | 10 | 15 (Woo) – 25 (WP) | 35 | 60 |
| `LSAPI_AVOID_FORK` | 0 | 200M | 500M | 1 |
| `LSAPI_MAX_REQS` (`PHP_LSAPI_MAX_REQUESTS`) | 1000 | 1000 | 5000 | 10000 |
| `LSAPI_MAX_IDLE` | 60 | 300 | 300 | 3600 |
| `LSAPI_PGRP_MAX_IDLE` | (default) | 3600 | 3600 | 3600 — keeps parent + opcache warm |
| `LSAPI_MAX_PROCESS_TIME` | 300 | 300 | 600 | 600 |
| `LSAPI_ACCEPT_NOTIFY` | 1 | 1 | 1 | 1 |
| `LSAPI_SLOW_REQ_MSECS` | 5000 | 5000 | 5000 | 5000 (free slow-req profiler) |
| `extMaxIdleTime` | 60 | 300 | 3600 | 3600 |
| `memSoftLimit` / `memHardLimit` | 300M / 350M | 512M / 512M | 1024M / 1024M | 2047M (default) |
| `initTimeout` / `retryTimeout` / `persistConn` / `backlog` | 60 / 0 / 1 / 100 (keep defaults) | — | — | — |

Children formula (when refining from measurement):
```
CHILDREN = clamp( (RAM_total − OS_reserve − innodb_pool − redis − 150M_lsws) / avg_lsphp_RSS,
                  min=8, max=cores*8 )
OS_reserve   = max(512MB, 12% RAM)
avg_lsphp_RSS = measured via `ps -ylC lsphp --sort:rss`, else 80MB (woocommerce) / 50MB (wordpress)
```
Feedback signals: WebAdmin Real-Time Stats **WaitQ > 0** sustained ⇒ raise children; error.log "Reached max children process limit" ⇒ raise children; swap usage ⇒ lower.

### 2.3 PHP ini / opcache (per active lsphp version)

| Param | 1 GB | 2 GB | 4 GB | 8 GB+ |
|---|---|---|---|---|
| `memory_limit` | 256M | 256M | 256M (WP) / 512M (Woo) | 512M |
| `opcache.memory_consumption` | 64 | 128 | 192 (WP) / 256 (Woo) | 256 |
| `opcache.max_accelerated_files` | 20000 | 20000 | 50000 | 50000 |
| `opcache.interned_strings_buffer` | 16 | 16 | 32 | 32 |
| `opcache.validate_timestamps` / `revalidate_freq` | 1 / 60 | 1 / 60 | 1 / 60 | 1 / 60 |
| `opcache.save_comments` | 1 (REQUIRED — WP annotations) | 1 | 1 | 1 |
| `opcache.enable_cli` | 0 | 0 | 0 | 0 |
| `opcache.jit` | off (Woo is I/O-bound) | off | off | off |
| `max_execution_time` | 120 | 120 | 300 | 300 |

Apply path varies by panel (§4). After edit: `touch /usr/local/lsws/admin/tmp/.lsphp_restart.txt` (lsphp respawns, no full restart).

### 2.4 Redis (`redis.conf`)

| Param | 1 GB | 2 GB | 4 GB | 8 GB+ |
|---|---|---|---|---|
| `maxmemory` | 64mb | 128mb | 256–512mb | 512mb–1gb |
| `maxmemory-policy` | allkeys-lru | allkeys-lru | allkeys-lru | allkeys-lru |
| transport | 127.0.0.1 TCP | unix socket if feasible | unixsocket `/var/run/redis/redis.sock`, perm 770 | unix socket |
| persistence | `save ""`, `appendonly no` (pure cache; sessions persist in MariaDB) | — | — | — |
| extras | — | — | `io-threads 2` (4+ cores, Redis ≥6), `lazyfree-lazy-eviction yes` | same |

`allkeys-lru` is mandatory for WP object cache (most keys have no TTL ⇒ `volatile-lru` would OOM-on-write). If PHP sessions also live in Redis, that must be a **separate instance** with `volatile-lru`/`noeviction` + persistence. Health: `evicted_keys ≈ 0` steady-state — evictions are the root cause of "cart randomly empties".

### 2.5 MariaDB (`99-woocommerce.cnf`)

| Param | 1 GB | 2 GB | 4 GB | 8 GB+ |
|---|---|---|---|---|
| `innodb_buffer_pool_size` | 256M | 512M | 1024–1536M | 2.5–3G |
| `innodb_log_file_size` | 64M | 128M | 256M | 512M |
| `innodb_flush_method` | O_DIRECT | O_DIRECT | O_DIRECT | O_DIRECT |
| `innodb_flush_log_at_trx_commit` | 1 (orders = ACID; never lower on a store) | 1 | 1 | 1 |
| `tmp_table_size` = `max_heap_table_size` | 32M | 32M | 64M | 64M |
| `table_open_cache` | 2000 | 2000 | 4000 | 4000 |
| `max_connections` | bounded by lsphp children + slack: children+20 | children+20 | children+20 | children+20 |
| `slow_query_log` / `long_query_time` | 1 / 0.5 | 1 / 0.5 | 1 / 0.5 | 1 / 0.5 |
| `performance_schema` | OFF | OFF | OFF | default |

### 2.6 OS

All tiers: `LimitNOFILE=65535` via systemd override `/etc/systemd/system/lsws.service.d/override.conf` (limits.d alone does NOT bind systemd services); sysctl `/etc/sysctl.d/99-litespeed.conf`: `net.core.somaxconn=4096`, `tcp_max_syn_backlog=8192`, `tcp_fin_timeout=15`, `tcp_tw_reuse=1`, `tcp_slow_start_after_idle=0`, `default_qdisc=fq` + `tcp_congestion_control=bbr` (if kernel supports), `vm.swappiness=10`, `vm.vfs_cache_pressure=50`. Swap: 2–4 GB safety net, alert if used.

---

## 3. LSWS Enterprise vs OpenLiteSpeed capability matrix

| Capability | OLS | LSWS Enterprise | Tool behavior |
|---|---|---|---|
| Main config | plain-text `/usr/local/lsws/conf/httpd_config.conf` (`block { key value }`) | XML `/usr/local/lsws/conf/httpd_config.xml` + reads Apache configs | OLS: edit native config via `include` files. LSWS: write Apache-style includes / .htaccess, never touch the XML |
| `.htaccess` | rewrites only, restart to pick up | full Apache directives, auto-detected, no restart | LSWS path can drop cache/security directives into .htaccess safely |
| **ESI** (mini-cart hole punching) | ✗ (only via QUIC.cloud CDN) | ✓ (`CacheEngine on esi`) | Enable ESI on Enterprise; on OLS warn + fall back (cart-fragment dequeue / vary) |
| Crawler engine | ✓ (cache module) | ✓ (`CacheEngine ... crawler`) | Enable both; LSCWP needs server-side crawler enabled |
| LSCache config | `module cache { }` blocks in native config | `CacheRoot` / `CacheEngine` / `CacheLookup` Apache directives | Two code paths in cache module |
| `WordPressProtect` (brute-force) | ✗ | ✓ (`WordPressProtect drop, 10`) | Enterprise only; OLS: skip (suggest fail2ban) |
| ModSecurity | ModSec **3.x** engine via `module mod_security` | proprietary async engine, ModSec **2.9** syntax, OWASP CRS/Comodo/Imunify | Different rule-install paths; v0.1: detect + report only |
| reCAPTCHA/hCaptcha protection | ✓ | ✓ (≥5.4) | Configurable both; v0.1: report, apply behind flag |
| Per-client throttling (`perClientConnLimit`) | ✓ | ✓ | Same block both editions |
| HTTP/3 (LSQUIC) | ✓ (≥1.7, default on) | ✓ (≥5.4, default on) | Verify listener + UDP 443 + CSF UDPFLOOD=0 |
| License connection caps | n/a | legacy VPS=500/Ultra=800 only; current licenses uncapped | Detect license tier if readable; warn if legacy |
| lswsctrl / WebAdmin :7080 / `.lsphp_restart.txt` | ✓ | ✓ | Shared apply/restart path |

---

## 4. Environment detection logic

```
1. LiteSpeed present?      [ -x /usr/local/lsws/bin/lswsctrl ]   (also try /opt/lsws)
2. Edition:
     primary:  [ -f $LSWS_ROOT/conf/httpd_config.xml ]   → LSWS Enterprise
               elif [ -f $LSWS_ROOT/conf/httpd_config.conf ] → OLS
     confirm:  $LSWS_ROOT/bin/lshttpd -v | grep -qi 'Open' → OLS; 'Enterprise'/'LiteSpeed/' → LSWS
     extra:    [ -s $LSWS_ROOT/conf/serial.no ] or license.key present → Enterprise
3. Panel (order matters):
     CyberPanel:  [ -d /usr/local/CyberCP ] (or lscpd service)        → OLS native conf authoritative
     cPanel:      [ -d /usr/local/cpanel ]                            → LSWS via Apache EA4 configs
     DirectAdmin: [ -d /usr/local/directadmin ]                       → DA CustomBuild-managed
     RunCloud:    [ -d /etc/runcloud ] or /RunCloud markers           → OLS, panel-managed conf
     else:        plain
4. Running?     pgrep -f 'litespeed|lshttpd' ; systemctl is-active lsws/lshttpd
5. PHP:         resolve lsphp binaries: /usr/local/lsws/lsphp*/bin/lsphp (CyberPanel/RunCloud/plain),
                /opt/cpanel/ea-php*/root/usr/bin/lsphp (cPanel), /usr/local/php*/ (DirectAdmin).
                php.ini path: `<lsphp> -i | grep 'Loaded Configuration File'` — NEVER hardcode.
6. WordPress:   given --site path or scan vhost docroots for wp-config.php; wp-cli available?
7. Hardware:    RAM /proc/meminfo, cores nproc; measured lsphp RSS via ps if processes exist.
8. Stack:       redis-cli ping; mysqld/mariadbd present; CSF (/etc/csf) vs ufw vs firewalld;
                QUIC reachability (ss -ulnp | grep :443).
```

Config paths matrix (from 03 §6):

| Env | Server conf | Vhost conf | php.ini | Safe edit mechanism | Restart |
|---|---|---|---|---|---|
| CyberPanel (OLS) | `/usr/local/lsws/conf/httpd_config.conf` | `/usr/local/lsws/conf/vhosts/<domain>/vhost.conf` | `/usr/local/lsws/lsphpXX/etc/php/X.X/litespeed/php.ini` | native conf + `include` files; `phpIniOverride { }` in vhost | `.lsphp_restart.txt` / `systemctl restart lsws` |
| cPanel + LSWS | `httpd_config.xml` (don't touch) + Apache EA4 | `/etc/apache2/conf.d/userdata/...` | `/opt/cpanel/ea-phpXX/root/etc/php.ini` | `/etc/apache2/conf.d/includes/pre_main_global.conf`, .htaccess | `/scripts/restartsrv_lsws` |
| DirectAdmin | `/usr/local/lsws/conf/` + DA templates | DA-generated includes | `/usr/local/phpXX/lib/php.ini` | DA "Custom HTTPd Configurations" only (CustomBuild overwrites direct edits) | `systemctl restart lsws` |
| RunCloud (OLS) | `httpd_config.conf` (panel-managed) | per-app via panel | `/usr/local/lsws/lsphpXX/etc/php/X.X/...` | `PHP_INI_SCAN_DIR` env, panel hooks; direct edits may be regenerated | panel / systemctl |
| Plain OLS | `httpd_config.conf` | `conf/vhosts/<name>/vhconf.conf` | `/usr/local/lsws/lsphpXX/etc/php/X.X/litespeed/php.ini` | native conf, `include` files preferred | `lswsctrl restart` (graceful) |

Panel rule: on cPanel/DA, tune through panel-safe mechanisms or **report manual steps with exact values** instead of editing files that get regenerated.

---

## 5. WooCommerce automation list (LSCWP)

LSCWP auto-handles (don't duplicate): cart/checkout/my-account exclusion, `woocommerce_items_in_cart` vary cookie, core ESI nonces.

Tool-applied settings (via `wp litespeed-option set` / `import`):

| Key (LSCWP option) | woocommerce profile | wordpress profile |
|---|---|---|
| `cache` (Enable Cache) | 1 | 1 |
| `cache-priv` (logged-in users) | 1 if ESI avail & RAM≥4 GB, else 0 | 0 |
| `cache-commenter` | 0 | 0 |
| `cache-rest` | 1 | 1 |
| `cache-mobile` | 0 (unless AMP/mobile theme detected) | 0 |
| `cache-ttl-pub` | 604800 | 604800 |
| `cache-ttl-priv` | 1800 | 1800 |
| `cache-ttl-frontpage` | 86400 | 604800 |
| Serve Stale | 1 | 1 |
| Purge All on Upgrade | 1 | 1 |
| Woo Product Update Interval | purge on qty/stock-status change | n/a |
| Vary for Mini Cart | 0 with ESI; 1 on OLS if theme mini-cart stale | n/a |
| `esi` (Enterprise/QUIC.cloud only) | 1 + Cache Admin Bar 1 + Comment Form 1 | optional |
| Object cache | method=redis, host/port or unix socket, **lifetime ≥ 600** (default 360 breaks Woo sessions/password resets), persistent=1 | same |
| CSS/JS/HTML minify | 1 | 1 |
| CSS Combine / UCSS / JS Combine / JS Defer-Delay | **0** (breaks add-to-cart, gateways) | 0 (conservative) |
| Lazy-load images | 1, exclude LCP/product gallery | 1 |
| Guest Mode | 1 | 1 |
| Guest Optimization | **0** (UCSS file explosion, geo/currency breakage) | 0 |
| Crawler | enable, sitemap = `wp-sitemap.xml` (or Yoast/RankMath sitemap if detected), threads 3, server load limit 1.0, **no role simulation** (CVE-2024-28000 surface) | optional |
| Debug log | OFF (CVE-2024-44000) | OFF |

wp-cli surface (verified, 02): `wp litespeed-option all|get|set|export|import|import_remote|reset`, `wp litespeed-presets apply|get_backups|restore`, `wp litespeed-purge all|url|post_id|category|tag`, `wp litespeed-crawler list|enable|disable|run|reset`, `wp litespeed-database clear_transients|clear_posts|optimize_tables|optimize_all`, `wp litespeed-image ...`, `wp litespeed-online ...`.

Workflow: install/activate plugin → `litespeed-option import <profile-file>` (idempotent config-as-code; nobody else ships profiles — key differentiator per 04) → server-side ESI/crawler enablement → `wp litespeed-purge all` → `wp litespeed-crawler run`.

App-level extras (woocommerce profile, optional steps): HPOS (`wp wc hpos status/sync/enable`), lookup tables (`wp wc palt regenerate`), Action Scheduler purge + retention filter, transient cleanup, autoload audit (<1 MB target), `wp_woocommerce_sessions` expiry purge. Cart fragments: detect `wc-cart-fragments` handle; on Enterprise rely on ESI; on OLS report conditional-dequeue guidance.

---

## 6. Security hardening checklist

1. **Per-client throttling** (both editions, `perClientConnLimit`): `dynReqPerSec 2`, `staticReqPerSec 40`, `softLimit 15`, `hardLimit 20`, `gracePeriod 15`, `banPeriod 300`, `blockBadReq 1`. Caveat: NAT'd offices can trip `dynReqPerSec` — support `--trusted-ip` whitelist via `accessControl`.
2. **connTimeout 30–60** (slowloris resistance) — part of server tuning.
3. **CAPTCHA protection** (reCAPTCHA/hCaptcha, both editions): enable with Connection Limit lowered to slightly above normal peak so it actually triggers; keep Bot White List for Googlebot. v0.1: report-only unless keys provided.
4. **WordPressProtect drop, 10** — Enterprise only (.htaccess/include). OLS: recommend fail2ban on access log.
5. **ModSecurity + OWASP CRS** — Enterprise: async engine, 2.9 syntax; OLS: ModSec 3 module + CRS in `/usr/local/lsws/conf/owasp/`. High false-positive risk on Woo AJAX/checkout ⇒ v0.1 detect/report, apply later.
6. **Security headers** (.htaccess on LSWS / vhost context on OLS): `X-Content-Type-Options nosniff`, `X-Frame-Options SAMEORIGIN`, `Referrer-Policy strict-origin-when-cross-origin`, HSTS (only when HTTPS verified).
7. **xmlrpc.php**: block/403 unless Jetpack-style use detected.
8. **LSCWP CVE hygiene**: plugin version ≥ 6.5.1 (CVE-2024-28000 privesc ≤6.3.0.1, CVE-2024-44000 debug-log takeover <6.5.0.1, CVE-2024-47374 XSS ≤6.5.0.2); Debug Log OFF; crawler role simulation OFF; block `*.log` and `wp-content/debug.log` at server level; auto-update LSCWP recommended.
9. **HTTP/3 firewall**: UDP 443 open AND CSF `UDPFLOOD = 0` (else QUIC is rate-killed to ~10 pps).
10. **WebAdmin :7080**: check it isn't world-open with default creds; recommend IP-restricting.

---

## 7. Top-10 optimizations ranked by impact (merged 01/03/04/05/06)

1. **LSCache full-page cache wired correctly** — vhost cache module/CacheRoot + LSCWP driving via headers; most traffic never reaches PHP. Verify `x-litespeed-cache: hit`.
2. **lsphp pool sizing** — `maxConns` = `PHP_LSAPI_CHILDREN` per RAM formula, ProcessGroup mode, `LSAPI_AVOID_FORK` per tier. Governs every uncached request (checkout!).
3. **OPcache sized + ProcessGroup sharing + `LSAPI_PGRP_MAX_IDLE=3600`** — idle-kill destroys opcache; warm parent saves 300–800 ms per cold hit.
4. **Redis object cache** (LSCWP module, lifetime ≥600 s, allkeys-lru) — uncached TTFB typically halves (400–800 ms → <200 ms).
5. **ESI for WooCommerce** (Enterprise/QUIC.cloud) — public-caches product pages while mini-cart stays private; kills cart-fragments AJAX. On OLS: fragment-dequeue fallback.
6. **Crawler warmup + Serve Stale + tag-based auto-purge** — high hit ratio sustained through purges.
7. **MariaDB buffer pool + DB hygiene** (autoload <1 MB, Action Scheduler purge, sessions table, lookup tables, HPOS).
8. **Static delivery**: Brotli+gzip with `gzipAutoUpdateStatic`, HTTP/2+3 verified (UDP 443/CSF), browser cache TTLs.
9. **Security throttling/CAPTCHA/WordPressProtect** — stops bots from eating the lsphp pool (perf feature as much as security).
10. **OS limits**: systemd `LimitNOFILE`, somaxconn, swappiness — silent under-burst failures otherwise.

---

## 8. Pitfalls / danger list (the tool must guard against these)

1. **`enableCache 1` server-wide** — force-caches everything incl. carts; PHP-driven exclusions ignored. Correct: `enableCache 0` at server level, `ignoreRespCacheCtrl 0`, LSCWP drives via `X-LiteSpeed-Cache-Control`.
2. **`AVOID_FORK=1` on <1 GB free RAM** — silently degrades to 0; on tight boxes it can also cause OOM. Use size form (`=200M`).
3. **`maxConns` ≠ `PHP_LSAPI_CHILDREN`** — queuing 508s or zombie processes.
4. **Adding `woocommerce_items_in_cart` to Do-Not-Cache Cookies** — disables caching for every visitor with a cart (C4). Tool should detect and offer to remove.
5. **Cart cache poisoning**: missing vary on third-party cart cookies, Cloudflare "cache everything" in front of LSCache (ignores vary cookies — QUIC.cloud is the only safe HTML CDN), Woo page mis-association (cart/checkout slugs wrong in WC settings), themes with non-AJAX cart widgets. Mandatory post-change verification: two-browser cart isolation test.
6. **Pure geo-IP pricing is incompatible with page cache** — first visitor's locale cached for all; needs cookie-vary, ESI, or exclusion. Detect multi-currency plugins (CURCY/WOOCS/WCML) and ensure currency cookie in Vary Cookies.
7. **Vary explosion** — currencies × mobile × webp × roles multiply cache copies; UCSS + Guest Optimization = file/inode explosion.
8. **Short `LSAPI_PGRP_MAX_IDLE` / idle teardown kills opcache** between bursts.
9. **Object cache lifetime <600 s** breaks Woo session validation/password resets; Redis eviction (`evicted_keys` > 0) ⇒ "cart empties randomly".
10. **JS Combine/Defer/UCSS on stores** — breaks add-to-cart, variation swatches, Stripe/PayPal SDKs. Never auto-enable.
11. **Scripting the LSWS XML** — GUI-managed; restart-validated; gets clobbered. Apache includes only.
12. **Panel regeneration clobbering** — DA CustomBuild and RunCloud regenerate configs; only use their custom-include hooks.
13. **`lswsctrl restart` breaks Enhance panel v12** (PID conflict) — webdighost/cPFence known bug; prefer `systemctl` where unit exists.
14. **Debug Log left ON** (CVE-2024-44000 class), crawler role simulation ON (CVE-2024-28000 class).
15. **`opcache.validate_timestamps=0`** on auto-updating WP serves stale code after updates.
16. **Config file ownership**: OLS conf must stay readable by `lsadm` — preserve owner/perms when writing.
17. **CSF UDPFLOOD** silently throttles QUIC — "HTTP/3 enabled but slow" trap.
18. **Editing `# BEGIN LiteSpeed` .htaccess block by hand** — LSCWP regenerates it; it must precede the WordPress block.
