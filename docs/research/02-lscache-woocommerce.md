# LiteSpeed Cache (LSCWP) + WooCommerce on LiteSpeed Servers — Research Report

Date: 2026-06-10. Sources cited inline. Focus: architecture, WooCommerce specifics, optimal settings, crawler, object cache, pitfalls/CVEs, page optimization, QUIC.cloud, verification, wp-cli.

---

## 1. Architecture: how LSCWP talks to the server cache engine

LSCache is **server-level cache** — the page store lives inside LiteSpeed Web Server (Enterprise), OpenLiteSpeed, or LiteSpeed Web ADC, not in PHP/files like WP Rocket. The WordPress plugin is a *controller*: it never stores pages itself; it emits **internal response headers** that the server reads, acts on, and strips before the response reaches the client.

Request flow:

1. Server-level **rewrite rules** (`CacheLookup on` inside `<IfModule LiteSpeed>`) intercept the request before PHP and look up a cache object (keyed by URL + vary).
2. **Hit** → served straight from the server cache, PHP never runs.
3. **Miss** → WordPress runs; LSCWP evaluates the response (content type, user state, config) and attaches directives; the server stores the object accordingly.

Control headers (internal, server-consumed):

- `X-LiteSpeed-Cache-Control` — like `Cache-Control` but for the LSCache engine only; if both are present the server uses this one and browsers ignore it. Directives: `public`, `private`, `shared`, `no-cache`, `no-store`, `no-vary`, `esi=on`, `max-age=<sec>`. Examples:
  - `X-LiteSpeed-Cache-Control: public,max-age=3600`
  - `X-LiteSpeed-Cache-Control: private,max-age=86400`
  - `X-LiteSpeed-Cache-Control: esi=on`
- `X-LiteSpeed-Tag` — attaches tags to the stored object for grouped purging. ASCII only, comma-separated, `public:` prefix reserved. Example: `X-LiteSpeed-Tag: public:pubtag1,privtag1`.
- `X-LiteSpeed-Purge` — purge by tag or URL (no wildcards/regex except `*` for all):
  - `X-LiteSpeed-Purge: *` (all public)
  - `X-LiteSpeed-Purge: public,tag=Cat1,tag=Page2`
  - `X-LiteSpeed-Purge: private,tag=privtag1` (private purge must say `private`)
  - `X-LiteSpeed-Purge: url=/page.php`
  - Combined: `X-LiteSpeed-Purge: public,tag=pubtag1;private,tag=privtag1`
- `X-LiteSpeed-Vary` — declare vary cookies/values: `X-LiteSpeed-Vary: cookie=my_cookie,value=ismobile`.

This tag system is what powers LSCWP's "Smart Purge": when a product/post updates, the plugin purges just the tags for that post, its category/tag archives, home page, etc., instead of flushing everything.

