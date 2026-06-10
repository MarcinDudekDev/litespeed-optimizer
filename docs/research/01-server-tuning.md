# LiteSpeed Server-Level Optimization for WordPress/WooCommerce Hosting

Research report — server-level tuning of LiteSpeed Enterprise (LSWS) and OpenLiteSpeed (OLS).
Compiled 2026-06-10 from official LiteSpeed/OpenLiteSpeed docs, GitHub source defaults, and hosting-community guides. All parameter names verified against the shipped default config (`httpd_config.conf.in`) where possible.

---

## 1. LiteSpeed Enterprise vs OpenLiteSpeed — what matters for optimization tooling

| Aspect | OpenLiteSpeed (OLS) | LiteSpeed Enterprise (LSWS) |
|---|---|---|
| License | Free, open source (GPL) | Commercial; Free Starter / Site Owner / Web Host tiers. Legacy VPS license capped at 500 concurrent connections, Ultra-VPS at 800; **current licenses (Free Starter, Site Owner, Web Host) have no connection cap** — they're priced by worker processes/domains ([licenses doc](https://docs.litespeedtech.com/licenses/products/lsws/), [KB](https://store.litespeedtech.com/store/index.php?rp=/knowledgebase/188/)) |
| Main config | **Plain-text** `/usr/local/lsws/conf/httpd_config.conf` (hierarchical `block { key value }` format) | **XML** `/usr/local/lsws/conf/httpd_config.xml` (root tag `<httpServerConfig>`) **plus** the ability to read native Apache `httpd.conf` includes directly ([forum](https://www.litespeedtech.com/support/forum/threads/resolved-scripting-httpd_config-xml.906/), [CyberPanel thread](https://community.cyberpanel.net/t/i-need-httpd-conf-file-for-litespeed-enterprise/32438)) |
| .htaccess | Rewrite rules only; **other Apache directives ignored**; historically needed a restart to pick up new .htaccess (no .htaccess caching) | Full Apache directive compatibility incl. mod_rewrite; **auto-detects .htaccess changes without restart**; .htaccess result caching ([editions comparison](https://www.litespeedtech.com/products/litespeed-web-server/editions)) |
| Apache drop-in | No — own config format | Yes — reads cPanel/Plesk/DirectAdmin Apache configs, drop-in replacement |
| ModSecurity | ModSecurity **3.x** engine via `module mod_security` (rules in native config) | Proprietary high-performance async ModSecurity engine, **2.9-syntax compatible**, works with OWASP CRS, Comodo, Atomicorp, Imunify360 rule sets ([editions](https://www.litespeedtech.com/products/litespeed-web-server/editions), [perf blog](https://blog.litespeedtech.com/2019/12/02/modsecurity-performance-apache-nginx-litespeed/)) |
| LSCache control | Native config blocks + rewrite rules (`[E=cache-control:...]`) | Apache-style directives in server config and **.htaccess** (`CacheRoot`, `CacheEngine`, `CacheLookup`, `CacheEnable`, ESI, crawler) |
| WordPress brute-force protection (`WordPressProtect`) | **Not available** | Yes (server / vhost / .htaccess level) ([wp-protect doc](https://docs.litespeedtech.com/lsws/cp/cpanel/wp-protect/)) |
| Typical use | Single-tenant VPS, fixed sites (CyberPanel, RunCloud, plain installs) | Shared hosting / cPanel, frequently-changing .htaccess |

**Verification of the prompt's premise:** correct. OLS = plain-text `httpd_config.conf`; LSWS Enterprise = `httpd_config.xml` + Apache-compatible configuration layer + full `.htaccess`. Both keep everything under `/usr/local/lsws/conf/`. Sources: [litespeedtech.com editions](https://www.litespeedtech.com/products/litespeed-web-server/editions), [OLS forum comparison](https://forum.openlitespeed.org/threads/what-is-the-complete-difference-beetwen-openlitespeed-litespeed-enterprise.795/), [LSWS configuration docs](https://docs.litespeedtech.com/lsws/configuration/).

**Why this matters for tooling:** OLS's plain-text hierarchical format is trivially scriptable (sed/awk/python line edits, stable `block { key value }` grammar, supports `include` files — [includes doc](https://docs.openlitespeed.org/config/advanced/includes/)). LSWS Enterprise is best automated *through Apache-style include files* (e.g. cPanel: `/etc/apache2/conf.d/includes/pre_main_global.conf`) rather than touching the XML; the XML is normally managed by the WebAdmin GUI.

---

## 2. Core tuning parameters (the `tuning { }` block)

Shipped OLS defaults, verbatim from [`dist/conf/httpd_config.conf.in`](https://github.com/litespeedtech/openlitespeed/blob/master/dist/conf/httpd_config.conf.in):

```
tuning {
  maxConnections          10000
  maxSSLConnections       10000
  connTimeout             300
  maxKeepAliveReq         10000
  smartKeepAlive          0
  keepAliveTimeout        5
  sndBufSize              0
  rcvBufSize              0
  gzipStaticCompressLevel 6
  gzipMaxFileSize         10M
  eventDispatcher         best
  maxCachedFileSize       4096
  totalInMemCacheSize     20M
  maxMMapFileSize         256K
  totalMMapCacheSize      40M
  useSendfile             1
  fileETag                28
  enableGzipCompress      1
  enableBrCompress        4
  gzipCompressLevel       6
}
```

Parameter-by-parameter (from [LSWS tuning docs](https://www.litespeedtech.com/docs/webserver/config/tuning) and [OLS ServTuning help](https://fossies.org/linux/openlitespeed/dist/docs/ServTuning_Help.html)):

### Connections
- **`maxConnections`** — max concurrent connections (TCP + SSL combined). When hit, the server closes keep-alive connections as they finish active requests. OLS default 10000 is fine; on Enterprise legacy licenses it's capped by license (VPS=500, Ultra=800). Don't confuse connection capacity with PHP capacity — the real bottleneck is almost always lsphp workers, not this number.
- **`maxSSLConnections`** — concurrent SSL connections; counted inside `maxConnections`. Set ≤ `maxConnections`. Today nearly all traffic is SSL, so keep them equal.
- **`connTimeout`** (default 300 s) — max idle time *during processing of one request*. Recommendation: set as low as practical (e.g. **30–60 s**) to recover dead connections quickly and resist slowloris-style attacks.
- **`keepAliveTimeout`** (default 5 s) — idle time between requests on a keep-alive connection. **2–5 s is the reasonable range**; applies to HTTP/1.1 only (HTTP/2 and HTTP/3 manage their own long-lived connections). High-traffic servers go lower (2–3 s) to free slots faster.
- **`maxKeepAliveReq`** (default 10000) — requests served per keep-alive connection. Keep "reasonably high" (1000–10000); 0 or 1 effectively disables keep-alive — never do that. For WordPress pages with dozens of assets, ≥1000.
- **`smartKeepAlive`** (default 0=off) — when on, keep-alive is only granted to requests for JS/CSS/images; HTML page requests are closed after response. Designed for **very busy** servers (thousands of concurrent clients) to maximize slot reuse. Leave **off** on a typical VPS; enable on busy shared servers near `maxConnections`. ([keep-alive wiki](https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:config:keep_alive))

### I/O buffers
- **`sndBufSize` / `rcvBufSize`** ("ioBufferSize") — per-socket TCP buffers, max 512K. **Recommended: 0 / Not Set (use OS default)**. Increase send buffer only if serving many large static files; *decrease* to squeeze more concurrent sockets out of low-RAM boxes.
- **`useSendfile`** (default 1) — zero-copy static file serving; keep on. Consider **AIO** (`useAIO`, `aioBlockSize` default 1M) if `iowait` is high.

### Static file in-memory cache
- **`maxCachedFileSize`** (default 4096) — largest static file cached in pre-allocated memory buffers. Optimal ≤4K; raise to 16K–64K on RAM-rich servers serving many small assets.
- **`totalInMemCacheSize`** (default 20M) — total RAM for the small-file cache. 20M is fine for 1–2 GB; raise to 64M–256M on 8 GB+ static-heavy servers.
- **`maxMMapFileSize`** (default 256K) / **`totalMMapCacheSize`** (default 40M) — mid-size files served via mmap. Similar scaling logic.
- **`fileETag`** (default 28 = inode+mtime+size) — drop the inode bit on mirrored/multi-server setups so ETags match across nodes.

### Compression (gzip + brotli)
- **`enableGzipCompress`** = 1 — master switch for GZIP/Brotli on static **and** dynamic responses. Keep on.
- **`enableBrCompress`** = level (OLS ships `4`; LSWS dynamic brotli default 2, range 0–6) — Brotli for dynamic responses. 2–4 is the sweet spot; higher burns CPU for marginal gain.
- **`gzipCompressLevel`** (dynamic) default 6, range 1–9 — gains above 6 are minimal; keep 6.
- **`gzipAutoUpdateStatic`** = 1 — server automatically creates/updates `.gz`/`.br` versions of compressible static files in the static cache directory (precompression — compress once, serve many). Keep on.
- **`gzipStaticCompressLevel`** default 6 (1–9); **`brStaticCompressLevel`** default 5 (1–11) — static files are compressed once, so you can afford higher levels (gzip 6–9, brotli 5–8).
- **`gzipCacheDir`** — where compressed copies are stored; defaults to the server swap directory. Point at fast disk; `/dev/shm` works if files are small.
- **`gzipMaxFileSize`** default 10M (don't precompress huge files), **`gzipMinFileSize`** default 200 bytes (don't compress tiny files).
- **`compressibleTypes`** — default list already includes `text/*`, JS, JSON, SVG, fonts. Never add jpeg/png/woff2 (already compressed).

Source: [LSWS tuning docs](https://www.litespeedtech.com/docs/webserver/config/tuning), [OLS ServTuning_Help](https://github.com/litespeedtech/openlitespeed/blob/master/dist/docs/ServTuning_Help.html).

### Request limits (DoS hygiene)
- `maxReqURLLen` 8192 (2–3K is enough for most sites), `maxReqHeaderSize` 32768 (4–8K enough), `maxReqBodySize` (constrain to what uploads actually need, e.g. 100M for WP media), `maxDynRespHeaderSize` 32K, `maxDynRespSize` reasonably low to catch runaway responses.

---

## 3. LSAPI / lsphp tuning (the real WordPress bottleneck)

PHP runs via **LSAPI** — LiteSpeed's own SAPI, faster than PHP-FPM/FastCGI. Configured as an `extprocessor` (OLS) / External App (LSWS), tuned through **environment variables**.

Shipped OLS default ([httpd_config.conf.in](https://github.com/litespeedtech/openlitespeed/blob/master/dist/conf/httpd_config.conf.in)):

```
extprocessor lsphp {
  type                lsapi
  address             uds://tmp/lshttpd/lsphp.sock
  maxConns            10
  env                 PHP_LSAPI_CHILDREN=10
  env                 LSAPI_AVOID_FORK=200M
  initTimeout         60
  retryTimeout        0
  persistConn         1
  respBuffer          0
  autoStart           1
  path                lsphp83/bin/lsphp
  backlog             100
  instances           1
  priority            0
  memSoftLimit        2047M
  memHardLimit        2047M
  procSoftLimit       1400
  procHardLimit       1500
  extMaxIdleTime      ...   # optional; kills idle workers
}
```

### Two process modes ([LSPHP options doc](https://docs.litespeedtech.com/lsws/extapp/php/configuration/options/), [php-src LSAPI README](https://github.com/php/php-src/blob/master/sapi/litespeed/README.md))
- **Worker mode**: `PHP_LSAPI_CHILDREN=1`, `instances` = `maxConns`. Each process independent. Rarely used now.
- **ProcessGroup mode** (preferred): `instances 1`, `PHP_LSAPI_CHILDREN = maxConns` (>1). One parent lsphp forks children on demand; **all children share one opcode-cache memory block** — major RAM saving for WordPress.

**Golden rule: `maxConns` must equal `PHP_LSAPI_CHILDREN`.** Mismatch causes either queuing (508s) or zombie children.

### Key environment variables (defaults from official docs)

| Variable | Default | Tuning guidance |
|---|---|---|
| `PHP_LSAPI_CHILDREN` / `LSAPI_CHILDREN` | 35 (LSWS doc) / 10 (OLS shipped) | = max simultaneous PHP requests. Size by RAM and CPU, not hope (formula below). |
| `PHP_LSAPI_MAX_REQUESTS` / `LSAPI_MAX_REQS` | 10000 | Requests per child before recycling — defends against PHP memory leaks. 500–10000; lower (500–1000) for leaky plugin stacks. |
| `LSAPI_AVOID_FORK` | 0 | `0` = kill children when idle, fork on demand (shared hosting, low RAM). `1` = keep children resident (dedicated/perf-focused; avoids fork latency). Can take a size: `LSAPI_AVOID_FORK=200M` keeps children alive only while ≥200M free; bare `=1` requires ≥1 GB free or it silently behaves like 0 ([forum](https://forum.openlitespeed.org/threads/lsapi_avoid_fork-and-lsapi_max_idle.6141/)). |
| `LSAPI_MAX_IDLE` | 300 s | Idle child lifetime in ProcessGroup mode before exit. Lower (30–60) on RAM-starved boxes; raise (3600) on RAM-rich dedicated WP servers to keep warm workers. |
| `LSAPI_MAX_IDLE_CHILDREN` | CHILDREN/3 (avoid_fork=0) or CHILDREN (=1) | Cap on resident idle children. |
| `LSAPI_EXTRA_CHILDREN` | CHILDREN/3 (avoid_fork=0); 0 (=1) | Emergency headroom when children malfunction. |
| `LSAPI_MAX_PROCESS_TIME` | 3600 s | Hard kill for runaway requests; drop to 300–600 for WP, keep higher only if WP-CLI/imports run through web. |
| `LSAPI_PGRP_MAX_IDLE` | FOREVER | Parent process idle timeout. |
| `LSAPI_ACCEPT_NOTIFY` | 0 | Set 1 — notify on new connection only; recommended perf tweak. |
| `LSAPI_SLOW_REQ_MSECS` | 0 | Set e.g. 5000 to log slow requests — cheap profiling. |
| `LS_OOM_SCORE_ADJ` | — | Protect/expose lsphp to the kernel OOM killer. |

### Process limits in the extprocessor block
- **`memSoftLimit` / `memHardLimit`** (default 2047M) — per-process address-space rlimit for lsphp, *not* php.ini `memory_limit`. Must be > PHP `memory_limit` + opcache + overhead. Low-RAM boxes: 300M–512M soft to contain runaways.
- **`procSoftLimit` / `procHardLimit`** (1400/1500) — total process count rlimit per user.
- **`extMaxIdleTime`** — server-side idle-app teardown (seconds); `-1`/unset = never stop. LiteSpeed's shared-hosting guide suggests **3600** if you have free RAM (keep apps warm), small values (10–60) when scavenging RAM ([shared tuning guide](https://docs.litespeedtech.com/lsws/tuning-shared/)).
- **`initTimeout`** 60, `retryTimeout` 0, `persistConn` 1, `backlog` 100 — keep defaults.
- LSWS Enterprise/cPanel: per-account cap is **PHP suEXEC Max Conn** (default 10; 15–20 if resources allow); per-vhost override via Apache config: `<IfModule LiteSpeed> LSPHP_Workers 100 </IfModule>`; `LSPHP_MaxWaitQ` returns 508 beyond queue depth.

### RAM-aware sizing formula
Practical formula used across LiteSpeed guides/forums:

```
PHP_LSAPI_CHILDREN ≈ (RAM_total − OS − MySQL − LSWS − cache) / avg_lsphp_RSS
```

- avg lsphp RSS for WordPress ≈ 30–60 MB (vanilla) up to 80–150 MB (WooCommerce with many plugins). Measure: `ps -ylC lsphp --sort:rss`.
- Also bound by CPU: more than ~4–8 children per core just thrashes; "it would be unrealistic to attempt 100 max connections on a server with two cores and 2GB RAM" ([LSWS shared tuning](https://docs.litespeedtech.com/lsws/tuning-shared/)).
- Watch **WaitQ** in WebAdmin Real-Time Stats → External App; persistently >0 means raise children or fix slow code. Error log "Reached max children process limit" = raise `PHP_LSAPI_CHILDREN`/`maxConns` ([high-load doc](https://docs.litespeedtech.com/lsws/cp/cpanel/high-load/)).

### PHP-side settings that pair with LSAPI
- `memory_limit`: WordPress 256–512M; WooCommerce 256M minimum, 512M comfortable; Magento 768–1024M ([shared tuning guide](https://docs.litespeedtech.com/lsws/tuning-shared/), [Woo docs](https://woocommerce.com/document/increasing-the-wordpress-memory-limit/)).
- OPcache **on** (ProcessGroup mode shares it): `opcache.memory_consumption=128–256`, `opcache.max_accelerated_files=10000–20000`.
- php.ini path per version: `/usr/local/lsws/lsphpXX/etc/php/X.X/litespeed/php.ini`; apply with `killall lsphp` (children respawn) — no full server restart needed.
- Disable `xdebug`/`snmp` modules in production; enable `timezonedb`.

---

## 4. HTTP/3 / QUIC

LiteSpeed wrote **LSQUIC** — both editions have first-class HTTP/3 (LSWS ≥5.4 / OLS ≥1.7). Mostly zero-config:

- **Server level** (`quicEnable` / "Enable HTTP3/QUIC"): default **on**. Per-listener: `Open HTTP3/QUIC (UDP) Port = Yes` on the SSL listener; ALPN must include h2 + h3; TLS 1.3 required for HTTP/3.
- **Firewall**: open **UDP 443** in/out (`ufw allow 443/udp`; CSF: add 443 to UDP_IN/UDP_OUT **and set UDPFLOOD = 0** or QUIC gets rate-killed; iptables: `iptables -I INPUT -p udp --dport 443 -j ACCEPT`). ([enable_quic wiki](https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:config:enable_quic), [Contabo guide](https://contabo.com/blog/how-to-enable-http-3-in-litespeed-web-server/), [RunCloud guide](https://runcloud.io/docs/setup-http-3-and-quic))
- **Alt-Svc** header advertising h3 is emitted automatically — do not set manually.
- If behind Cloudflare: QUIC terminates at the CDN; origin QUIC is then irrelevant.
- Tunables (defaults are good — [LSWS tuning docs](https://www.litespeedtech.com/docs/webserver/config/tuning)): `quicShmDir` **/dev/shm** (keep on RAM disk), versions list blank (auto), congestion control Default, connection flow-control window 1.5M (64K–512M), stream window 1M, max concurrent streams/connection 100, handshake timeout 10 s, idle timeout 30 s, DPLPMTUD on.
- Verify: `curl --http3 -I https://site/` or https://http3check.net.

```
# OLS httpd_config.conf — listener with HTTP/3
listener HTTPS {
  address                 *:443
  secure                  1
  keyFile                 /path/privkey.pem
  certFile                /path/fullchain.pem
  enableQuic              1        # default on when secure
}
```

---

## 5. Server-level LSCache engine

LSCache is a server-internal page cache (think varnish-quality, zero proxy hop). The WP plugin (LSCWP) only *manages* it via response headers (`X-LiteSpeed-Cache-Control`, `X-LiteSpeed-Tag`, `X-LiteSpeed-Purge`); storage and policy live in the **server**.

### OpenLiteSpeed — `module cache` block ([OLS lscache doc](https://docs.openlitespeed.org/config/lscache/))

Server level (`/usr/local/lsws/conf/httpd_config.conf`):

```
module cache {
  internal                1
  ls_enabled              1
  storagePath             $SERVER_ROOT/cachedata   # default if unset
  checkPrivateCache       1
  checkPublicCache        1
  maxCacheObjSize         10000000     # 10 MB max cached object
  maxStaleAge             200
  qsCache                 1            # cache URLs with query strings
  reqCookieCache          1            # serve cache to cookie-bearing requests
  respCookieCache         1            # cache responses with Set-Cookie
  ignoreReqCacheCtrl      1            # ignore client Cache-Control (yes - clients lie)
  ignoreRespCacheCtrl     0            # OBEY app's X-LiteSpeed-Cache-Control (needed for LSCWP)
  enableCache             0            # leave 0 server-wide!
  expireInSeconds         3600
  enablePrivateCache      0
  privateExpireInSeconds  3600
}
```

Per-vhost override (recommended — separate storage per site):

```
module cache {
  storagePath $VH_ROOT/lscache
  ...
}
```

Key facts:
- **Do not set `enableCache 1` server-wide** — official guidance is to leave forced caching off at server level and let the LSCWP plugin drive caching via headers (`ignoreRespCacheCtrl 0` makes the server obey them). `enableCache`/`enablePrivateCache` are deliberately meant for vhost/context level.
- `storagePath` relative paths resolve against `$SERVER_ROOT` (/usr/local/lsws); variables `$VH_ROOT`, `$VH_NAME`, `$SERVER_ROOT` allowed. Put it on **fast disk or tmpfs**; cache objects are small files.
- Without LSCWP, you can force-cache via rewrite rules: `RewriteRule .* - [E=cache-control:max-age=120]` (values: `max-age`, `s-maxage`, `public`, `private`, `no-cache`, `no-store`, `max-stale`, `esi`, `no-vary`) — works in OLS vhost rewrite section and LSWS .htaccess ([no-plugin settings](https://docs.litespeedtech.com/lscache/noplugin/settings/), [devguide controls](https://docs.litespeedtech.com/lscache/devguide/controls/)).

### LiteSpeed Enterprise — Apache-style directives ([LSWS+cPanel LSCache](https://docs.litespeedtech.com/lsws/cp/cpanel/lscache/))

```apache
# server level, e.g. /etc/apache2/conf.d/includes/pre_main_global.conf
<IfModule Litespeed>
  CacheRoot   /home/lscache/        # dedicated partition with space
  CacheEngine on esi crawler        # global engine on, ESI + crawler support
</IfModule>

# vhost level: CacheRoot lscache  →  /home/<user>/lscache

# site/.htaccess level
<IfModule LiteSpeed>
  CacheLookup public on             # check cache for hits (LSCWP needs this)
  # or manual: CacheEnable public /   |   CacheDisable public /admin
</IfModule>
```

- `CacheEngine` is server/vhost-only (never .htaccess); `CacheLookup`/`CacheEnable`/`CacheDisable` work in .htaccess.
- Enterprise extras vs OLS cache module: ESI (edge-side includes for WooCommerce mini-cart/private blocks), crawler support, `CacheMaxStaleAge`, per-package cache limits. **WooCommerce note:** ESI is Enterprise-only — on OLS, cart/checkout pages simply bypass cache instead of using hole-punching.

---

## 6. Security / anti-DDoS (server level)

### Per-client throttling ([OLS throttling doc](https://docs.openlitespeed.org/security/throttling/), defaults from shipped config)

```
perClientConnLimit {
  staticReqPerSec     0        # 0 = unlimited (default)
  dynReqPerSec        0
  outBandwidth        0        # bytes/s, rounded up in 4KB units
  inBandwidth         0
  softLimit           10000    # concurrent conns per IP before grace clock starts
  hardLimit           10000    # absolute per-IP concurrent connection cap
  gracePeriod         15       # seconds over softLimit allowed
  banPeriod           300      # seconds banned after violation
  blockBadReq         1        # ban IPs sending malformed requests
}
```

Recommended hardening for WordPress hosting (community + LiteSpeed anti-DDoS guidance — [anti-DDoS doc](https://docs.litespeedtech.com/lsws/cp/cpanel/antiddos/), [OLS doc example](https://docs.openlitespeed.org/security/throttling/)):

```
perClientConnLimit {
  staticReqPerSec   40     # (range seen in guides: 10–40)
  dynReqPerSec      2      # 1–5; this is the big DDoS lever — PHP is expensive
  softLimit         15     # 15–25
  hardLimit         20     # 20–30
  gracePeriod       15
  banPeriod         60     # or 300 for stricter
  blockBadReq       1
}
```

Note `dynReqPerSec` counts per-IP; NAT'd offices/proxies can trip it — whitelist trusted IPs in `accessControl`. Throttled requests are delayed, not dropped, until limits force a ban.

### reCAPTCHA / hCaptcha protection (LSWS ≥5.4, OLS supported) ([LSWS recaptcha doc](https://docs.litespeedtech.com/lsws/recaptcha/), [OLS recaptcha doc](https://docs.openlitespeed.org/security/recaptcha/))
- When connection counts cross thresholds, suspicious clients get a CAPTCHA challenge page instead of denial.
- WebAdmin: Configuration → Server → Security → CAPTCHA. Settings: Enable CAPTCHA, Type (reCAPTCHA Invisible / Checkbox / hCaptcha), Site Key + Secret Key (defaults exist but register your own), **Max Tries** (default 3), **Connection Limit** (default 15000), **SSL Connection Limit** (default 10000) — lower these (e.g. a bit above normal peak) so the trigger actually fires under attack.
- **Bot White List** + **Allowed Robot Hits** (hits per same URL per 10 s for whitelisted bots) keep Googlebot etc. unchallenged.
- Vhost override: `LsRecaptcha <sensitivity 0–100>` directive (higher = triggers more readily).

### WordPress brute-force protection — **Enterprise only** ([wp-protect doc](https://docs.litespeedtech.com/lsws/cp/cpanel/wp-protect/))
```apache
<IfModule LiteSpeed>
  WordPressProtect drop, 10      # drop connection (no reply) after 10 wp-login/xmlrpc attempts
  # or: WordPressProtect throttle, 20   |   deny → 403 only, doesn't block IP
</IfModule>
```
Works at server / vhost / .htaccess level. On OLS, emulate with rewrite-rule rate limiting or fail2ban on the access log.

### ModSecurity
- **Enterprise**: native high-performance async engine, ModSec 2.9-style syntax; works with OWASP CRS 3+, Atomicorp, Imunify360. Comodo's "LiteSpeed" vendor set is deprecated — use Comodo's **Nginx/ModSec_3.0** ruleset where ModSec3 engines are involved ([forum](https://www.litespeedtech.com/support/forum/threads/comodo-modsecurity-ruleset-no-longer-supported-with-modsecurity.21453/)). Benchmarks: LSWS stays fastest with CRS enabled; Comodo rules slower than OWASP ([perf blog](https://blog.litespeedtech.com/2019/12/02/modsecurity-performance-apache-nginx-litespeed/)).
- **OpenLiteSpeed**: ModSecurity **3.x only** via module block ([OLS modsecurity doc](https://docs.openlitespeed.org/modules/modsecurity/)):

```
module mod_security {
  modsecurity on
  modsecurity_rules `
    SecRuleEngine On
  `
  modsecurity_rules_file /usr/local/lsws/conf/owasp/modsec_includes.conf
  ls_enabled 1
}
```
CRS install: unzip coreruleset v3/v4 into `/usr/local/lsws/conf/owasp/`, rename `crs-setup.conf.example` and the two exclusion `.example` files, list them in a master include.

### Other security blocks (shipped defaults)
```
accessControl { allow ALL }            # IP allow/deny lists
CGIRLimit {
  maxCGIInstances 20
  minUID 11  minGID 10
  CPUSoftLimit 10  CPUHardLimit 50
  memSoftLimit 2047M  memHardLimit 2047M
}
```
Plus: `connTimeout` low for slowloris resistance, `verifyGoogleBot` (PTR-verify claimed Googlebots), Secure Cookie/SameSite control, SSL session cache + tickets (enable session cache; ticket lifetime 3600 s with auto key rotation).

---

## 7. CLI / admin interfaces & programmatic config

### lswsctrl (both editions) — `/usr/local/lsws/bin/lswsctrl` ([OLS commands](https://docs.openlitespeed.org/commands/), [LSWS commands](https://docs.litespeedtech.com/lsws/commands/))
- `lswsctrl start | stop | restart` — restart is graceful (existing requests finish).
- `lswsctrl reload` — re-read config without dropping the listener (preferred for automated tuning loops).
- `systemctl restart lsws` works where the unit is installed.
- `lswsctrl status`, `lswsctrl help`.

### WebAdmin console
- `https://server:7080` (both editions). Reset credentials: `/usr/local/lsws/admin/misc/admpass.sh`. Admin listener config: `/usr/local/lsws/admin/conf/admin_config.conf` (OLS) / `admin_config.xml` (LSWS).
- Real-Time Stats panel = primary tuning feedback (External App **WaitQ**, in-use connections, req/s).
- Apply changes via the console's **Graceful Restart** button.

### Scripted edits
- **OLS**: `httpd_config.conf` is a flat, line-oriented `key value` / `block { }` format — ideal for sed/python edits. Use `include /path/file.conf` to keep automated changes in separate files that survive manual edits ([includes doc](https://docs.openlitespeed.org/config/advanced/includes/)). Vhost configs live in `conf/vhosts/<name>/vhconf.conf`. After edits: `lswsctrl restart` (config syntax errors fall back to last good config; check `/usr/local/lsws/logs/error.log`). RunCloud/CyberPanel both manage OLS exactly this way ([RunCloud doc](https://runcloud.io/docs/openlitespeed-configuration)).
- **LSWS Enterprise**: avoid scripting the XML directly (it's GUI-managed and a restart-validated format; people who script it do XML-aware edits — [forum](https://www.litespeedtech.com/support/forum/threads/resolved-scripting-httpd_config-xml.906/)). Instead drop Apache-style directives into Apache include files (cPanel: `/etc/apache2/conf.d/includes/pre_main_global.conf`, per-vhost userdata includes, or `.htaccess`) — LSWS reads Apache config natively and auto-detects .htaccess changes with no restart.
- Config file ownership: OLS config must stay readable by `lsadm`; preserve permissions when scripting.

---

## 8. RAM-aware tuning recommendations (VPS sizes)

Assumptions: single/few WordPress or WooCommerce sites, MariaDB on the same box, LSCache enabled (so most traffic never reaches PHP — that's why modest worker counts hold up). Derived from: [OLS 1GB forum thread](https://forum.openlitespeed.org/threads/openlitespeed-configuration-for-1-gb-ram.4930/), [1-gig fine-tune thread](https://forum.openlitespeed.org/threads/how-to-fine-tune-the-server-settings-for-1gig-of-memory.5337/), [low-RAM advice thread](https://forum.openlitespeed.org/threads/advices-for-settings-for-low-ram-settings.5514/), [LSWS shared tuning](https://docs.litespeedtech.com/lsws/tuning-shared/), [cPFence large-server guide](https://cpfence.app/how-to-optimize-openlitespeed-for-large-shared-hosting-servers/).

| Setting | 1 GB / 1 vCPU | 2 GB / 2 vCPU | 4 GB / 2–4 vCPU | 8 GB+ / 4–8 vCPU |
|---|---|---|---|---|
| `PHP_LSAPI_CHILDREN` = `maxConns` | 10–15 (forum: up to 30 if lean) | 20–35 | 35–60 | 60–100+ (per pool) |
| `LSAPI_AVOID_FORK` | 0 | 0 (or `=200M`) | `=500M` or 1 | 1 |
| `LSAPI_MAX_IDLE` | 30–60 | 60–300 | 300 | 3600 (keep warm) |
| `extMaxIdleTime` | 10–60 | 60–300 | 300–3600 | 3600 |
| `memSoftLimit`/`memHardLimit` | 300M/350M | 512M/512M | 1024M | 2047M (default) |
| PHP `memory_limit` | 128–256M | 256M | 256–512M | 512M (Woo) |
| `PHP_LSAPI_MAX_REQUESTS` | 500–1000 | 1000–5000 | 5000–10000 | 10000 |
| `maxConnections` | 2000 | 5000 | 10000 (default) | 10000–100000 |
| `keepAliveTimeout` | 2–3 | 3–5 | 5 | 5 (or 2–3 + smartKeepAlive 1 if very busy) |
| `connTimeout` | 30 | 30–60 | 60 | 60–300 |
| `totalInMemCacheSize` | 20M | 32M | 64M | 128–256M |
| `totalMMapCacheSize` | 40M | 40M | 80M | 160M+ |
| OPcache memory | 64M | 128M | 192M | 256M |
| `dynReqPerSec` (per IP) | 1–2 | 2 | 2–5 | 5 |
| `staticReqPerSec` (per IP) | 10–20 | 20–40 | 40 | 40–100 |

Notes:
- Field report: 2 vCPU / 2 GB OLS box handles ~5000–7000 pageviews/day across 2 WP sites at ~1.5 GB RAM used ([LowEndTalk](https://lowendtalk.com/discussion/163917/what-specs-do-i-need-for-wp-with-openlitespeed)).
- Children formula: `(RAM − ~300M OS − MySQL allocation − ~150M LSWS+caches) / per-process RSS`. WooCommerce RSS 80–150 MB → on 2 GB with MariaDB taking 512M, ~8–12 children is the honest number; LSCache hit ratio is what makes that sufficient.
- Don't copy large-server configs to small VPSes — defaults are already close to right for ≤2 GB; the highest-leverage changes are LSCache + OPcache + correct `maxConns/CHILDREN`, in that order.
- LSWS Enterprise: license worker count ≈ 25% of cores is LiteSpeed's guidance; sustained LSWS CPU >60% with low overall load ⇒ needs more worker processes (bigger license tier) ([choosing a license](https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:licenses:choosing-a-license)).

---

## 9. Quick checklist for an automated optimizer

1. Detect edition: `httpd_config.xml` present → Enterprise (edit via Apache includes/.htaccess); `httpd_config.conf` → OLS (edit native config, prefer `include` files).
2. Read RAM/cores → compute `PHP_LSAPI_CHILDREN`/`maxConns` from the formula; set matching pair.
3. Set `LSAPI_AVOID_FORK` per RAM tier; `LSAPI_MAX_REQS` 1000–10000; `extMaxIdleTime` per tier.
4. Tuning block: keepAliveTimeout 5, maxKeepAliveReq ≥1000, connTimeout 30–60, gzip+brotli on, gzipAutoUpdateStatic 1, sndBuf/rcvBuf 0.
5. Cache: vhost `module cache` with `storagePath $VH_ROOT/lscache`, `ignoreRespCacheCtrl 0`, `enableCache 0` (LSCWP drives it); Enterprise: `CacheRoot /home/lscache/` + `CacheEngine on esi crawler` + `CacheLookup public on`.
6. Security: perClientConnLimit (dyn 2/s, static 40/s, soft 15 / hard 20, blockBadReq 1), CAPTCHA enabled with sane thresholds, ModSec CRS optional, `WordPressProtect drop, 10` on Enterprise.
7. HTTP/3: confirm enableQuic + UDP 443 open (and CSF UDPFLOOD off).
8. Apply with `lswsctrl restart` (graceful); verify via Real-Time Stats WaitQ, `curl --http3`, `x-litespeed-cache: hit` header.

---

## Sources

- https://www.litespeedtech.com/products/litespeed-web-server/editions — OLS vs Enterprise feature matrix
- https://forum.openlitespeed.org/threads/what-is-the-complete-difference-beetwen-openlitespeed-litespeed-enterprise.795/
- https://www.litespeedtech.com/docs/webserver/config/tuning — LSWS tuning parameter reference (incl. HTTP/3 tunables)
- https://github.com/litespeedtech/openlitespeed/blob/master/dist/conf/httpd_config.conf.in — shipped OLS defaults
- https://github.com/litespeedtech/openlitespeed/blob/master/dist/docs/ServTuning_Help.html / https://fossies.org/linux/openlitespeed/dist/docs/ServTuning_Help.html — OLS tuning help
- https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:config:keep_alive — keep-alive guidance
- https://docs.litespeedtech.com/lsws/extapp/php/configuration/options/ — LSAPI env vars & defaults
- https://github.com/php/php-src/blob/master/sapi/litespeed/README.md — LSAPI SAPI reference
- https://forum.openlitespeed.org/threads/lsapi_avoid_fork-and-lsapi_max_idle.6141/ — AVOID_FORK memory threshold behavior
- https://docs.litespeedtech.com/lsws/tuning-shared/ — shared-hosting tuning guide (suEXEC Max Conn, WaitQ, memory limits)
- https://docs.litespeedtech.com/lsws/cp/cpanel/high-load/ — high-load diagnostics
- https://docs.openlitespeed.org/config/lscache/ — OLS cache module config
- https://docs.litespeedtech.com/lsws/cp/cpanel/lscache/ — Enterprise CacheRoot/CacheEngine
- https://docs.litespeedtech.com/lscache/noplugin/settings/ — rewrite-rule cache control
- https://docs.litespeedtech.com/lscache/devguide/controls/ — cache-control env values
- https://docs.openlitespeed.org/security/throttling/ — per-client throttling params + example values
- https://docs.litespeedtech.com/lsws/cp/cpanel/antiddos/ — anti-DDoS handbook
- https://docs.litespeedtech.com/lsws/recaptcha/ and https://docs.openlitespeed.org/security/recaptcha/ — CAPTCHA protection
- https://docs.litespeedtech.com/lsws/cp/cpanel/wp-protect/ — WordPressProtect directive
- https://docs.openlitespeed.org/modules/modsecurity/ — OLS ModSecurity module
- https://www.litespeedtech.com/support/forum/threads/comodo-modsecurity-ruleset-no-longer-supported-with-modsecurity.21453/
- https://blog.litespeedtech.com/2019/12/02/modsecurity-performance-apache-nginx-litespeed/
- https://docs.openlitespeed.org/commands/ and https://docs.litespeedtech.com/lsws/commands/ — lswsctrl
- https://docs.openlitespeed.org/config/advanced/includes/ — OLS include files
- https://runcloud.io/docs/openlitespeed-configuration — config-file tuning workflow
- https://runcloud.io/docs/setup-http-3-and-quic and https://contabo.com/blog/how-to-enable-http-3-in-litespeed-web-server/ and https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:config:enable_quic — HTTP/3 setup
- https://docs.litespeedtech.com/licenses/products/lsws/ and https://store.litespeedtech.com/store/index.php?rp=/knowledgebase/188/ and https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:licenses:choosing-a-license — license limits & worker sizing
- https://forum.openlitespeed.org/threads/openlitespeed-configuration-for-1-gb-ram.4930/ and https://forum.openlitespeed.org/threads/how-to-fine-tune-the-server-settings-for-1gig-of-memory.5337/ and https://forum.openlitespeed.org/threads/advices-for-settings-for-low-ram-settings.5514/ — low-RAM tuning threads
- https://lowendtalk.com/discussion/163917/what-specs-do-i-need-for-wp-with-openlitespeed — real-world 2GB capacity report
- https://cpfence.app/how-to-optimize-openlitespeed-for-large-shared-hosting-servers/ — large-server OLS tuning
- https://woocommerce.com/document/increasing-the-wordpress-memory-limit/ — Woo memory guidance
- https://www.litespeedtech.com/support/forum/threads/resolved-scripting-httpd_config-xml.906/ — scripting the Enterprise XML
- https://docs.litespeedtech.com/lsws/configuration/ — LSWS configuration overview
