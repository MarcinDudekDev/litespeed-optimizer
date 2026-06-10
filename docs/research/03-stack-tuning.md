# Full-Stack Tuning Around LiteSpeed for WooCommerce
## PHP (lsphp), Redis, MySQL/MariaDB, WooCommerce app-level, OS, control panels, RAM sizing, benchmarking

> Research compiled 2026-06-10. Part 3 of the LiteSpeed research series.
> Focus: concrete values and formulas usable by a tooling/automation script.

---

## 1. lsphp (LSAPI PHP) specifics

### 1.1 How lsphp differs from php-fpm

- LiteSpeed (both Enterprise LSWS and OpenLiteSpeed) does **not** use PHP-FPM. It runs PHP via the **LSAPI** protocol (`lsphp` binary), which is faster and lighter than FastCGI/php-fpm — LSWS only supports lsphp, not php-fpm integration ([LiteSpeed wiki: PHP](https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:php), [LSWS forum: LiteSpeed vs PHP-FPM](https://www.litespeedtech.com/support/forum/threads/litespeed-vs-php-fpm.18194/)).
- Key architectural difference vs php-fpm: **on-demand process spawning** instead of pre-forked static/dynamic pools. Modes ([LSPHP Modes docs](https://docs.litespeedtech.com/lsws/extapp/php/configuration/modes/)):
  - **Worker mode** (`LSAPI_CHILDREN=1` per extApp, LSWS spawns N copies): processes spawned/killed as needed. Does **not** effectively share opcache between processes.
  - **ProcessGroup mode** (`LSAPI_CHILDREN > 1`): one parent PHP process per user/vhost forks children. Behaves like a dynamic on-demand php-fpm pool and **is opcache-friendly** (children forked from the same parent share the opcache SHM) — as long as the group isn't killed for idling.
  - **Detached mode** (default since LSWS 5.3): PHP process groups survive LSWS restarts; still subject to Max Idle Time.
  - **Daemon mode** (OLS-style): single persistent parent; also opcache-sharing-friendly with suEXEC.
- Practical consequences a tuning script must know:
  - The php-fpm equivalents map as: `pm.max_children` → `LSAPI_CHILDREN` / "PHP suEXEC Max Conn" (control panels); `pm.max_requests` → `LSAPI_MAX_REQS` (`PHP_LSAPI_MAX_REQUESTS`) — recycles a child after N requests to contain memory leaks ([LSPHP Options docs](https://docs.litespeedtech.com/lsws/extapp/php/configuration/options/)).
  - **Idle kill destroys opcache.** If `LSAPI_PGRP_MAX_IDLE` / Max Idle Time is short, the whole process group (and its opcache) dies between bursts → first uncached WooCommerce hit pays a full recompile (often +300–800 ms). LiteSpeed's own performance doc recommends per-vhost: `LS_EXTAPP_ENV LSAPI_PGRP_MAX_IDLE=3600` inside `<IfModule LiteSpeed>` to keep the group (and opcache) warm ([LSWS PHP performance docs](https://docs.litespeedtech.com/lsws/extapp/php/performance/)).
  - "Reached max children process limit: please increase LSAPI_CHILDREN" in `stderr.log` = concurrency ceiling hit. On control panels raise **PHP suEXEC Max Conn** (default 10; 15–20 if RAM allows) rather than the raw env var ([Tuning guide for shared hosting](https://docs.litespeedtech.com/lsws/tuning-shared/), [Plesk KB](https://support.plesk.com/hc/en-us/articles/27335062060055-Plesk-with-LiteSpeed-poor-performance-Reached-max-children-process-limit-please-increase-LSAPI-CHILDREN)).
  - `LSAPI_SLOW_REQ_MSECS=10000` logs PHP requests slower than 10 s to stderr.log — cheap built-in slow-request profiler ([performance docs](https://docs.litespeedtech.com/lsws/extapp/php/performance/)).
  - Watch **WaitQ** in the real-time stats panel: nonzero WaitQ under normal load = raise children/Max Conn.

### 1.2 OPcache for WooCommerce on lsphp

WooCommerce + theme + 25–40 plugins easily compiles 60–150 MB of scripts; default 128 MB opcache is marginal, defaults for `max_accelerated_files` (10000) are too low.

Recommended production block (php.ini for the lsphp version in use):

```ini
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256        ; 192–256 MB for typical Woo; 512 for very large stores
opcache.interned_strings_buffer=32    ; 16–64
opcache.max_accelerated_files=50000   ; WP+Woo+plugins routinely >20k files
opcache.validate_timestamps=1         ; keep 1 on auto-updating WP sites
opcache.revalidate_freq=60            ; 30–120s; cuts stat() syscalls massively
opcache.save_comments=1               ; REQUIRED: WP/Woo plugins use doc-comment annotations
opcache.jit=off                       ; see below
opcache.jit_buffer_size=0
```

- **memory_consumption**: 256 MB is the sweet spot for 25–40 plugin Woo sites; 512 MB only for massive multi-site/plugin-heavy installs; 128 MB is a floor on small 2–4 GB VPSes ([DCHost OPcache guide](https://www.dchost.com/blog/en/php-opcache-settings-best-configuration-for-wordpress-laravel-and-woocommerce/), [DoHost: beyond 128MB](https://dohost.us/index.php/2026/05/04/beyond-128mb-scaling-opcache-memory-for-massive-wordpress-and-woocommerce-installs/), [Jorijn OPcache for WP](https://jorijn.com/en/knowledge-base/wordpress/performance/wordpress-opcache-configuration/)). Verify with `opcache_get_status()`: target <80% used, ~0 restarts (`oom_restarts`), hit rate >99%.
- **validate_timestamps**: `=0` is the absolute-max-performance choice but is **wrong for typical WordPress** — auto-updates, plugin updates from wp-admin, and WP-CLI edits would serve stale code until manual `opcache_reset()`. For a tooling script targeting client sites: `validate_timestamps=1` + `revalidate_freq=60` is the safe default; only set `0` on deploy-pipeline-managed sites ([Tideways OPcache guide](https://tideways.com/profiler/blog/fine-tune-your-opcache-configuration-to-avoid-caching-suprises), [Boosted Host safe values](https://boostedhost.com/blog/en/opcache-settings-for-wordpress-2025-safe-values-that-actually-speed-things-up/)).
- **JIT: leave off** for WooCommerce. The workload is I/O-bound (DB, object-cache, HTTP); JIT (`tracing`) adds memory overhead with little/no measurable gain, and has had compatibility issues with some extensions. Only enable with profiling data showing CPU-bound PHP ([DCHost](https://www.dchost.com/blog/en/php-opcache-settings-best-configuration-for-wordpress-laravel-and-woocommerce/), [TweaksWP benchmarks](https://tweakswp.com/php-opcache-settings-for-wordpress-configuration-guide-with-benchmarks/)).
- **lsphp-specific opcache caveats** ([LSWS PHP performance docs](https://docs.litespeedtech.com/lsws/extapp/php/performance/)):
  - Opcache is shared only within a process group (Daemon/ProcessGroup modes with suEXEC). Worker mode = one opcache per process = N× the memory and no sharing. A tuning script should ensure ProcessGroup/Daemon mode for WordPress.
  - LiteSpeed's shared-hosting guidance: opcache SHM ≤ ~25% of the per-account memory budget (e.g. 32 MB opcache on a 128 MB account). On a dedicated Woo VPS this constraint doesn't apply — use the 256 MB figure.
  - Put `session.save_path` and any opcache file cache on `/dev/shm` if RAM allows.

### 1.3 Per-vhost php.ini handling on LiteSpeed (what a script must handle)

Mechanisms, in order of precedence/practicality ([per-user php.ini docs](https://docs.litespeedtech.com/lsws/cp/cpanel/php-user-ini/), [LiteSpeed wiki per-user php.ini](https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:php:per-user-php-ini)):

1. **`PHPRC=/path/to/dir` env** on the external app / vhost — *replaces* the default php.ini entirely.
2. **`PHP_INI_SCAN_DIR=:/path/to/dir`** env — loads default php.ini *plus* extra `.ini` files from the dir (leading `:` keeps the compiled-in scan dir). Preferred for additive overrides (RunCloud uses exactly this pattern: [RunCloud custom php.ini on OLS](https://runcloud.io/docs/custom-php-ini-openlitespeed)).
3. **`phpIniOverride { php_admin_value ... }`** block inside the vhost conf (OLS/CyberPanel native way).
4. **`.htaccess`** `php_value`/`php_flag` — LSWS (Enterprise, Apache-config mode) honors these natively; works with cPanel MultiPHP INI Editor out of the box ([cPanel PHP docs](https://docs.litespeedtech.com/lsws/cp/cpanel/php/)).
5. **`.user.ini`** per directory — standard PHP mechanism, works under lsphp ([OLS per-dir docs](https://docs.openlitespeed.org/config/php/file/)).

**Gotcha:** changes only apply after the lsphp process group restarts — `touch /usr/local/lsws/admin/tmp/.lsphp_restart.txt` (or `kill` the lsphp parent / graceful LSWS restart). A tooling script must do this after every ini edit.

---

## 2. Redis object cache for WooCommerce

### 2.1 redis.conf tuning

```conf
# /etc/redis/redis.conf — single-server Woo store
maxmemory 512mb                 # see sizing table §7
maxmemory-policy allkeys-lru
unixsocket /var/run/redis/redis.sock
unixsocketperm 770
port 0                          # disable TCP if everything is local (or keep 6379 bound to 127.0.0.1)
save ""                         # pure cache: disable RDB persistence (but see sessions caveat §2.3)
appendonly no
tcp-backlog 511                 # raise net.core.somaxconn to match (§5)
lazyfree-lazy-eviction yes
io-threads 2                    # only on 4+ core boxes, Redis ≥6
```

- **allkeys-lru vs volatile-lru**: WP object-cache plugins write most keys *without TTLs*, so `volatile-lru` would find nothing evictable and Redis would hit OOM-on-write errors. **`allkeys-lru` is the correct policy for a WP/Woo object cache** ([binadit: Redis for high-traffic Woo](https://dev.to/binadit/how-to-configure-redis-for-a-high-traffic-woocommerce-store-3a51), [Super Speedy Plugins Redis guide](https://www.superspeedyplugins.com/kb/performance-optimization/stack-guides-tips/configuring-redis-for-wordpress/)). `volatile-lru` is only appropriate if Redis *also* stores must-not-evict data (e.g. PHP sessions) in the same instance — better solved by separate instances (§2.3).
- **maxmemory**: 256 MB–1 GB covers most Woo stores; size to working set, verify with `INFO memory` (`used_memory` should plateau below maxmemory; watch `evicted_keys` rate) ([boostedhost Redis config](https://boostedhost.com/blog/en/configure-redis-object-cache-for-wordpress-2025-safe-ttls-and-persistent-cache/)).
- **Unix socket vs TCP**: same-host Redis over a Unix socket is ~25% faster than loopback TCP (eliminates TCP stack overhead) ([wp-bullet Unix socket guide](https://guides.wp-bullet.com/how-to-configure-redis-to-use-unix-socket-speed-boost/), [binadit](https://binadit.com/blog/redis-configuration-high-traffic-woocommerce-cloud-cost-optimization-services)). wp-config:
  ```php
  define('WP_REDIS_SCHEME', 'unix');
  define('WP_REDIS_PATH', '/var/run/redis/redis.sock');
  ```
  The web-server user (e.g. the vhost's suEXEC user) must be in the `redis` group for `unixsocketperm 770`. On suEXEC shared hosting with many users this is the main blocker — fall back to 127.0.0.1 TCP with `requirepass` there.

### 2.2 WordPress-side config

- Plugin: Redis Object Cache (free) or Object Cache Pro / LiteSpeed Cache's own object-cache module (LSCWP has built-in Redis/Memcached object cache settings — one less plugin).
- `define('WP_REDIS_MAXTTL', 86400);` — safety TTL so orphaned keys eventually expire.
- Use `WP_REDIS_PREFIX`/`WP_CACHE_KEY_SALT` per site when sharing one instance; better: one Redis **database number** or instance per site (cPanel multi-tenant case study: isolated per-account Redis instances avoided cross-site eviction storms — [NixTree case study](https://www.nixtree.com/blog/dedicated-redis-instance-for-wordpress/)).

### 2.3 WooCommerce session considerations (important!)

- WooCommerce **does not use PHP sessions**; carts live in `wp_woocommerce_sessions` (DB) *but are also cached through the object cache* (`wc_session_id` group). If Redis evicts under memory pressure, customers can see **carts randomly emptying** ([cr0x: cart empties after refresh](https://cr0x.net/en/woocommerce-cart-empties-refresh-fixes/), [binadit](https://dev.to/binadit/how-to-configure-redis-for-a-high-traffic-woocommerce-store-3a51)).
- Mitigations a script can apply:
  1. Size `maxmemory` so eviction is rare (`evicted_keys` ≈ 0 in steady state).
  2. Keep `allkeys-lru` but give sessions DB authority — they are persisted in MariaDB anyway; an evicted cache entry is re-read from DB (slow path, not data loss). The genuine data-loss case is plugins that make sessions Redis-only.
  3. For serious stores: **separate Redis instances** (or at least DB indexes with conservative settings) for object cache vs anything persistent/queue-like ([DCHost sessions vs cache](https://www.dchost.com/blog/en/choosing-php-session-and-cache-storage-files-vs-redis-vs-memcached-for-wordpress-and-laravel/)).
  4. If PHP `session.save_handler=redis` is also configured (some stacks do for non-Woo plugins), that instance must NOT use `allkeys-lru` — use `volatile-lru`/`noeviction` + persistence (`save` directives kept) ([Hypernode Redis+Woo docs](https://docs.hypernode.com/ecommerce-applications/woocommerce/how-to-use-redis-with-woocommerce-and-wordpress-on-hypernode.html)).
- Measured impact: Redis object cache on OLS + Woo typically halves uncached TTFB (e.g. 400–800 ms → <200 ms) and cuts DB CPU 60–80% ([riz.codes OLS+Redis TTFB](https://riz.codes/redis-object-cache-openlitespeed-woocommerce-ttfb/), [WP Pro Host benchmarks](https://wp-pro-host.com/resources/performance/litespeed-vs-nginx-wordpress/)).

---

## 3. MySQL / MariaDB tuning for WooCommerce

### 3.1 Core settings

```ini
# /etc/mysql/mariadb.conf.d/99-woocommerce.cnf
[mysqld]
innodb_buffer_pool_size = 1536M      # see formula below
innodb_log_file_size    = 256M       # ~25% of buffer pool, 128–512M typical
innodb_flush_method     = O_DIRECT
innodb_flush_log_at_trx_commit = 1   # keep 1 for orders (ACID); 2 only on non-critical sites
tmp_table_size          = 64M
max_heap_table_size     = 64M
table_open_cache        = 4000
max_connections         = 100–151    # lsphp children bound this; don't blindly raise
slow_query_log          = 1
long_query_time         = 0.5
performance_schema      = OFF        # saves ~400MB on small VPSes (MariaDB default is mostly off)
```

- **innodb_buffer_pool_size formula**:
  - Dedicated DB server: 70–80% of RAM ([MariaDB memory allocation docs](https://mariadb.com/docs/server/ha-and-performance/mariadb-memory-allocation), [Eklipse MySQL for Woo](https://eklipsecreative.com/blog/mysql-tuning-for-woocommerce-databases/)).
  - **Shared web+DB box (the LiteSpeed-typical case): 25–40% of total RAM**, and at minimum ≥ the hot dataset (rule of thumb: ≥ 50% of total DB size; ideally buffer pool ≥ full DB size for Woo DBs under ~2 GB) ([wp-hosting.co.nz MariaDB guide](https://wp-hosting.co.nz/mariadb-tuning-for-wordpress-a-complete-performance-guide/), [Pieter Bakker MariaDB for WP](https://pieterbakker.com/optimizing-mariadb-performance-for-wordpress-2/)).
  - Verify: `SHOW ENGINE INNODB STATUS` buffer-pool hit rate should be >99%; `Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests < 0.01`.
- **Slow query log methodology**: `long_query_time=0.5`, run 24–48 h of real traffic, then `pt-query-digest` / `mariadb-dumpslow` — this reliably surfaces the Woo offenders below ([wp-maintenance.pro Woo DB optimisation](https://wp-maintenance.pro/wordpress-database-optimisation/)).

### 3.2 wp_options autoload bloat

- All rows with `autoload='yes'` (or `'on'` in WP 6.6+) load on **every request**. Target: **total autoloaded < 1 MB**; real-world horror cases of 8 MB+ autoload caused 6 s pages ([DCHost wp_options guide](https://www.dchost.com/blog/en/wordpress-database-optimization-guide-wp_options-autoload-and-table-bloat/)).
- Audit query:
  ```sql
  SELECT 'total' AS name, ROUND(SUM(LENGTH(option_value))/1024/1024,2) AS MB
  FROM wp_options WHERE autoload IN ('yes','on')
  UNION ALL
  SELECT option_name, ROUND(LENGTH(option_value)/1024/1024,2)
  FROM wp_options WHERE autoload IN ('yes','on')
  ORDER BY MB DESC LIMIT 21;
  ```
- Fix: `UPDATE wp_options SET autoload='no' WHERE option_name='...'` for >100 KB options not needed on every load (typically abandoned plugin caches, `_transient_` leftovers, page-builder CSS blobs). WP-CLI: `wp option list --autoload=on --fields=option_name,size_bytes`.

### 3.3 WooCommerce-specific tables and slow queries

- **Lookup tables**: `wp_wc_product_meta_lookup` (price/stock queries) and `wp_wc_product_attributes_lookup` (attribute filtering, WC 6.3+). If missing/stale, Woo falls back to huge `wp_postmeta` JOINs. Regenerate synchronously: `wp wc palt regenerate` (WC 9.1+ also raised the regen batch from 10→100 products) ([Woo dev blog: PALT optimization](https://developer.woocommerce.com/2024/06/20/an-optimization-for-the-product-attributes-lookup-table-is-coming/), [WC 3.6 perf improvements](https://developer.woocommerce.com/2019/04/01/performance-improvements-in-3-6/)). Tools page: WooCommerce → Status → Tools → "Regenerate product lookup tables".
- **HPOS** (§4.1) removes the classic `wp_posts`/`wp_postmeta` order-query bottleneck.
- **wp_woocommerce_sessions cleanup**: expired sessions should be purged by Woo's cleanup cron, but it falls behind; table grows to hundreds of MB. Safe manual purge ([MainWP sessions guide](https://mainwp.com/how-to-clean-and-optimize-the-woocommerce-sessions-table/)):
  ```sql
  DELETE FROM wp_woocommerce_sessions WHERE session_expiry < UNIX_TIMESTAMP();
  OPTIMIZE TABLE wp_woocommerce_sessions;
  ```
  Or WooCommerce → Status → Tools → "Clear customer sessions" (logs out carts — off-peak only).

---

## 4. WooCommerce application-level

### 4.1 HPOS (High-Performance Order Storage)

- Dedicated order tables (`wp_wc_orders`, `wp_wc_order_addresses`, `wp_wc_order_operational_data`, `wp_wc_orders_meta`) replacing posts/postmeta storage — default on new stores since WC 8.2; existing stores must migrate ([HPOS docs](https://woocommerce.com/document/high-performance-order-storage/), [developer docs](https://developer.woocommerce.com/docs/features/high-performance-order-storage/)).
- Script-friendly enablement flow ([enable-HPOS guide](https://developer.woocommerce.com/docs/features/high-performance-order-storage/enable-hpos/), [HPOS CLI tools](https://developer.woocommerce.com/docs/features/high-performance-order-storage/cli-tools/), [large-store guide](https://developer.woocommerce.com/docs/features/high-performance-order-storage/guide-large-store/)):
  ```bash
  wp wc hpos status                       # check counts + current authority
  wp wc hpos sync                         # synchronous backfill (much faster than Action Scheduler batches)
  wp wc hpos enable                       # flip authoritative storage to HPOS
  wp wc hpos cleanup all                  # later: purge redundant order meta from wp_postmeta (compat mode off)
  ```
  Keep compatibility mode (sync to posts) ON initially; disable + `cleanup all` after verifying plugins are HPOS-compatible — cleanup can shrink DBs by **gigabytes** ([CLI tools doc](https://developer.woocommerce.com/docs/features/high-performance-order-storage/cli-tools/)).
- Gate: check plugin compatibility first (`WooCommerce → Settings → Advanced → Features` shows incompatible plugins).

### 4.2 Action Scheduler cleanup

- `wp_actionscheduler_actions` + `_logs` grow continuously; 200k–500k rows on an 18-month store is common, and claiming queries slow down the whole store. Default retention for completed actions is 30 days but cleanup (batch of 20) falls behind on busy stores ([TurboPress AS bloat](https://www.turbopress.pro/blog/action-scheduler-bloat), [MainWP AS tips](https://mainwp.com/action-scheduler-tables-tips-for-a-leaner-faster-wordpress/)).
- Fixes:
  ```php
  add_filter('action_scheduler_retention_period', fn() => WEEK_IN_SECONDS);   // 30d → 7d
  add_filter('action_scheduler_cleanup_batch_size', fn() => 200);             // 20 → 200
  ```
  One-shot SQL purge (safe statuses only):
  ```sql
  DELETE FROM wp_actionscheduler_actions WHERE status IN ('complete','failed','canceled')
    AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 7 DAY);
  DELETE l FROM wp_actionscheduler_logs l
    LEFT JOIN wp_actionscheduler_actions a ON a.action_id=l.action_id WHERE a.action_id IS NULL;
  OPTIMIZE TABLE wp_actionscheduler_actions, wp_actionscheduler_logs;
  ```
  Real-world result: 370 MB → 11 MB and visibly faster background processing ([WP Beaches](https://wpbeaches.com/removing-scheduled-actions-woocommerce-action-scheduler/), [Black Hills Web Works auto-clean](https://blackhillswebworks.com/2024/08/29/automatically-clean-action-scheduler-database-tables/)).

### 4.3 Transient cleanup

- Expired transients linger in `wp_options` (many never get GC'd) ([webdevsupply Woo DB cleanup](https://webdevsupply.com/how-to-clean-up-woocommerce-database-slowdowns-by-optimizing-orders-transients-and-lookup-tables/)).
  ```bash
  wp transient delete --expired
  wp transient delete --all          # aggressive; transients regenerate
  ```
  Note: Woo's "Clear transients" tool misses many `_transient_wc_*` rows ([woocommerce#31852](https://github.com/woocommerce/woocommerce/issues/31852)). With a Redis object cache active, transients live in Redis instead of wp_options — another reason to install it.

### 4.4 Cart fragments (`?wc-ajax=get_refreshed_fragments`)

- Every page load fires an **uncacheable admin-ajax-style POST** that boots full WordPress to refresh the mini-cart — historically the #1 Woo frontend perf complaint, up to multi-second delays on heavy sites ([woocommerce#31981](https://github.com/woocommerce/woocommerce/issues/31981), [WebNots fix guide](https://www.webnots.com/fix-slow-page-loading-with-woocommerce-wc-ajaxget_refreshed_fragments/)).
- **WC ≥ 7.8: fragments are disabled by default** unless a Cart Widget block renders — first check whether `cart-fragments.js` even loads before "fixing" ([Woo dev blog: cart fragments best practices](https://developer.woocommerce.com/2023/06/16/best-practices-for-the-use-of-the-cart-fragments-api/)).
- Mitigation ladder for a tooling script:
  1. Detect script handle `wc-cart-fragments`; if absent → nothing to do.
  2. Conditional disable (Perfmatters approach): dequeue unless `woocommerce_cart_hash` cookie exists ([Perfmatters doc](https://perfmatters.io/docs/disable-woocommerce-cart-fragments-ajax/)).
  3. Settings tweak: disable "AJAX add to cart" + enable "redirect to cart" (saves one AJAX call) ([Business Bloomer](https://www.businessbloomer.com/woocommerce-why-how-to-disable-ajax-cart-fragments/)).
  4. **LiteSpeed-native answer: ESI.** LSCWP "ESI" mini-cart block = page stays in public cache, cart count served as a private-cache ESI sub-request — eliminates the fragments AJAX entirely. **Enterprise LSWS / QUIC.cloud only; OpenLiteSpeed has no ESI** ([LSCWP FAQ](https://docs.litespeedtech.com/lscache/lscwp/faq/), [LiteSpeed blog: ESI](https://blog.litespeedtech.com/2017/09/06/wpw-esi-and-litespeed-cache/), [LSCache+Woo conflicts](https://blog.litespeedtech.com/2017/05/31/wpw-fixing-lscachewoocommerce-conflicts/)). On OLS, use option 2 instead.

---

## 5. OS-level tuning

### 5.1 File descriptors

LiteSpeed is event-driven with few processes; each request can need **up to 4 FDs**, so the *per-process* limit caps concurrency ([LiteSpeed FD wiki](https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:config:increasing-os-file-descriptor-limit)).

```bash
# /etc/security/limits.d/99-lsws.conf
*    soft nofile 65535
*    hard nofile 65535

# systemd unit override (this is what actually matters for lsws/lshttpd):
# /etc/systemd/system/lsws.service.d/override.conf  (or lshttpd.service.d)
[Service]
LimitNOFILE=65535          # LiteSpeed docs show up to 5000000 for extreme cases
# then: systemctl daemon-reload && systemctl restart lsws
```
LSWS started as root auto-raises soft limits per its config, but the systemd cap still binds — set the override ([BaseZap too-many-open-files fix](https://www.basezap.com/fixed-too-many-open-files-error-on-litespeed-web-server/), [LSWS troubleshooting](https://docs.litespeedtech.com/lsws/troubleshooting/)).

### 5.2 sysctl

```bash
# /etc/sysctl.d/99-litespeed.conf — sane high-traffic Woo values (not the extreme 655350 wiki numbers)
fs.file-max = 500000
net.core.somaxconn = 4096              # default 128/4096; must exceed listener backlogs (incl. redis tcp-backlog)
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_slow_start_after_idle = 0
net.core.default_qdisc = fq            # pair for BBR
net.ipv4.tcp_congestion_control = bbr
vm.swappiness = 10                     # 1–10 on combined web+DB box
vm.vfs_cache_pressure = 50
```
Sources: [Raju Ginni sysctl tweaks](https://raazkumar.com/tutorials/linux/linux-sysctl-conf-performance-tweaks/), [TechNops kernel tuning](https://technops.com/linux-kernel-tuning-sysctl-ulimit/), [LSWS tuning docs](https://www.litespeedtech.com/docs/webserver/config/tuning). `somaxconn` too low silently drops connections under burst load before LSWS ever sees them.

### 5.3 Swap

- Have swap as a **safety net, never a performance feature**: 2–4 GB swap on a 2–8 GB VPS (≈ RAM-sized at 2–4 GB, min 2 GB on ≤4 GB boxes) ([RHEL guidance](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/storage_administration_guide/ch-swapspace), [It's FOSS swap sizing](https://itsfoss.com/swap-size/)).
- `vm.swappiness=10` (or 1) on boxes running MariaDB — DB pages getting swapped is catastrophic for query latency ([MariaDB swappiness docs](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/configuring-mariadb/mariadb-performance-advanced-configurations/configuring-swappiness)). Sustained swap *usage* = undersized RAM, alert rather than tune ([Perlod swap guide](https://perlod.com/tutorials/swap-usage-on-linux-servers/)).

---

## 6. Control-panel path matrix (what a tooling script must handle)

| Environment | Web server | Main server conf | Vhost conf | php.ini (per version) | Per-site PHP override | PHP restart trigger |
|---|---|---|---|---|---|---|
| **CyberPanel** | OLS (or Ent) | `/usr/local/lsws/conf/httpd_config.conf` | `/usr/local/lsws/conf/vhosts/<domain>/vhost.conf` | `/usr/local/lsws/lsphpXX/etc/php/X.X/litespeed/php.ini` | `phpIniOverride { }` block via "vHost Conf" in panel | `touch /usr/local/lsws/admin/tmp/.lsphp_restart.txt` or `systemctl restart lsws` |
| **cPanel + LSWS Ent** | LSWS reads Apache config | `/usr/local/lsws/conf/httpd_config.xml` + Apache `/etc/apache2/conf/httpd.conf` (EA4) | Apache vhost includes (`/etc/apache2/conf.d/userdata/...`) | `/opt/cpanel/ea-phpXX/root/etc/php.ini` (ea-php) | MultiPHP INI Editor, `.htaccess` php_value (works natively), `PHPRC`/`PHP_INI_SCAN_DIR` env | `/scripts/restartsrv_lsws`; lsphp restart marker also works |
| **DirectAdmin + LSWS/OLS** | CustomBuild-built lsphp | `/usr/local/lsws/conf/` + DA templates | DA-generated includes | `/usr/local/phpXX/lib/php.ini` (+ `/usr/local/phpXX/lib/php.conf.d/*.ini`) | per-user ini via CustomBuild / `.user.ini` | `systemctl restart lsws` after `da build php` |
| **RunCloud (OLS stack)** | OLS | `/usr/local/lsws/conf/httpd_config.conf` (managed — edits via panel survive) | per-app conf via panel "OpenLiteSpeed config" | `/usr/local/lsws/lsphpXX/etc/php/X.X/...`; mods at `/usr/local/lsws/lsphpXX/etc/php/X.X/mods-available/` | add `PHP_INI_SCAN_DIR` env in app's extprocessor block | panel restart / `systemctl restart lsws` |
| **Plain OLS (Ploi & manual installs)** | OLS | `/usr/local/lsws/conf/httpd_config.conf` | `/usr/local/lsws/conf/vhosts/...` | `/usr/local/lsws/lsphpXX/etc/php/X.X/litespeed/php.ini` | `PHPRC` / `PHP_INI_SCAN_DIR` env on extApp, or `phpIniOverride` | `.lsphp_restart.txt` touch / `lswsctrl restart` |

Notes for a script:
- **Universal detection**: `readlink -f $(which lsphp 2>/dev/null)`; better: `/usr/local/lsws/lsphp*/bin/php -i | grep 'Loaded Configuration File'` — never hardcode, since DA uses `/usr/local/phpXX` while CyberPanel/RunCloud use `/usr/local/lsws/lsphpXX` ([DA php options docs](https://docs.directadmin.com/webservices/php/php-options.html), [CyberPanel config locations](https://community.cyberpanel.net/t/location-of-configuration-files/139), [RunCloud OLS config docs](https://runcloud.io/docs/openlitespeed-configuration)).
- On **cPanel/Plesk/DA with Enterprise LSWS**, tune via Apache-style directives and panel mechanisms — LSWS rereads Apache config; direct XML edits get clobbered. On **CyberPanel/RunCloud OLS**, the native conf files are authoritative but panel regeneration can overwrite them — use the panel's include/override hooks.
- Ploi's OLS support is thin/absent (Ploi is primarily nginx); treat Ploi boxes as "plain OLS if present, else not a LiteSpeed target".

---

## 7. RAM-aware sizing formulas (whole stack on one box)

General rule: **OS + LSWS reserve first, MariaDB buffer pool second, lsphp pool third, Redis + opcache from the remainder.** LSWS itself is tiny (event-driven, ~tens of MB) — unlike Apache, almost all "web" RAM goes to lsphp children.

**Formulas:**
```
reserve_os        = max(512MB, 12% of RAM)
lsphp_children    = clamp( cores * 2, 10, RAM_for_php / avg_proc_size )   # avg Woo lsphp proc ≈ 50–80 MB RSS
RAM_for_php       = lsphp_children * 80MB (Woo worst case)
innodb_buffer_pool= 25–40% of RAM (same-box), but ≥ min(DB_size, 40% RAM)
redis_maxmemory   = 64MB–1GB sized to working set (start 12% of RAM, cap 1GB)
opcache           = 192–256MB (one SHM per process group, not per child)
sanity check      : reserve + buffer_pool + redis + opcache + children*80MB ≤ 0.9 * RAM
```

**Concrete splits** (combined LSWS+lsphp+MariaDB+Redis, WooCommerce):

| RAM | OS+LSWS | innodb_buffer_pool | lsphp children × ~70MB | Redis maxmemory | opcache | headroom |
|---|---|---|---|---|---|---|
| **2 GB** | 384 MB | 512 MB | 8 × 70 = 560 MB | 128 MB | 128 MB | ~290 MB |
| **4 GB** | 512 MB | 1024–1536 MB | 15 × 70 ≈ 1050 MB | 256–512 MB | 256 MB | ~400 MB |
| **8 GB** | 768 MB | 2.5–3 GB | 25 × 80 = 2 GB | 512 MB–1 GB | 256 MB | ~1 GB |
| **16 GB** | 1 GB | 6 GB | 40 × 80 = 3.2 GB | 1–2 GB | 384 MB | ~3 GB |

Sources for the component formulas: [MariaDB memory allocation](https://mariadb.com/docs/server/ha-and-performance/mariadb-memory-allocation) (25–40% same-box), [Kevin Dees PHP scaling](https://kevdees.com/how-to-configure-php-memory-and-php-fpm-for-scalable-performance-on-8-16-and-32-gb-servers) (children = free_php_ram / per-worker RSS; ~50 MB/worker for plain WP, use 70–80 MB for Woo), [Super Speedy Plugins](https://www.superspeedyplugins.com/kb/performance-optimization/stack-guides-tips/configuring-redis-for-wordpress/) and [boostedhost](https://boostedhost.com/blog/en/configure-redis-object-cache-for-wordpress-2025-safe-ttls-and-persistent-cache/) (Redis 256 MB–1 GB), [HostAccent VPS sizing](https://www.hostaccent.com/blog/wordpress-vps-requirements-ram-cpu-storage-guide) (4 GB minimum sensible tier for WooCommerce).

Measurement-driven correction loop for a script:
```bash
# real lsphp per-proc RSS:
ps -ylC lsphp --sort:rss | awk '{s+=$8; n++} END {print s/n/1024 " MB avg"}'
# mysql actual usage vs config: mysqltuner or
# redis: redis-cli INFO memory | grep used_memory_human
```
The key LiteSpeed difference vs nginx/php-fpm sizing: because lsphp is **on-demand**, idle sites release PHP RAM — you can size children for peak knowing steady-state usage is lower; but you must also keep `LSAPI_PGRP_MAX_IDLE` high enough to preserve opcache (§1.1) — i.e. the *parent* stays, children come and go.

---

## 8. Benchmarking methodology

### 8.1 What to measure, in what state

Always benchmark **three states** and record them separately:
1. **Cached (LSCache HIT)** — verifies page-cache config: header `x-litespeed-cache: hit`.
2. **Uncached / cache MISS** — the PHP+DB+Redis path; what logged-in users, carts, checkout and cache-cold pages experience. Force with `curl -H "Cache-Control: no-cache"` won't bypass LSCache — instead hit a URL with a cache-busting query string the plugin doesn't ignore, or test logged-in/with a Woo session cookie, or purge then hit once.
3. **Cart/checkout flow** — add-to-cart POST, `/checkout/` GET with session cookie. These are *never* page-cached and dominate revenue UX.

### 8.2 Tools

**curl timing (single-shot TTFB, the foundation):**
```bash
curl -o /dev/null -s -w 'dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' https://store.example/
# run 10x, take median; time_starttransfer = TTFB (connection setup + server processing)
```
([Speed Test Demon curl metrics cheat sheet](https://speedtestdemon.com/a-guide-to-curls-performance-metrics-how-to-analyze-a-speed-test-result/), [NOC.org curl perf](https://noc.org/learn/curl-website-performance))

**wrk (raw throughput, cached pages):** good for "how many req/s can LSCache serve", HTTP/1.1 only, no scripting of flows ([wrk](https://github.com/wg/wrk)):
```bash
wrk -t4 -c100 -d60s --latency https://store.example/
```

**k6 (realistic flows, the recommended tool):** HTTP/1.1+2, scriptable cart flows, thresholds, and `http_req_waiting` = TTFB ([k6 TTFB metric](https://github.com/grafana/k6/issues/4074), [k6 vs wrk](https://stackshare.io/stackups/k6-vs-wrk), [wrk→k6 methodology](https://community.grafana.com/t/from-wrk-to-k6-equivalent-parameters-and-testing-methodology/111033)):
```js
import http from 'k6/http';
export const options = { stages: [
  { duration: '1m', target: 20 }, { duration: '3m', target: 20 }, { duration: '1m', target: 0 }],
  thresholds: { 'http_req_waiting{page:product}': ['p(95)<600'],
                'http_req_waiting{page:cached}':  ['p(95)<150'] } };
export default function () {
  http.get('https://store.example/', { tags: { page: 'cached' } });
  http.get('https://store.example/product/sample/?nocache=' + Math.random(), { tags: { page: 'product' } });
}
```

Methodology rules: run the load generator from a *separate* machine in the same region; warm caches first; fixed durations ≥60 s; report p50/p95/p99 not averages; one variable change per run; watch server-side (`top`, WaitQ in LSWS console, `SHOW PROCESSLIST`, `redis-cli INFO stats`) during the run.

### 8.3 Realistic targets for WooCommerce on LiteSpeed

| Scenario | Target TTFB (p95, server-local/near) | Notes |
|---|---|---|
| LSCache HIT (Enterprise/OLS) | **30–150 ms** | never enters PHP; 50–150 ms typical incl. TLS ([WP Pro Host benchmarks](https://wp-pro-host.com/resources/performance/litespeed-vs-nginx-wordpress/), [FatLab TTFB](https://fatlabwebsupport.com/blog/website-optimization/wordpress-ttfb/)) |
| Uncached page, tuned stack (opcache+Redis+buffer pool) | **<200–600 ms** | Redis object cache typically drops 400–800 ms → <200 ms ([riz.codes](https://riz.codes/redis-object-cache-openlitespeed-woocommerce-ttfb/), [CommerceGurus TTFB guide](https://www.commercegurus.com/reduce-ttfb-woocommerce/)) |
| Cart/checkout pages | **<800 ms** | uncacheable; dominated by PHP+DB; >2 s = something's wrong |
| Untuned baseline for reference | 600 ms–2 s shared, 200–600 ms managed | ([WPBundle Woo PageSpeed](https://www.wpbundle.com/guides/woocommerce-pagespeed-score)) |
| Throughput, cached homepage (4 GB VPS) | thousands req/s | LSCache serves from static-like cache; CPU-bound on TLS |
| Throughput, uncached product page (4 GB/2 cores) | ~10–40 req/s | bound by lsphp children × per-request time |

Red flags during benchmark: TTFB cached >300 ms (cache not actually hitting — check `x-litespeed-cache` header), uncached >2 s (check slow query log + autoload + Action Scheduler), p99 ≫ p95 (WaitQ saturation → raise LSAPI_CHILDREN or add RAM), cart-empty reports under load (Redis eviction, §2.3).

---

## Appendix: one-screen checklist for a tuning script

```text
[ ] Detect environment (cPanel/CyberPanel/DA/RunCloud/plain) → resolve php.ini & vhost paths (§6)
[ ] lsphp: ProcessGroup/Daemon mode, LSAPI_CHILDREN per formula §7, LSAPI_MAX_REQS=1000,
    LSAPI_PGRP_MAX_IDLE=3600, PHP suEXEC Max Conn 10→15-20 if RAM allows
[ ] opcache: 256M / 50000 files / validate=1 revalidate=60 / save_comments=1 / JIT off → touch .lsphp_restart.txt
[ ] Redis: unix socket, maxmemory per table §7, allkeys-lru, monitor evicted_keys
[ ] MariaDB: buffer pool 25-40% RAM, slow log 0.5s, O_DIRECT
[ ] DB hygiene: autoload <1MB, sessions purge, transients purge, AS retention 7d + purge,
    lookup tables regenerated (wp wc palt regenerate)
[ ] Woo: HPOS status → sync → enable → (later) cleanup all; cart-fragments detection;
    ESI mini-cart if Enterprise, conditional dequeue if OLS
[ ] OS: LimitNOFILE=65535 (systemd override), somaxconn=4096, swappiness=10, 2-4GB swap
[ ] Benchmark before/after: curl median TTFB ×10 (cached/uncached/cart), k6 staged load with
    http_req_waiting thresholds (cached p95<150ms, uncached p95<600ms)
```