Sources: [LSCache Dev Guide — Basic Controls](https://docs.litespeedtech.com/lscache/devguide/controls/), [Advanced Concepts](https://docs.litespeedtech.com/lscache/devguide/advanced/), [X-LiteSpeed-Cache-Control header guide](https://http.dev/x-litespeed-cache-control), [Getting Started](https://docs.litespeedtech.com/lscache/start/).

### .htaccess rules LSCWP generates

LSCWP maintains a `# BEGIN LiteSpeed` block in `.htaccess` automatically (don't hand-edit). It must appear **before** the WordPress rewrite block. Core pieces:

```apache
<IfModule LiteSpeed>
RewriteEngine on
CacheLookup on
RewriteRule .* - [E=Cache-Control:no-autoflush]
# WebP vary (when image optimization / WebP replacement is on):
RewriteCond %{HTTP_ACCEPT} "image/webp" [or]
RewriteCond %{HTTP_USER_AGENT} "Page Speed"
RewriteRule .* - [E=Cache-Control:vary=%{ENV:LSCACHE_VARY_VALUE}+webp]
# Mobile vary (when "Cache Mobile" is on):
RewriteCond %{HTTP_USER_AGENT} Mobile|Android|Silk/|Kindle|BlackBerry|Opera\ Mini|Opera\ Mobi [NC]
RewriteRule .* - [E=Cache-Control:vary=%{ENV:LSCACHE_VARY_VALUE}+ismobile]
# Login cookie (multi-app docroot):
RewriteRule .? - [E="Cache-Vary:my_unique_login_cookie"]
</IfModule>
```

Key mechanics:
- `CacheLookup on` enables public-cache lookup for the docroot.
- `LSCACHE_VARY_VALUE` is the server-provided current vary string; rules **append** dimensions (`+webp`, `+ismobile`) so varies compose.
- Vary **cookies**: server stores a separate copy per cookie value; any cookie named `_lscache_vary*` is a vary cookie by default. LSCWP's login state is tracked via its vary cookie so logged-in users never receive the public (guest) copy.
- Vary **environment values** (`E=Cache-Control:vary=...`): only one value retained (last wins), unlike cookies which can stack.

Sources: [WpW: .htaccess and Rewrite Rules](https://blog.litespeedtech.com/2017/07/26/wpw-rewrite-rules-in-the-proper-order/), [LSCache Vary docs](https://docs.litespeedtech.com/lscache/devguide/advanced/), [WebP replacement wiki](https://www.litespeedtech.com/support/wiki/doku.php/litespeed_wiki:cache:lscwp:configuration:webpreplacement).

---

## 2. WooCommerce specifics

### Auto-detection (built in, no config needed)

When WooCommerce is active, LSCWP automatically:
- Excludes **Cart, Checkout, My Account** from public cache (do NOT add them manually — already handled).
- Treats the `woocommerce_items_in_cart` cookie as a **cache-vary trigger**: visitors with items in cart get private/vary-separated handling so a cached page never shows someone else's cart.
- Pre-defines several WooCommerce **ESI nonces** (incl. PayPal Checkout nonces).

What auto-detection does **not** cover: mini-cart ESI blocks, object-cache group exclusions, cart-fragment optimization, crawler tuning for large catalogs, multi-currency vary. ([LSCWP FAQ](https://docs.litespeedtech.com/lscache/lscwp/faq/), [Savvy WooCommerce guide](https://savvy.co.il/en/blog/wordpress-speed/litespeed-cache-woocommerce/))

### ESI for cart / mini-cart / fragments

ESI ("punch holes" in a public page, fill them with private/uncached blocks) is **highly recommended for WooCommerce**. Requirements: **LiteSpeed Enterprise or Web ADC, or QUIC.cloud CDN** — plain OpenLiteSpeed does NOT support ESI ([LSCWP Cache screens](https://docs.litespeedtech.com/lscache/lscwp/cache/), [ChemiCloud ESI glossary](https://chemicloud.com/glossary/term/edge-side-includes-esi/)).

- `Cache > ESI > Enable ESI: ON` — turns admin bar, comment form, and registered widgets into ESI blocks. Page body stays public-cached; the mini-cart block is served from **ESI private cache** and refreshed only when the cart changes — this kills the `?wc-ajax=get_refreshed_fragments` AJAX call on every page load ([Pofii cart fragments](https://www.pofii.com/blog/woocommerce-cart-fragments-stop-the-ajax-drag/), [WpW: ESI and LiteSpeed Cache](https://blog.litespeedtech.com/2017/09/06/wpw-esi-and-litespeed-cache/)).
- Per-widget control: each widget can be ESI `private`, `public`, or `no cache`, with its own TTL.
- **ESI Nonces**: list nonces (wildcards allowed) that should become ESI blocks so they expire independently of page TTL — prevents "nonce expired" checkout/add-to-cart failures on long-TTL pages.
- **Vary Groups** (ESI tab): assign vary group IDs per user role — essential for **role-based pricing** (wholesale vs retail) so each role gets its own cached copy of product pages.
- ESI mechanics underneath: `<esi:include src=...>` sub-requests (max 10 nesting levels), `esi:inline` for separately cached fragments, `as-var` only for private content < 8 KB ([Dev guide — Advanced](https://docs.litespeedtech.com/lscache/devguide/advanced/)).

### wc-ajax handling

- Cart fragments (`?wc-ajax=get_refreshed_fragments`) are POST/no-cache by nature — LSCache doesn't cache them, but they cost a PHP hit per page view. Mitigations: ESI mini-cart (above), `wp_dequeue_script('wc-cart-fragments')` everywhere except cart/checkout, and note WooCommerce ≥ 7.8 disables fragments by default unless a Cart Widget block renders ([WooCommerce dev blog](https://developer.woocommerce.com/2023/06/16/best-practices-for-the-use-of-the-cart-fragments-api/)).
- LSCWP `Cache > Advanced > AJAX Cache TTL` can cache specific *idempotent* AJAX actions (`action_name TTL`, e.g. `getads 30`) — never use for cart/checkout actions.

### The cookie trap

**Do NOT add `woocommerce_items_in_cart` (or `woocommerce_cart_hash`) to "Do Not Cache Cookies".** LSCWP already varies on it; putting it in the exclude list disables caching entirely for every visitor with a non-empty cart, tanking performance. Exclusion-by-cookie is a last resort for broken non-AJAX themes ([LiteSpeed blog: Fixing LSCache+WooCommerce conflicts](https://blog.litespeedtech.com/2017/05/31/wpw-fixing-lscachewoocommerce-conflicts/), [LSCWP FAQ](https://docs.litespeedtech.com/lscache/lscwp/faq/)).

### Multi-currency / geolocation vary

Multi-currency plugins (CURCY/WOOCS, WCML, Price Based on Country) break under page cache unless the currency lives in a **cookie** the cache varies on:

- Add the currency cookie under `Cache > Advanced > Vary Cookies` (LSCWP UI) — e.g. `wmc_current_currency` (CURCY), WCML's `wp-wpml_current_language`. Server-level equivalent: `CacheVary wp-wpml_current_language,wmc_current_currency` or a rewrite rule appending to `LSCACHE_VARY_VALUE` ([WPML forum thread](https://wpml.org/forums/topic/critical-woocommerce-multicurrency-cache-conflict-with-litespeed-user-selected-currency-reverting/), [VillaTheme CURCY support](https://villatheme.com/supports/topic/litespeed-cache-and-curcy-multi-currency/)).
- **Pure IP-geolocation pricing (no cookie) is fundamentally incompatible with full-page cache** — the first visitor's locale gets cached for everyone. Either have the geo plugin set a cookie on first hit (then vary on it), use ESI for the price block, or exclude affected pages. Also: the LSCWP crawler runs from the server's IP, so it can only warm one geo variant ([Aelia dynamic caching notes](https://aelia.freshdesk.com/support/solutions/articles/3000042591-how-to-add-dynamic-caching-to-your-site)).
- Each vary dimension **multiplies** cache copies (currencies × mobile × webp × roles) — keep dimensions minimal or hit ratio collapses.

### Private cache for logged-in users

- `Cache > Cache Logged-in Users: ON` stores **private per-session copies** (default private TTL 1800 s). Safe because copies are keyed to the user's vary cookie/session.
- With ESI ON, a better pattern: keep pages public and ESI-hole the personalized bits (greeting, mini-cart, account links) — far higher hit ratio than full private copies.

---

## 3. Optimal LSCWP settings for a WooCommerce store

Tested-consensus values from LiteSpeed docs + [Savvy 2026 guide](https://savvy.co.il/en/blog/wordpress-speed/litespeed-cache-optimal-settings/), [OnlineMediaMasters 2026](https://onlinemediamasters.com/litespeed-cache-settings/), [WisdmLabs Woo walkthrough](https://wisdmlabs.com/blog/speed-up-woocommerce-store-with-litespeed-cache-full-settings-walkthrough/), [TheSheryar Woo settings](https://thesheryar.com/litespeed-cache-settings-for-woocommerce/):

### Cache tab
| Setting | Value | Why |
|---|---|---|
| Enable Cache | ON | |
| Cache Logged-in Users | ON (with ESI) / OFF (low RAM, many users) | Private copies per user |
| Cache Commenters | OFF | Minor |
| Cache REST API | ON | Default |
| Cache Login Page | ON | |
| Cache favicon.ico / PHP resources | ON | |
| Cache Mobile | OFF unless truly different mobile HTML (AMP, mobile-specific plugins) | Doubles cache copies |

### TTL tab (plugin defaults are sane; Woo-adjusted)
| Setting | Default | WooCommerce recommendation |
|---|---|---|
| Public Cache TTL | 604800 (1 wk) | 604800; rely on tag-based auto-purge for freshness |
| Private Cache TTL | 1800 (30 min) | 1800 |
| Front Page TTL | 604800 | 86400–604800 (lower if promos rotate) |
| Feed TTL | 604800 | default |
| REST TTL | 604800 | default |
| Status codes | 3600 for 403/404/500 | default |
| Browser Cache TTL | 31557600 (1 yr) when Browser Cache ON | static assets fine at 1 yr; some Woo guides use ~1 month if asset names aren't versioned |

### Purge tab
- Purge All on Upgrade: ON.
- Keep default auto-purge hooks (post/term/archive).
- **Serve Stale: ON** — serves the expired copy while regenerating; big win for busy stores during purges.

### WooCommerce tab
- **Product Update Interval**: "Purge product on changes to the quantity or stock status" (recommended whenever stock quantity is displayed); the lighter option purges only on stock-status flips.
- **Vary for Mini Cart**: OFF by default; turn ON if you don't use ESI and the mini-cart shows stale counts (creates a separate cache copy for non-empty carts).

### ESI tab (LiteSpeed Enterprise / QUIC.cloud only)
- Enable ESI: ON. Cache Admin Bar: ON. Cache Comment Form: ON.
- ESI Nonces: add any third-party plugin nonces that misbehave (one per line, `*` wildcards OK).
- Vary Group per role if role-based pricing.

### Guest Mode & Guest Optimization — pitfalls
- **Guest Mode** (General tab): first-time visitors instantly get a default cached copy; a follow-up JS call fixes their actual vary. Good TTFB win and generally safe.
- **Guest Optimization**: applies maximum optimization (UCSS, WebP, etc.) to that guest copy. Risks: layout breakage; **UCSS file explosion** (a CSS file per variant per page → thousands of files, disk/inode exhaustion); **crawler count grows exponentially** with the extra varies; inflates lab scores while masking real-user issues ([LiteSpeed Guest Mode blog](https://blog.litespeedtech.com/2021/06/01/guest-mode-for-wordpress-in-lscwp-v4-0/), [ChemiCloud Guest Mode deep dive](https://chemicloud.com/blog/guest-mode-in-litespeed-cache/), [General screen docs](https://docs.litespeedtech.com/lscache/lscwp/general/)).
- **WooCommerce verdict**: Guest Mode ON is usually OK (cart/checkout are excluded anyway); Guest Optimization OFF unless tested end-to-end — it interacts badly with multi-currency/geo plugins (prices won't re-localize) and with the crawler.

---

## 4. Crawler (cache warmup)

- **Must be enabled at the server level** (Enterprise: `crawler` enabled in server/vhost config; cPanel hosts toggle it in the WHM LiteSpeed plugin). Otherwise LSCWP shows "Server crawler engine not enabled" — on shared hosting, ask the host ([hosting.com KB](https://kb.hosting.com/docs/enabling-the-litespeed-cache-crawler-for-wordpress), [Crawler docs](https://docs.litespeedtech.com/lscache/lscwp/crawler/)). Server admins can cap crawler resource use server-wide (override usleep, load limit, enable/disable) regardless of plugin settings.
- **Sitemap-based**: point `Crawler > Sitemap > Custom Sitemap` at any XML sitemap (default WP: `https://example.com/wp-sitemap.xml`); multiple sitemaps / index sitemaps supported. "Drop Domain from Sitemap" ON by default (saves DB).
- Key knobs (v7 moved several to wp-config constants):
  - Delay: 500 µs default — `LITESPEED_CRAWLER_USLEEP`
  - Run duration: capped 900 s
  - Interval between runs: 600 s — `LITESPEED_CRAWLER_RUN_INTERVAL`
  - **Crawl Interval** (full re-crawl cadence): set slightly above your measured full-crawl time
  - Threads: 3 — `LITESPEED_CRAWLER_THREADS`
  - **Server Load Limit: 1.0 default** (per-core; 0 disables) — crawler self-throttles/halts above it
  - Timeout 30 s/page (`LITESPEED_CRAWLER_TIMEOUT`); sitemap timeout 120 s (`LITESPEED_CRAWLER_MAP_TIMEOUT`)
- **Role Simulation / Cookie Simulation**: crawl as a logged-in role or with specific cookies (e.g. one crawler per currency cookie value) to pre-warm those varies. Each simulated role/cookie/vary spawns an **additional crawler** — large catalogs × many varies = heavy load; this is the main reason hosts disable crawling.
- WooCommerce note: warm product/category pages; the crawler can't warm geo-IP variants (runs from the server IP).

Sources: [Crawler screen docs](https://docs.litespeedtech.com/lscache/lscwp/crawler/), [LiteSpeed crawler blog](https://blog.litespeedtech.com/2017/06/14/wpw-crawl-your-site-make-it-fly/).

---

## 5. Object cache (Redis/Memcached) and WooCommerce sessions

`Cache > Object` configures an external object cache: **Redis, Memcached, or LSMCD** (LiteSpeed's Memcached replacement). LSCWP installs its own drop-in — don't combine with another object-cache plugin.

Recommended values:
- **Method: Redis** (better fit for Woo sessions/transients; persistent connections, richer structures) ([LiteSpeed object cache blog](https://blog.litespeedtech.com/2018/02/07/object-cache-support-in-lscache/))
- Host `localhost` (or unix socket path with Port 0); Port 6379 (Redis) / 11211 (Memcached)
- **Default Object Lifetime: 360 s default** — for WooCommerce keep **≥ 600 s**; lower values have broken password-reset tokens and Woo session validation
- Persistent Connection: ON (default). Cache WP-Admin: ON (default). Store Transients: deprecated (always object-cached now)
- Global Groups (multisite shared): defaults (`users, userlogins, usermeta, user_meta, site-transient, site-options, ...`)
- **Do Not Cache Groups**: keep defaults (`comment`, `counts`, etc.); add `wc_session_id` or other session groups only if you observe stale-session/login issues — WooCommerce stores sessions in its own `wp_woocommerce_sessions` table via its session handler, but session *caching* through the object cache can go stale under aggressive TTLs or multi-server Redis setups
- Known friction: a reported incompatibility between LSCWP object cache and WooCommerce 10.5.x ([wp.org thread](https://wordpress.org/support/topic/litespeed-cache-bug-report-object-cache-incompatibility-with-woocommerce-10-5-1/)) — after Woo core updates, verify checkout + login, and `wp cache flush` after deploys.

Sources: [Object cache setup blog](https://blog.litespeedtech.com/2018/02/07/object-cache-support-in-lscache/), [Cache screen docs](https://docs.litespeedtech.com/lscache/lscwp/cache/), [Savvy guide](https://savvy.co.il/en/blog/wordpress-speed/litespeed-cache-optimal-settings/).

---

## 6. Pitfalls, cache-poisoning incidents, CVEs, hardening

### Cart/cache leakage incidents (misconfiguration class)
- Reported cases of **mini-cart showing another user's basket** traced to misconfiguration (e.g. enabling LSCWP "Browser Cache" on HTML/fragments, themes whose cart widget isn't AJAX, or caching layered CDNs in front that ignore LSCache varies) ([wp.org cart widget thread](https://wordpress.org/support/topic/cart-widget-caching-problems/), [LiteSpeed forum: cart cached](https://www.litespeedtech.com/support/forum/threads/litespeed-also-cache-the-cart.17372/), [MyGlobalHost compat KB](https://www.myglobalhost.net/kb/fixing-compatibility-issues-between-litespeed-cache-and-woocommerce/), [ChemiCloud conflict KB](https://chemicloud.com/kb/article/fix-litespeed-cache-woocommerce-conflicts/)).
- Symptoms: wrong cart totals, items vanishing at checkout, empty cart after visiting a cached page. Root causes: missing vary on cart cookie (third-party cart plugins not setting `woocommerce_items_in_cart`), a CDN (Cloudflare "cache everything") caching HTML in front of LiteSpeed, or ESI blocks failing to render.
- Conversion-tracking side effect: cached thank-you/cart flows can break analytics/pixels ([seresa.io](https://seresa.io/blog/data-loss/your-caching-plugin-is-breaking-woocommerce-conversion-tracking)).

### Known CVEs (awareness)
| CVE | Type | Affected | Fixed | Notes |
|---|---|---|---|---|
| **CVE-2024-28000** | Unauthenticated **privilege escalation** → admin, CVSS 9.8 | ≤ 6.3.0.1 | 6.4 | Weak security hash in the crawler's *user simulation* feature; any visitor could become admin ([Wordfence](https://www.wordfence.com/blog/2024/08/over-5000000-site-owners-affected-by-critical-privilege-escalation-vulnerability-patched-in-litespeed-cache-plugin/), [Patchstack](https://patchstack.com/articles/critical-privilege-escalation-in-litespeed-cache-plugin-affecting-5-million-sites/)) |
| **CVE-2024-44000** | Account takeover via **debug log leaking session cookies** | < 6.5.0.1 (with Debug Logging ON) | 6.5.0.1 | `wp-content/debug.log` publicly readable contained admin Set-Cookie values; fix moved log to randomized filename, dropped "Log Cookies" option ([Patchstack](https://patchstack.com/articles/critical-account-takeover-vulnerability-patched-in-litespeed-cache-plugin/), [BleepingComputer](https://www.bleepingcomputer.com/news/security/litespeed-cache-bug-exposes-6-million-wordpress-sites-to-takeover-attacks/)) |
| **CVE-2024-47374** | Unauthenticated **stored XSS** via `X-LSCACHE-VARY-VALUE` header, CVSS 7.2 | ≤ 6.5.0.2 | 6.5.1 | Header value stored/output unescaped ([Patchstack](https://patchstack.com/articles/unauthenticated-stored-xss-vulnerability-in-litespeed-cache-plugin-affecting-6-million-sites/), [TheHackerNews](https://thehackernews.com/2024/10/wordpress-litespeed-cache-plugin.html)) |
| **CVE-2023-40000** | Stored XSS (admin notice / nopriv AJAX) | ≤ 5.7 | 5.7.0.1 | Actively exploited in 2024 campaigns ([Qualys](https://threatprotect.qualys.com/2024/02/29/wordpress-litespeed-cache-plugin-cross-site-scripting-xss-vulnerability-cve-2023-40000/)) |

Full history: [WPScan LiteSpeed Cache page](https://wpscan.com/plugin/litespeed-cache/).

### Hardening recommendations
1. **Auto-update LSCWP** (or pin within days of release) — it's a 6M-install target with repeat critical CVEs.
2. **Debug Log OFF in production** (or "Admin IP Only" + remove after); never leave `WP_DEBUG_LOG` world-readable; block `*.log` in the webserver config.
3. **Disable crawler role simulation** unless needed (CVE-2024-28000 lived in user simulation).
4. Block direct access to `wp-content/debug.log` and the LSCWP debug directory at server level.
5. After any cache config change on a store: test add-to-cart → cart → checkout in a clean incognito session AND a second browser simultaneously to catch cross-user leakage.
6. Don't stack an HTML-caching CDN ("cache everything") in front of LSCache unless it honors the vary cookies (QUIC.cloud does; generic Cloudflare rules do not).
7. Never cache POST endpoints, `?wc-ajax=*` cart actions, or REST checkout routes.

---

## 7. Page Optimization features — safe vs risky for WooCommerce

([Page Optimization docs](https://docs.litespeedtech.com/lscache/lscwp/pageopt/), [CSS/JS troubleshooting](https://docs.litespeedtech.com/lscache/lscwp/ts-optimize/), [OnlineMediaMasters](https://onlinemediamasters.com/litespeed-cache-settings/), [BoostedHost guide](https://boostedhost.com/blog/en/litespeed-cache-best-settings-for-wordpress-2025-the-ultimate-practical-guide/))

**Safe defaults (low risk):**
- CSS Minify: ON
- JS Minify: ON
- HTML Minify: ON
- Font Display: Swap: ON
- Remove WP emoji / dashicons for guests: ON
- DNS Prefetch / Preconnect for third-party origins: ON
- Image optimization (QUIC.cloud): ON; **WebP Replacement: ON** (adds `+webp` vary via .htaccess — safe)
- Lazy-load images: ON, but **exclude above-the-fold/LCP product image** and product gallery thumbnails

**Risky — test on a Woo store, default OFF:**
- **CSS Combine** — required for UCSS but commonly breaks themes; expect to maintain excludes
- **UCSS (Generate Unique CSS)** — QUIC.cloud service; strips "unused" CSS that JS later needs (sliders, variation swatches, mini-cart drawers). Also file-explosion risk with Guest Optimization. If used: add UCSS File Excludes + per-selector safelist, and whitelist Woo classes
- **CCSS (Critical CSS)** — generally OK, but list every distinct post type design (product, product category) in "Separate CCSS Cache Post Types"
- **JS Combine** and **Load JS Deferred/Delayed** — top cause of broken add-to-cart buttons, carousels, payment-gateway widgets (Stripe/PayPal SDKs must NOT be delayed). Exclude checkout/payment scripts explicitly
- **Load CSS Asynchronously** — FOUC risk on product pages
- **Localize JS / Instant Click** — Instant Click prefetch can inflate server load and fire side-effecting GETs; keep OFF on stores
- **Guest Optimization** — see §3 pitfalls

Pragmatic Woo baseline: minify everything, no combine, no UCSS, no JS defer on cart/checkout; revisit only with a staging site + the `/e2e`-style purchase-path test after each toggle.

---

## 8. QUIC.cloud CDN integration (overview)

- Connect: `LiteSpeed Cache > General > Online Services` → Enable QUIC.cloud / Request Domain Key → Link to QUIC.cloud account ([QUIC.cloud onboarding](https://docs.quic.cloud/onboarding/enabling/), [Automatic setup blog](https://blog.litespeedtech.com/2022/08/08/automatic-quic-cloud-setup/)).
- DNS: either **CNAME** records to QUIC.cloud or switch nameservers to QUIC.cloud's free Anycast DNS (simpler, apex-safe) ([GridPane setup KB](https://gridpane.com/kb/how-to-set-up-quic-cloud-cdn/)).
- Distinguishing feature: it's the only CDN that caches **dynamic WordPress HTML at the edge with full LSCache semantics** — tags, Smart Purge on WP events, vary cookies, and **ESI at the edge**. This is how OpenLiteSpeed sites get ESI (OLS itself lacks it) ([QUIC.cloud LSCache service](https://www.quic.cloud/quic-cloud-services-and-features/litespeed-cache-service/), [Spiritual Agency ESI writeup](https://spiritual.agency/affordable-enterprise-grade-esi-caching-with-quic-cloud/)).
- Also hosts the page-optimization services LSCWP depends on: UCSS, CCSS, Low-Quality Image Placeholders, image optimization (WebP/AVIF), VPI. Free tier with quotas; LiteSpeed-server sites get larger free quotas.
- For Woo: edge ESI keeps cart/account fragments private at the PoP; QUIC.cloud honors the cart/currency varies that generic CDNs ignore.

---

## 9. Detecting / verifying LSCache works

Headers on the main HTML document (DevTools → Network → first request → Response Headers, in a logged-out window), or `curl -sI https://store.example/`:

| Header | Meaning |
|---|---|
| `x-litespeed-cache: hit` / `miss` | Served by LSWS/OLS cache. `miss` = freshly generated and (usually) now stored. Absent entirely → rules/plugin not active |
| `x-litespeed-cache: hit,litemage` | LiteMage variant (Magento) |
| `x-lsadc-cache: hit` | Served by LiteSpeed Web ADC layer |
| `x-qc-cache: hit` + `x-qc-pop: <location>` | Served by QUIC.cloud CDN edge (and which PoP) |
| `x-litespeed-cache-control: no-cache` | Page intentionally not cached (exclusion, cart cookie, logged-in w/o private cache…) — escaped internal header indicates plugin active but page excluded |

Debug workflow ([Troubleshooting guide](https://docs.litespeedtech.com/lscache/lscwp/troubleshoot/)):
1. `LiteSpeed Cache > Toolbox > Debug Settings`: Debug Log → **Admin IP Only**, Debug Level → Advanced.
2. View via Toolbox > Log View; log lines state *why* a page was no-cache (e.g. "Cache_control off - Admin configured URI Do not cache").
3. Check Excludes (URIs, query strings, cookies, user agents, roles) when a page repeatedly returns no-cache.
4. **Turn debug logging OFF afterwards** (CVE-2024-44000 class risk).
5. Woo-specific verification: incognito → product page should be `hit` on second load; cart/checkout/my-account must show `x-litespeed-cache-control: no-cache`; add item to cart → previously-cached pages must show correct mini-cart (ESI or vary working); second browser must NOT see the first browser's cart.

---

## 10. wp-cli commands (automation surface)

From [LSCWP CLI docs](https://docs.litespeedtech.com/lscache/lscwp/cli/) — all accept standard WP-CLI flags (`--path`, `--url` for multisite) except `litespeed-database`:

```bash
# Settings
wp litespeed-option all [--format=json]
wp litespeed-option get <key>
wp litespeed-option set <key> <value>      # e.g. wp litespeed-option set cache-priv false
wp litespeed-option export [--filename=path]
wp litespeed-option import <file>
wp litespeed-option import_remote <URL>
wp litespeed-option reset

# Presets / backups
wp litespeed-presets apply <preset>
wp litespeed-presets get_backups
wp litespeed-presets restore <backup_number>

# Purging
wp litespeed-purge all
wp litespeed-purge url <url>
wp litespeed-purge post_id 1 3 5
wp litespeed-purge category <ids> | tag <ids>
wp litespeed-purge blog <blogid>           # multisite
wp litespeed-purge network_list

# Crawler
wp litespeed-crawler list
wp litespeed-crawler enable <n> | disable <n>
wp litespeed-crawler run
wp litespeed-crawler reset

# QUIC.cloud image optimization
wp litespeed-image push | pull | status | clean | rm_bkup
wp litespeed-image batch_switch <optm|orig>

# QUIC.cloud account / CDN
wp litespeed-online init | sync | services | nodes
wp litespeed-online ping <service> [--force]
wp litespeed-online cdn_status
wp litespeed-online cdn_init --method=cname|ns|cfi [...]
wp litespeed-online link --email=... --api-key=...

# DB optimization (mirrors GUI buttons)
wp litespeed-database clear_posts | clear_comments | clear_trackbacks | clear_transients
wp litespeed-database optimize_tables | optimize_all   # [blog <id>] on multisite

# Support
wp litespeed-debug send
```

Automation notes for tooling: `litespeed-option export/import` enables config-as-code across stores; `litespeed-purge url`/`post_id` are the right hooks post-deploy or after price imports; `litespeed-crawler run` chains after `purge all` for warmup; option keys match those visible in `wp litespeed-option all`.

---

## Quick-reference: WooCommerce LSCWP checklist

1. Plugin updated (≥ 6.5.1; ideally current 7.x). Debug log OFF.
2. Cache ON; cart/checkout/my-account auto-excluded — don't double-exclude.
3. Never put `woocommerce_items_in_cart` in Do-Not-Cache Cookies.
4. LiteSpeed Enterprise or QUIC.cloud → ESI ON (+ nonces, + role vary groups if role pricing).
5. Multi-currency → currency cookie in Vary Cookies; pure geo-IP pricing → ESI or exclusion.
6. TTLs: public 604800 / private 1800 / Serve Stale ON; Product Update Interval = quantity+status.
7. Object cache: Redis, lifetime ≥ 600 s, defaults for groups; flush after Woo core updates.
8. Crawler: server-enabled, sitemap set, load limit 1.0, no role-sim unless required.
9. Page opt: minify ON; combine/UCSS/JS-defer OFF until purchase-path tested.
10. Verify: `x-litespeed-cache: hit` on products, `no-cache` on cart/checkout, two-browser cart isolation test.
