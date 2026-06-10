# LiteSpeed + WooCommerce CLI Optimizer — Independent Research Report
> Source: Gemini CLI (gemini-2.5-flash, Google Search grounding), generated 2026-06-10.
> Prompted in two parts to avoid truncation; combined below. Default model (pro) quota was exhausted, so flash was used.

---

# PART 1: LiteSpeed + WooCommerce CLI Optimizer Research Report

This report details a technical research for building an automated CLI optimizer (bash) for LiteSpeed servers (Enterprise LSWS and OpenLiteSpeed) hosting WordPress/WooCommerce. It covers server configuration tuning, LSCache + WooCommerce specifics, lsphp/opcache tuning, and automating LiteSpeed Cache plugin settings via `wp-cli`.

## 1. Complete Server Configuration Tuning Checklist

Optimizing the LiteSpeed Web Server configuration is crucial for WordPress/WooCommerce performance. These settings control how the server handles connections, processes PHP requests, and utilizes system resources. The recommendations below are generalized and should be fine-tuned based on actual server load, traffic patterns, and monitoring.

**Assumptions for RAM Tiers:**
*   **Operating System:** ~200-300MB
*   **MySQL/MariaDB:** ~200-700MB (for smaller sites) up to 1GB+ (for larger databases). We'll assume a moderate 700MB baseline for calculation of PHP workers, but acknowledge it can vary.
*   **OPcache:** ~128-256MB. We'll use 150MB as a baseline.
*   **PHP Worker Memory:** ~120MB per child process (this can vary based on `memory_limit` and application complexity).

### 1.1 `maxConnections` (Maximum Concurrent Connections)

This directive limits the total number of simultaneous client connections the web server can handle. Hitting this limit results in 503 Service Unavailable errors.

*   **Location (OpenLiteSpeed):**
    *   WebAdmin Console: `Server Configuration > Tuning > Max Connections`
    *   Configuration File: `/usr/local/lsws/conf/httpd_config.conf` (or similar, depending on installation)
*   **Location (LiteSpeed Enterprise):**
    *   WebAdmin Console: `Server Configuration > Tuning > Max Connections`
*   **Important:** LiteSpeed Enterprise licenses have connection limits (e.g., 500 for VPS, 800 for Ultra VPS). Ensure your configured `maxConnections` does not exceed your license limit.

| RAM Tier | Recommended `maxConnections` | Notes                                                                                                                                                                                                                                           |
| :------- | :--------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1 GB** | 500 - 1,000                  | Suitable for very low traffic sites. Performance will be heavily bottlenecked by RAM for PHP/MySQL.                                                                                                                                               |
| **2 GB** | 1,000 - 2,000                | Handles low to moderate traffic. Monitor closely.                                                                                                                                                                                               |
| **4 GB** | 2,000 - 4,000                | Good for moderate traffic sites. Provides a balance for more concurrent users.                                                                                                                                                                  |
| **8 GB** | 4,000 - 8,000+               | For high-traffic WooCommerce stores. Higher values may be necessary on dedicated servers with sufficient CPU resources. For enterprise, ensure you are within license limits.                                                                     |

### 1.2 `keepalive` (Persistent Connections)

Keep-alive settings allow clients to send multiple requests over a single TCP connection, reducing overhead.

#### `Keep-Alive Timeout`

Specifies how long an idle persistent connection remains open.

*   **Location (OpenLiteSpeed/LiteSpeed Enterprise):**
    *   WebAdmin Console: `Server Configuration > General > General > Keep-Alive Timeout`
*   **Recommended Value:** 2 - 5 seconds
    *   Too high: Wastes server resources, potential DDoS vulnerability.
    *   HTTP/2 connections are less affected by this, as they manage persistence differently.

#### `Max Keep-Alive Requests`

Limits the number of requests served over a single persistent connection.

*   **Location (OpenLiteSpeed/LiteSpeed Enterprise):**
    *   WebAdmin Console: `Server Configuration > General > General > Max Keep-Alive Requests`
*   **Recommended Value:** 100 - 150
    *   Helps manage server load by eventually closing long-lived connections.

#### Per-Client Throttling (Connection Throttling)

Limits the number of connections allowed from a single IP address to prevent abuse.

*   **Location (OpenLiteSpeed):**
    *   WebAdmin Console: `Configuration > Server > Security configurations > Per-Client Throttling`
*   **Recommended Settings:**
    *   **Keep-Alive Request Limit:** 10
    *   **Client Connection Timeout:** 30 seconds (default often sufficient)
    *   **Per IP Connection Throttling:** Enable
    *   **Static Connection Limit:** 4 - 10
    *   **Dynamic Connection Limit:** 4 - 10
    *   **Outbound Bandwidth:** `0` (unlimited, or set a value if needed)
    *   **Inbound Bandwidth:** `0` (unlimited, or set a value if needed)

### 1.3 `LSAPI children` (PHP Process Management)

This setting (often referred to as `PHP_LSAPI_CHILDREN` or `PHP suEXEC Max Conn`) controls the number of PHP child processes that LiteSpeed's LSAPI handler can spawn. Each child process consumes RAM, so careful tuning based on available memory is critical.

*   **Location (OpenLiteSpeed/LiteSpeed Enterprise):**
    *   **PHP Handler Defaults:** Via WebAdmin Console, navigate to `Server Configuration > External App > LSAPI App` (or similar for specific PHP versions). Under the "Environment" tab, add `PHP_LSAPI_CHILDREN=X`.
    *   **suEXEC Max Conn (for shared hosting/cPanel):** In some setups (especially with cPanel), this is managed via `Server Configuration > General > Using Apache Configuration File` for the `PHP suEXEC Max Conn` setting, which maps to `LSAPI_CHILDREN`.
*   **`LSAPI_AVOID_FORK` Environment Variable:**
    *   If `LSAPI_AVOID_FORK=0` (common in shared hosting), `LSAPI_CHILDREN` is effectively divided by 3, meaning you set `X` to three times the desired active children. This stops processes when they finish, conserving resources.
    *   If `LSAPI_AVOID_FORK=1`, `LSAPI_CHILDREN` uses the value directly.
    *   **Recommendation:** Check your specific setup. For automated optimization, understanding this distinction is vital. If not specified, `LSAPI_AVOID_FORK=0` is often the default for some distributions.
*   **Monitoring:** Regularly check the `WaitQ` value in the LiteSpeed WebAdmin Console (`Actions > Real-Time Stats > External Application`). A consistently high `WaitQ` indicates that `LSAPI children` may be too low, and requests are waiting for a PHP process to become available.

| RAM Tier | Usable RAM (approx.) | Recommended `LSAPI_CHILDREN` (assuming PHP worker ~120MB & `LSAPI_AVOID_FORK=1`) | Notes                                                                                                                                             |
| :------- | :------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1 GB** | ~500 MB              | 4 - 5                                                                                                                                             | Extremely limited. Server will likely swap under moderate load. This tier is not recommended for production WooCommerce.                               |
| **2 GB** | ~900 MB              | 7 - 8                                                                                                                                             | Minimal for a very small WooCommerce store. Prioritize lightweight themes/plugins. Performance highly susceptible to traffic spikes.                      |
| **4 GB** | ~3 GB                | 20 - 25                                                                                                                                           | Suitable for small to medium WooCommerce stores. Provides a good balance. Monitor `WaitQ` and adjust.                                                  |
| **8 GB** | ~7 GB                | 55 - 60                                                                                                                                           | Ideal for medium to large WooCommerce stores. Allows for significant concurrent PHP execution. Fine-tune based on actual memory usage.               |

**Important Considerations for `LSAPI children`:**
*   The `memory_limit` set in `php.ini` influences a PHP process's potential memory usage, but the actual resident memory (RSS) can be higher.
*   Always set the PHP `memory_limit` to at least `256M` or `512M` in `php.ini` for WooCommerce.
*   These are starting points. Monitor your server's RAM usage and CPU load to adjust these values up or down.

## 2. LSCache + WooCommerce: Advanced Configuration and Pitfalls

The LiteSpeed Cache for WordPress (LSCWP) plugin offers deep integration with WooCommerce, providing advanced caching mechanisms to enhance performance. However, careful configuration is required to leverage its full potential and avoid common pitfalls.

### 2.1 ESI (Edge Side Includes) for Dynamic Content

ESI is a powerful technique for caching dynamic blocks within otherwise static pages. This is particularly valuable for WooCommerce, where parts of a page (e.g., cart contents, user-specific greetings) need to remain dynamic while the rest can be served from cache.

*   **How it Works:** ESI "punches holes" in publicly cached pages, allowing specific sections to be fetched and assembled at the edge server (LiteSpeed Enterprise or QUIC.cloud) level, ensuring fresh, user-specific content.
*   **Benefits for WooCommerce:**
    *   **Mini-Cart:** ESI enables the mini-cart widget to display accurate cart counts and contents without breaking page caching. The mini-cart block is privately cached per session, reducing AJAX calls.
    *   **User-Specific Content:** Personalized greetings, "My Account" links, or "recently viewed products" can be dynamically inserted.
*   **Requirements:** ESI functionality requires a LiteSpeed Enterprise Web Server or a QUIC.cloud CDN subscription. OpenLiteSpeed does not natively support ESI.
*   **Configuration in LSCWP:**
    *   Navigate to `LiteSpeed Cache > Cache > ESI`.
    *   Enable ESI.
    *   You may need to define specific ESI blocks for custom dynamic elements if they are not automatically recognized by the plugin.
*   **Pitfall:** Intermittent login failures or nonce issues can occur on "My Account" pages if ESI interferes with dynamic nonce generation. Thorough testing after enabling ESI is crucial.

### 2.2 Private Cache and Exclusions

Managing private cache and exclusions correctly prevents sensitive user data from being publicly cached and ensures dynamic features work as expected.

*   **Automatic Exclusions by LSCWP:**
    *   By default, LSCWP intelligently excludes critical WooCommerce pages from public caching: `/cart/`, `/checkout/`, and `/my-account/`.
    *   The `woocommerce_items_in_cart` cookie automatically triggers a private cache variation, ensuring personalized cart contents are displayed for logged-in users or users with items in their cart.
*   **Manual Exclusions (`LiteSpeed Cache > Cache > Excludes`):**
    *   **Do Not Cache URIs:** Add any URLs that contain highly dynamic or user-specific information that LSCWP doesn't automatically exclude. This might include custom wishlist pages, comparison pages, or other unique endpoints.
        *   **Example:** `/wishlist`, `/compare`
    *   **Do Not Cache Cookies:** Use with extreme caution. Adding common WooCommerce cookies like `woocommerce_cart_hash` here can effectively disable caching for your entire site. Instead, leverage "Vary Cookie" for personalization.
*   **Vary Cookie:** This advanced setting (`LiteSpeed Cache > Cache > Advanced`) allows LiteSpeed to store different cached versions of a page based on the presence or value of a specific cookie. This is superior to simply excluding pages via cookies.

### 2.3 Crawler Warmup

The LSCache crawler pre-generates cached versions of pages by visiting them, ensuring that subsequent visitors receive a fast, cached response.

*   **LSCWP Built-in Crawler:**
    *   **Functionality:** LSCWP includes a built-in crawler that can warm up the cache based on your WordPress sitemap (`LiteSpeed Cache > General > Warm Up`).
    *   **Enabling:** Activate the "Crawler" and "Auto Crawler" options. Ensure your sitemap is correctly configured.
    *   **Limitations:** The built-in crawler can be resource-intensive and slow, especially for large stores. It might not effectively warm up all variations (e.g., pages with GET parameters, filtered results) or pages not listed in the sitemap.
*   **Third-Party Solutions:**
    *   Consider dedicated cache warmup services or plugins (e.g., Kitt, some QUIC.cloud features) that offer more advanced, faster, and less resource-intensive crawling, often with intelligent re-caching capabilities for WooCommerce (e.g., triggering re-caching of product pages when stock changes).

### 2.4 Cache-Poisoning Pitfalls and Security Considerations

Cache poisoning occurs when a malicious request causes a cache to store and serve incorrect or harmful content to other users. While LSCache is robust, misconfigurations or vulnerabilities can lead to issues.

*   **Incorrect Caching of Dynamic/Private Content:**
    *   **Pitfall:** If user-specific data, sensitive forms, or personalized elements are accidentally cached publicly (e.g., due to incorrect ESI setup or exclusion rules), it can expose private information to other users.
    *   **Mitigation:** Rigorously test all dynamic elements and ensure proper ESI configuration and exclusion rules are in place. Always verify that pages served from cache do not contain unintended user-specific data.
*   **Stale Nonces:**
    *   **Pitfall:** Nonces (numbers used once) are security tokens in WordPress. If pages with nonces are cached for too long, or ESI interacts poorly with them, it can lead to "invalid nonce" errors, particularly on forms or "My Account" pages.
    *   **Mitigation:** LSCWP handles nonces for most common scenarios. If issues arise, investigate `LiteSpeed Cache > Optimize > Nonce` options and consider reducing cache lifetimes for pages with critical forms.
*   **Security Vulnerabilities in the Plugin:**
    *   **Pitfall:** Like any software, LSCWP can have vulnerabilities. For example, a high-severity stored Cross-Site Scripting (XSS) vulnerability (CVE-2024-47374) was found.
    *   **Mitigation:** **Always keep the LiteSpeed Cache plugin, WordPress core, and all other plugins/themes updated to their latest versions.** This is the most crucial step to prevent exploitation of known vulnerabilities.
*   **Unintended Cache Variations:**
    *   **Pitfall:** If too many "Vary Cookies" or other variation settings are enabled without careful consideration, it can lead to an explosion of cached objects, consuming excessive disk space and CPU, and potentially negating caching benefits.
    *   **Mitigation:** Only create cache variations for truly necessary dynamic content. Monitor your cache size.

## 3. `lsphp` / OPcache Tuning

Optimizing PHP (specifically `lsphp`, LiteSpeed's SAPI for PHP) and OPcache is critical for reducing server load and improving the response time of your WordPress/WooCommerce site. OPcache stores pre-compiled PHP script bytecode in shared memory, eliminating the need for PHP to load and parse scripts on every request.

### 3.1 Enabling and Configuring OPcache

OPcache is a PHP extension that must be enabled and properly configured in your `php.ini` file.

*   **Locating `php.ini`:** The `php.ini` file for LiteSpeed's PHP is often located at a path similar to `/etc/php/X.x/litespeed/php.ini`, where `X.x` corresponds to your PHP version (e.g., `8.1`, `8.2`). You can confirm its location via `phpinfo()` or by running `php --ini` in the command line (if `lsphp` uses the same `php.ini`).

*   **Key `opcache` Directives in `php.ini`:**

    | Directive                          | Description                                                                                                                                                                                                                                                                       | Recommended Value (WooCommerce)                                                                                                                                                                                                           |
    | :--------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
    | `opcache.enable`                   | Enables or disables the OPcache extension.                                                                                                                                                                                                                                        | `1` (Enable)                                                                                                                                                                                                                              |
    | `opcache.memory_consumption`       | The size of the shared memory storage used by OPcache, in megabytes. For a complex WordPress/WooCommerce site with many plugins, the default 128MB is often insufficient.                                                                                                            | `192` to `384` (MB). Monitor `opcache_get_status()` output (e.g., via a PHP script or `opcache-gui`) to ensure you have enough free memory and are not hitting limits.                                                                      |
    | `opcache.max_accelerated_files`    | The maximum number of PHP scripts that can be cached. WordPress and WooCommerce, especially with themes and plugins, can easily exceed the default 10,000 files.                                                                                                                | `100000` or more. You can determine a suitable value by counting PHP files on your site: `find /path/to/your/wordpress -iname "*.php" | wc -l`. Set it slightly higher than this count.                                                                                                               |
    | `opcache.interned_strings_buffer`  | The amount of memory for storing interned (deduplicated) strings. This reduces memory usage and improves performance. The default 8MB is often too low for modern applications.                                                                                                   | `16` to `32` (MB)                                                                                                                                                                                                                         |
    | `opcache.validate_timestamps`      | If enabled, OPcache checks for updated scripts on disk. If disabled, scripts are never re-checked, requiring a manual cache clear after code changes.                                                                                                                       | `1` (Enable) for development/staging; `0` (Disable) for production on stable codebases (requires explicit OPcache reset after deployment).                                                                                                   |
    | `opcache.revalidate_freq`          | How often (in seconds) OPcache checks for script updates if `opcache.validate_timestamps` is `1`. A value of `0` means it checks on every request, which negates caching benefits.                                                                                              | `2` to `60` (seconds). For production, `60` is a common balance. For high-traffic, rapidly updated sites, `2` might be acceptable, or set to `0` and manage cache clearing via LSCWP or explicit commands after deployments.                      |
    | `opcache.enable_cli`               | Enables OPcache for PHP executed via the command line. Useful for `wp-cli` commands, cron jobs, etc., to benefit from cached bytecode.                                                                                                                                         | `1` (Enable). This can speed up `wp-cli` commands and other CLI-based WordPress tasks.                                                                                                                                                      |
    | `opcache.save_comments`            | If disabled, OPcache strips comments from code, reducing memory footprint. Some applications (e.g., Doctrine annotations) may rely on comments. | `1` (Enable) for broader compatibility, `0` (Disable) if you've confirmed no dependencies on comments and want to save memory.                                                                                                                |
    | `opcache.fast_shutdown`            | Allows for faster shutdown of PHP processes by not freeing memory, deferring it to process termination.                                                                                                                                                                     | `1` (Enable)                                                                                                                                                                                                                              |

*   **Applying Changes:** After modifying `php.ini`, you must restart your LiteSpeed web server (or the specific `lsphp` external application) for the changes to take effect.
    *   **OpenLiteSpeed:** Restart via WebAdmin Console or `sudo systemctl restart lsws`
    *   **LiteSpeed Enterprise:** Restart via WebAdmin Console or `sudo systemctl restart lsws` (or `httpd -k restart` if using Apache compatibility)

### 3.2 Monitoring OPcache

Regularly monitor your OPcache usage to ensure it's effectively caching files and not running out of memory or file slots.

*   **`opcache_get_status()`:** Create a simple PHP file (e.g., `opcache-status.php`) with `<?php var_dump(opcache_get_status(false)); ?>` and access it via your browser. This will show detailed statistics including memory usage, hit rate, and file counts.
*   **OPcache GUI Tools:** Tools like `opcache-gui` (available on GitHub) provide a more user-friendly interface to visualize OPcache statistics.

### 3.3 PHP Version

Always run the latest stable and supported PHP version (e.g., PHP 8.2 or newer). Each new PHP version brings significant performance improvements and bug fixes, directly impacting your WordPress/WooCommerce site's speed.

## 4. Automating LiteSpeed Cache Plugin Settings via `wp-cli` (`wp litespeed-option`)

The `wp litespeed-option` command-line utility for `wp-cli` allows for programmatic control over the LiteSpeed Cache plugin's settings. This is invaluable for automated deployment, configuration management, or scripting optimizations.

### 4.1 `wp litespeed-option` Basics

The general syntax for `wp litespeed-option` is:

```bash
wp litespeed-option <command> [options]
```

Common commands include:
*   `get`: Retrieve the value of a specific LSCache option.
*   `set`: Set the value of a specific LSCache option.
*   `list`: List all LSCache options and their current values.
*   `dump`: Output all LSCache options in a structured format (e.g., JSON).

### 4.2 Key LSCache Options for WooCommerce Optimization

Here are common LSCache settings that can be managed via `wp-cli`, along with their typical values for a WooCommerce site:

#### Cache Settings (`cache` category)

*   **`cache-enabled` (Enable LiteSpeed Cache):**
    *   **Command:** `wp litespeed-option set cache-enabled 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`cache-priv` (Cache Logged-in Users):** Essential for WooCommerce to cache personalized content for logged-in customers. Requires ESI or careful exclusion.
    *   **Command:** `wp litespeed-option set cache-priv 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`cache-comment` (Cache Commenters):** Caches pages for users who have commented.
    *   **Command:** `wp litespeed-option set cache-comment 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`cache-ttl` (Default Public Cache TTL):** Time-to-Live for public cache objects (seconds).
    *   **Command:** `wp litespeed-option set cache-ttl 604800` (7 days)
    *   **Value:** Integer (e.g., `604800` for 1 week)
*   **`cache-ttl-private` (Default Private Cache TTL):** Time-to-Live for private cache objects (seconds).
    *   **Command:** `wp litespeed-option set cache-ttl-private 1800` (30 minutes)
    *   **Value:** Integer
*   **`cache-mobile` (Cache Mobile):** Separates cache for mobile and desktop views.
    *   **Command:** `wp litespeed-option set cache-mobile 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`cache-uri-exclude` (Do Not Cache URIs):** A comma-separated list of URI patterns to exclude from caching. Crucial for WooCommerce for custom dynamic pages not automatically excluded.
    *   **Command:** `wp litespeed-option set cache-uri-exclude "/wishlist/,/compare/"`
    *   **Value:** String of comma-separated URI patterns.
*   **`cache-drop-qs` (Drop Query Strings):** Excludes specified query strings from being cached separately.
    *   **Command:** `wp litespeed-option set cache-drop-qs "utm_,gclid"`
    *   **Value:** String of comma-separated query string prefixes.

#### ESI Settings (`esi` category)

*   **`esi-enabled` (Enable ESI):**
    *   **Command:** `wp litespeed-option set esi-enabled 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`esi-nocache-cookies` (Do Not Cache Cookies for ESI):** For advanced use, specify cookies that should prevent ESI processing for a block.
    *   **Command:** `wp litespeed-option set esi-nocache-cookies "some_custom_cookie"`
    *   **Value:** String of comma-separated cookie names.

#### Object Cache Settings (`object` category)

*   **`object-cache-enabled` (Enable Object Cache):**
    *   **Command:** `wp litespeed-option set object-cache-enabled 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`object-cache-method` (Object Cache Method):** `Memcached` or `Redis`. Redis is generally preferred.
    *   **Command:** `wp litespeed-option set object-cache-method "redis"`
    *   **Value:** `"memcached"`, `"redis"`
*   **`object-cache-host` (Object Cache Host):** Hostname or IP of the object cache server.
    *   **Command:** `wp litespeed-option set object-cache-host "127.0.0.1"`
*   **`object-cache-port` (Object Cache Port):** Port of the object cache server.
    *   **Command:** `wp litespeed-option set object-cache-port 6379` (for Redis)
*   **`object-cache-persist` (Persistent Connection):**
    *   **Command:** `wp litespeed-option set object-cache-persist 1`
    *   **Value:** `1` (Enable), `0` (Disable)

#### Crawler Settings (`crawler` category)

*   **`crawler-enabled` (Enable Crawler):**
    *   **Command:** `wp litespeed-option set crawler-enabled 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`crawler-auto` (Auto Crawler):** Enables automatic sitemap crawling.
    *   **Command:** `wp litespeed-option set crawler-auto 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`crawler-map` (Build Cache Map):** Automatically builds the cache map from sitemaps.
    *   **Command:** `wp litespeed-option set crawler-map 1`
    *   **Value:** `1` (Enable), `0` (Disable)

#### Optimizations (CSS, JS, Image) (`optm` category)

*   **`optm-css-minify` (CSS Minify):**
    *   **Command:** `wp litespeed-option set optm-css-minify 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`optm-js-minify` (JS Minify):**
    *   **Command:** `wp litespeed-option set optm-js-minify 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`optm-img-optm-auto` (Image Optimization Auto Request):**
    *   **Command:** `wp litespeed-option set optm-img-optm-auto 1`
    *   **Value:** `1` (Enable), `0` (Disable)
*   **`optm-img-optm-webp` (Image Optimization WebP Replacement):**
    *   **Command:** `wp litespeed-option set optm-img-optm-webp 1`
    *   **Value:** `1` (Enable), `0` (Disable)

### 4.3 Clearing Cache via `wp-cli`

Beyond setting options, `wp-cli` can also be used to clear various caches.

*   **Clear All LSCache:**
    ```bash
    wp litespeed-purge all
    ```
*   **Clear Critical CSS:**
    ```bash
    wp litespeed-purge ccss
    ```
*   **Clear Opcode Cache (PHP OPcache):**
    ```bash
    wp litespeed-purge opcache
    ```
*   **Clear Object Cache:**
    ```bash
    wp litespeed-purge object
    ```
*   **Clear by URL:**
    ```bash
    wp litespeed-purge /product/example-product/
    ```
*   **Clear WooCommerce related caches:**
    ```bash
    wp litespeed-purge woocommerce
    ```
    This clears all LSCache for WooCommerce related pages, including products, shop, cart, checkout, and account pages.

### 4.4 Example Bash Script Snippet for Automation

A basic bash script for automating some LSCache settings might look like this:

```bash
#!/bin/bash

# Define WordPress installation path (adjust as necessary)
WP_PATH="/var/www/html/wordpress"

echo "Configuring LiteSpeed Cache settings via wp-cli..."

# Enable LiteSpeed Cache
wp litespeed-option set cache-enabled 1 --path=$WP_PATH

# Enable Cache for Logged-in Users
wp litespeed-option set cache-priv 1 --path=$WP_PATH

# Set public cache TTL to 1 week (604800 seconds)
wp litespeed-option set cache-ttl 604800 --path=$WP_PATH

# Set private cache TTL to 30 minutes (1800 seconds)
wp litespeed-option set cache-ttl-private 1800 --path=$WP_PATH

# Enable Object Cache with Redis
wp litespeed-option set object-cache-enabled 1 --path=$WP_PATH
wp litespeed-option set object-cache-method "redis" --path=$WP_PATH
wp litespeed-option set object-cache-host "127.0.0.1" --path=$WP_PATH
wp litespeed-option set object-cache-port 6379 --path=$WP_PATH
wp litespeed-option set object-cache-persist 1 --path=$WP_PATH

# Enable ESI
wp litespeed-option set esi-enabled 1 --path=$WP_PATH

# Configure Crawler
wp litespeed-option set crawler-enabled 1 --path=$WP_PATH
wp litespeed-option set crawler-auto 1 --path=$WP_PATH
wp litespeed-option set crawler-map 1 --path=$WP_PATH

# Exclude specific WooCommerce URIs from public cache (example)
wp litespeed-option set cache-uri-exclude "/wishlist/,/compare/" --path=$WP_PATH

# Clear all LSCache after configuration changes
echo "Clearing all LiteSpeed Cache..."
wp litespeed-purge all --path=$WP_PATH

echo "LiteSpeed Cache configuration complete."
```

---

# PART 2: Detailed Technical Research Report for Automated LiteSpeed/WooCommerce CLI Optimizer

This section of the report details LiteSpeed-specific security hardening, environment detection strategies for a bash CLI optimizer, and a prioritized list of LiteSpeed+WooCommerce optimizations.

## 5. LiteSpeed-Specific Security Hardening and Anti-DDoS Throttling

LiteSpeed Web Server (LSWS and OLS) offers robust built-in features to protect against DDoS attacks and enhance overall security.

### 5.1 Per-IP Connection and Request Throttling

LiteSpeed's "Per-Client Throttling" feature allows granular control over traffic from individual IP addresses, crucial for mitigating DoS/DDoS attacks. These settings are configurable via the LiteSpeed WebAdmin Console (`Configuration > Server > Security configurations > Per Client Throttling`) or directly in server configuration files.

**Key Directives and Functionality:**

*   **Connection Throttling:** Limits the number of concurrent connections from a single IP.
    *   `Connection Soft Limit`: Maximum concurrent connections. If exceeded, the IP enters a `Grace Period`.
    *   `Connection Hard Limit`: Absolute maximum concurrent connections. New connections from this IP are immediately closed if this is reached.
    *   `Grace Period (sec)`: Duration an IP can exceed the soft limit before being banned.
    *   `Banned Period (sec)`: Duration an IP is blocked after being identified as abusive.
*   **Request Throttling:** Limits the number of static and dynamic requests per second from a single IP. If the limit is reached, subsequent requests are "tar-pitted."
*   **Bandwidth Throttling:** Defines maximum inbound and outbound bandwidth (bytes/sec) for each IP. Setting to `0` disables it.

These settings can be applied globally at the server level and overridden for specific virtual hosts. Trusted IPs can be allow-listed to bypass throttling.

**Example `httpd_config.conf` (OLS) / `.conf` (LSWS) Directives:**

```
perClientConnLimit {
    connectionSoftLimit             20 # Max concurrent connections before grace period
    connectionHardLimit             50 # Absolute max concurrent connections
    gracePeriod                     60 # Seconds before banning if soft limit exceeded
    bannedPeriod                    3600 # Seconds IP is banned
    staticReqPerSec                 100 # Static requests per second
    dynamicReqPerSec                50  # Dynamic requests per second
    outboundBandwidth               0   # Outbound bandwidth limit (0 for unlimited)
    inboundBandwidth                0   # Inbound bandwidth limit (0 for unlimited)
}
```

### 5.2 reCAPTCHA Protection

LiteSpeed's server-level reCAPTCHA provides a powerful defense against automated threats by challenging suspicious traffic before it hits the application layer. This prevents server overload during attacks. It's a feature of the LiteSpeed Web Server, not the WordPress plugin.

**Configuration (WebAdmin Console: `Configuration > Server > Security > reCAPTCHA Protection`):**

*   **Enable reCAPTCHA:** `ON`/`OFF`.
*   **Site Key / Secret Key:** Obtained from Google reCAPTCHA v2.
*   **Trigger Sensitivity:** `0-100`. Higher values trigger reCAPTCHA more often.
*   **Max Tries:** Max reCAPTCHA attempts before an IP is blocked.
*   **Verification Expires:** How long a successful validation is valid.

**Apache-style Directives (in Virtual Host configuration or `.htaccess`):**

```apache
<IfModule LsRecaptcha.c>
    LsRecaptcha max_conn 10 # Triggers reCAPTCHA if concurrent connections exceed 10
</IfModule>
```
Setting `LsRecaptcha max_conn 1` will always enable reCAPTCHA for the specified context.

### 5.3 WordPress Brute-Force Protection

LiteSpeed Web Server (LSWS v5.2.3+) includes dedicated WordPress brute-force protection, operating independently or in conjunction with general reCAPTCHA.

**Features:**
*   **`captcha` or `full_captcha` modes:** Can enforce CAPTCHA on `wp-login.php`. `full_captcha` always displays it.
*   **Server-level blocking:** Protects the server from being overwhelmed.

**Mitigation and Troubleshooting:**
If an endless reCAPTCHA loop occurs (often due to Google reCAPTCHA Enterprise free quota exhaustion or caching issues), temporary solutions in `.htaccess` can be:

```apache
# Disable server-level WordPress brute-force protection
WordPressProtect off
# Bypass reCAPTCHA for specific requests if needed
RewriteRule .* - [E=verifycaptcha:off]
```
Ensure the LiteSpeed Cache plugin's crawler is not interfering and login pages are excluded from caching if conflicts arise.

### 5.4 ModSecurity Integration

LiteSpeed Web Server integrates with ModSecurity, acting as a Web Application Firewall (WAF) to filter malicious requests and protect against common web vulnerabilities (e.g., SQL injection, XSS). It supports popular rule sets like OWASP CRS, Comodo WAF, and Imunify360.

**Configuration:**

1.  **Prerequisites:** Ensure the ModSecurity module (`mod_security.so`) is present and enabled (e.g., in `/usr/local/lsws/modules/`).
2.  **WebAdmin Console (`Configuration > Server > Security > Web Application Firewall (WAF)`):**
    *   Enable ModSecurity.
    *   Add rule sets by specifying paths (e.g., `/usr/local/lsws/conf/comodo_litespeed/rules.conf`).
    *   Enable "Request Content Deep Inspection."
3.  **OpenLiteSpeed `httpd_config.conf`:**
    ```
    modsecurity on
    modsecurity_rules `
        # Include ModSecurity rules here or reference rule files
        # Example: SecRuleEngine On
        # Include /path/to/owasp-crs/owasp-crs.conf
    `
    ```
4.  **Control Panels:** ModSecurity rules are typically managed through the control panel's WAF interface (e.g., cPanel's ModSecurity Manager, DirectAdmin's ModSecurity setup).

**Important Considerations:**
*   **False Positives:** Add exceptions or whitelist rule IDs in the WebAdmin Console's "Rules Whitelist."
*   **Testing:** Thoroughly test after configuration (e.g., attempt SQL injection `?r=/etc/passwd` to expect a 403).
*   **`.htaccess` Overrides:** LiteSpeed handles ModSecurity rules in `.htaccess` differently; direct configuration or disabling `.htaccess` override for WAF might be needed.
*   **Logging:** LiteSpeed only supports Serial mode for ModSecurity audit logging.

## 6. Bash Script Detection for LiteSpeed Environments and Panels

An automated CLI optimizer needs to intelligently detect the LiteSpeed version (OLS vs. LSWS Enterprise) and the presence of control panels to apply configurations safely and correctly.

### 6.1 Detecting LiteSpeed Web Server Enterprise vs. OpenLiteSpeed

Key differences and detection methods:

*   **Binary Path:** Both typically use `$SERVER_ROOT/bin/lswsctrl` as the control script and `$SERVER_ROOT/bin/lshttpd` as the server executable.
*   **Main Configuration:**
    *   **OpenLiteSpeed:** Primarily uses `$SERVER_ROOT/conf/httpd_config.conf`.
    *   **LiteSpeed Enterprise:** Can use `$SERVER_ROOT/conf/httpd_config.conf` or integrate seamlessly with Apache's `httpd.conf` (e.g., `/usr/local/apache/conf/httpd.conf`, `/etc/httpd/conf/httpd.conf`).
*   **Differentiating Features for Detection:**
    1.  **License File:** LSWS Enterprise requires a commercial license. Check for `license.key` in `$SERVER_ROOT` or `$SERVER_ROOT/conf`.
    2.  **`.htaccess` Support:** LSWS Enterprise fully supports `.htaccess` without restarts. OLS requires restarts for `.htaccess` changes. This is harder to detect programmatically without advanced checks, but is a key differentiator in behavior.
    3.  **Specific Directives:** Enterprise-specific directives like `chrootPath` or full Apache configuration loading (`LoadApacheConfig`) might be present in the main config.
    4.  **Version String:** The output of `lshttpd -v` might contain "Enterprise" or "OpenLiteSpeed".

**Bash Detection Logic:**

```bash
LSWS_ROOT="/usr/local/lsws" # Common LiteSpeed installation root

if [ -f "${LSWS_ROOT}/bin/lshttpd" ]; then
    LSWS_VERSION=$("${LSWS_ROOT}/bin/lshttpd" -v)
    echo "LiteSpeed detected: ${LSWS_VERSION}"

    if echo "${LSWS_VERSION}" | grep -qi "Enterprise"; then
        echo "Detected: LiteSpeed Web Server Enterprise"
        LS_TYPE="Enterprise"
        # Check for license file
        if [ -f "${LSWS_ROOT}/license.key" ] || [ -f "${LSWS_ROOT}/conf/license.key" ]; then
            echo "License file found, confirming Enterprise."
        fi
        # Enterprise often uses httpd_config.xml internally for WebAdmin, or integrates httpd.conf
        CONFIG_FILE="${LSWS_ROOT}/conf/httpd_config.xml"
        if [ ! -f "${CONFIG_FILE}" ]; then
             CONFIG_FILE="${LSWS_ROOT}/conf/httpd_config.conf" # Fallback for non-panel setups or older versions
        fi
        # Check for common Apache config paths if LSWS is integrated with Apache
        if [ -f "/usr/local/apache/conf/httpd.conf" ]; then
            APACHE_CONFIG="/usr/local/apache/conf/httpd.conf"
        elif [ -f "/etc/httpd/conf/httpd.conf" ]; then
            APACHE_CONFIG="/etc/httpd/conf/httpd.conf"
        fi
        if [ -n "${APACHE_CONFIG}" ] && grep -q "LoadApacheConfig" "${CONFIG_FILE}"; then
            echo "LiteSpeed Enterprise integrated with Apache config: ${APACHE_CONFIG}"
        fi

    elif echo "${LSWS_VERSION}" | grep -qi "OpenLiteSpeed"; then
        echo "Detected: OpenLiteSpeed"
        LS_TYPE="OpenLiteSpeed"
        CONFIG_FILE="${LSWS_ROOT}/conf/httpd_config.conf"
    else
        echo "Could not determine exact LiteSpeed type."
        LS_TYPE="Unknown"
        CONFIG_FILE="${LSWS_ROOT}/conf/httpd_config.conf" # Default to OLS config path
    fi
else
    echo "LiteSpeed Web Server not found at ${LSWS_ROOT}"
    LS_TYPE="None"
fi
```

### 6.2 Detecting Panel Environments

Control panels standardize configurations. Detecting them is crucial for correct file paths and restart commands.

#### 6.2.1 CyberPanel Detection

CyberPanel inherently uses OpenLiteSpeed.

**Detection:**
*   Presence of CyberPanel's main configuration directory: `/usr/local/CyberCP/`
*   Checking for CyberPanel's version file: `/usr/local/CyberCP/version.txt`
*   Existence of the `lscpd` service.

**Bash Detection:**

```bash
if [ -d "/usr/local/CyberCP" ]; then
    echo "Detected: CyberPanel"
    PANEL_TYPE="CyberPanel"
    # CyberPanel uses OpenLiteSpeed
    LS_TYPE="OpenLiteSpeed"
    LSWS_ROOT="/usr/local/lsws" # CyberPanel's OLS installation
    CONFIG_FILE="${LSWS_ROOT}/conf/httpd_config.conf"
    # Virtual host configs in CyberPanel are usually managed via its GUI and stored per domain.
    # A common path for vhost includes might be within:
    # /home/<user>/conf/vhost.conf (or similar per domain)
    # or CyberPanel manages it directly in its backend database.
    # For general OLS config, the main httpd_config.conf is the target.
elif systemctl is-active --quiet lscpd || service lscpd status >/dev/null 2>&1; then
    echo "Detected: CyberPanel (via lscpd service)"
    PANEL_TYPE="CyberPanel"
    LS_TYPE="OpenLiteSpeed" # Assume OLS with lscpd
    LSWS_ROOT="/usr/local/lsws"
    CONFIG_FILE="${LSWS_ROOT}/conf/httpd_config.conf"
fi
```

#### 6.2.2 cPanel Detection

cPanel typically uses Apache, but LiteSpeed Enterprise can be integrated via the LiteSpeed WHM plugin.

**Detection:**
*   Presence of `/usr/local/cpanel/` directory.
*   Existence of cPanel's version file: `/usr/local/cpanel/version`.
*   Check for the LiteSpeed WHM plugin.

**Bash Detection:**

```bash
if [ -d "/usr/local/cpanel" ]; then
    echo "Detected: cPanel"
    PANEL_TYPE="cPanel"
    # Check for LiteSpeed WHM plugin to confirm LSWS presence
    if rpm -qa | grep -q "lsws-whm" || [ -f "/usr/local/cpanel/whostmgr/docroot/cgi/lsws/lsws_whm.php" ]; then
        echo "LiteSpeed Enterprise detected within cPanel."
        LS_TYPE="Enterprise"
        LSWS_ROOT="/usr/local/lsws" # Standard LSWS install for cPanel
        # LSWS in cPanel typically integrates with Apache's httpd.conf
        CONFIG_FILE="/etc/apache2/conf/httpd.conf" # Common cPanel Apache config
        if [ ! -f "${CONFIG_FILE}" ]; then # Fallback for other cPanel configs
            CONFIG_FILE="/usr/local/apache/conf/httpd.conf"
        fi
    else
        echo "cPanel detected, but LiteSpeed Web Server not explicitly found."
        LS_TYPE="None" # Apache typically
    fi
fi
```

#### 6.2.3 DirectAdmin Detection

DirectAdmin supports LiteSpeed Enterprise integration.

**Detection:**
*   Presence of `/usr/local/directadmin/` directory.
*   DirectAdmin's binary: `/usr/local/directadmin/directadmin`.

**Bash Detection:**

```bash
if [ -d "/usr/local/directadmin" ]; then
    echo "Detected: DirectAdmin"
    PANEL_TYPE="DirectAdmin"
    # Check for LSWS installation via DirectAdmin custombuild or services
    if systemctl is-active --quiet lsws || service lsws status >/dev/null 2>&1; then
        echo "LiteSpeed Web Server detected within DirectAdmin."
        LS_TYPE="Enterprise" # DirectAdmin typically uses LSWS Enterprise
        LSWS_ROOT="/usr/local/lsws"
        # DirectAdmin often manages Apache configs which LSWS Enterprise uses
        CONFIG_FILE="/etc/httpd/conf/httpd.conf" # Common DA Apache config
        if [ ! -f "${CONFIG_FILE}" ]; then # Fallback for other DA configs
            CONFIG_FILE="/usr/local/apache/conf/httpd.conf"
        fi
    else
        echo "DirectAdmin detected, but LiteSpeed Web Server not explicitly found."
        LS_TYPE="None"
    fi
fi
```

#### 6.2.4 Plain/No Panel Detection

If no control panel is detected, assume a standalone LiteSpeed installation.

```bash
if [ -z "${PANEL_TYPE}" ]; then # If PANEL_TYPE is still empty
    echo "Detected: Plain/No Control Panel"
    PANEL_TYPE="Plain"
    # LS_TYPE would have been set in 6.1 detection logic
fi
```

### 6.3 Binary Paths, Configuration Files, and Version Detection

#### 6.3.1 Common Paths

*   **LiteSpeed Server Root (LSWS_ROOT):**
    *   Most common: `/usr/local/lsws`
    *   Less common: `/opt/lsws`
*   **LiteSpeed Control Script:**
    *   `$LSWS_ROOT/bin/lswsctrl`
*   **LiteSpeed Server Executable:**
    *   `$LSWS_ROOT/bin/lshttpd`
*   **PHP SAPI (e.g., LSAPI):**
    *   `$LSWS_ROOT/lsphpX.X/bin/lsphp` (where X.X is the PHP version, e.g., `7.4`, `8.1`)
    *   `$LSWS_ROOT/lsphpX.X/etc/php.ini`

#### 6.3.2 Configuration Files

*   **OpenLiteSpeed:**
    *   Main config: `$LSWS_ROOT/conf/httpd_config.conf`
    *   Virtual Host templates/includes: `$LSWS_ROOT/conf/vhosts/*/vhost.conf`
*   **LiteSpeed Web Server Enterprise (Standalone):**
    *   Main config (can be Apache-like): `$LSWS_ROOT/conf/httpd_config.xml` (WebAdmin generated) or `$LSWS_ROOT/conf/httpd_config.conf` (manual config)
    *   Often integrates with Apache's configuration: `/etc/httpd/conf/httpd.conf`, `/usr/local/apache/conf/httpd.conf`
*   **Panel-Specific Configuration Paths:**
    *   **CyberPanel:** OLS configs are often managed through the panel. General config through `$LSWS_ROOT/conf/httpd_config.conf`. Vhost configs might be in `/home/<user>/conf/vhost.conf` for a domain.
    *   **cPanel/DirectAdmin:** LSWS Enterprise usually wraps the existing Apache configuration files, so modifications might target the Apache `httpd.conf` (`/etc/httpd/conf/httpd.conf` or `/usr/local/apache/conf/httpd.conf`) via the LSWS WHM/DA plugin.

#### 6.3.3 Version Detection Commands

*   **LiteSpeed Web Server (OLS/LSWS):**
    ```bash
    /usr/local/lsws/bin/lshttpd -v
    ```
*   **CyberPanel:**
    ```bash
    cat /usr/local/CyberCP/version.txt
    ```
*   **cPanel:**
    ```bash
    /usr/local/cpanel/cpanel -V
    cat /usr/local/cpanel/version
    ```
*   **DirectAdmin:**
    ```bash
    /usr/local/directadmin/directadmin v
    ```
*   **PHP Version (LiteSpeed SAPI):**
    ```bash
    /usr/local/lsws/lsphp81/bin/lsphp -v # Replace lsphp81 with your active version
    ```

### 6.4 Applying Config Changes and Safe Restarts

*   **Direct LiteSpeed (OLS/LSWS Standalone):**
    *   Edit the appropriate configuration file (`httpd_config.conf` for OLS, `httpd_config.xml` or integrated Apache configs for LSWS Enterprise).
    *   **Graceful Restart:** This applies changes without dropping active connections.
        ```bash
        sudo /usr/local/lsws/bin/lswsctrl restart
        ```
    *   **Reload (OLS):** For some changes, OLS might only require a reload.
        ```bash
        sudo /usr/local/lsws/bin/lswsctrl reload
        ```
    *   **Systemd/SysVinit:**
        ```bash
        sudo systemctl restart lsws # For systems using systemd
        sudo service lsws restart    # For systems using SysVinit
        ```
*   **CyberPanel:**
    *   Configuration changes are primarily made through the CyberPanel GUI. For manual edits to OLS `httpd_config.conf`, restart `lsws` service.
    *   **Restart LSWS:**
        ```bash
        sudo systemctl restart lsws
        # Or restart CyberPanel's control process:
        sudo systemctl restart lscpd
        ```
*   **cPanel:**
    *   LiteSpeed Enterprise changes are often applied via the LiteSpeed WHM plugin. For Apache config changes, cPanel's internal restart scripts should be used as they manage Apache and LSWS gracefully.
    *   **Restart Apache (and thus LSWS via plugin):**
        ```bash
        /usr/local/cpanel/scripts/restartsrv_httpd
        ```
*   **DirectAdmin:**
    *   Similar to cPanel, use DirectAdmin's mechanisms for service control.
    *   **Restart LiteSpeed:**
        ```bash
        sudo systemctl restart lsws
        # Or DirectAdmin's custombuild might have a way to restart services
        /usr/local/directadmin/custombuild/build rewrite_confs # Might trigger LSWS reload/restart after config changes
        ```

**General Principle:** When working with control panels, prefer their provided utilities or service management commands (`systemctl`, `service`) to ensure changes are applied within the panel's ecosystem and do not cause conflicts. Always perform a graceful restart if possible.

## 7. Top-10 LiteSpeed + WooCommerce Optimizations (Ranked by Impact)

Optimizing a LiteSpeed server for WooCommerce involves leveraging LiteSpeed's advanced caching and performance features, combined with WordPress/WooCommerce best practices. Here's a ranked list by expected impact:

### 7.1 ESI (Edge Side Includes) for Dynamic Content (Highest Impact for WooCommerce)

**Impact:** Dramatically improves caching for WooCommerce, allowing public caching of entire pages while dynamically inserting personalized content (e.g., cart widgets, user login status). Reduces TTFB and server load significantly for logged-in users and dynamic areas.
**Description:** ESI allows "hole-punching" – marking dynamic blocks within an otherwise static page. LiteSpeed processes these blocks separately, enabling full-page caching even on pages with personalized elements. Essential for WooCommerce cart, checkout, and account pages.
**Config Directives/Commands:**
*   **Enable ESI:** In LiteSpeed Cache plugin settings: `LiteSpeed Cache > Cache > ESI > Enable ESI: ON`.
*   **Mark ESI Blocks:** Use shortcodes or hooks in your theme/plugins for dynamic content that should be fetched via ESI (e.g., `<!--esi ... -->` comments, or the LSCache plugin's ESI shortcodes).
*   **WooCommerce-specific ESI:** The LSCache plugin automatically detects and handles many WooCommerce dynamic elements (cart, currency, account status).

### 7.2 Object Cache (Redis/Memcached) for Database Queries

**Impact:** Substantially reduces database query load and improves backend response times for dynamic WordPress/WooCommerce operations, especially on high-traffic sites. Improves TTFB.
**Description:** Caches database query results, user sessions, and transients in memory (Redis or Memcached), preventing repeated database calls. Critical for WooCommerce's numerous database interactions.
**Config Directives/Commands:**
*   **Install Redis/Memcached:** `sudo apt install redis-server php-redis` (for Ubuntu/Debian with Redis).
*   **Enable Object Cache:** In LiteSpeed Cache plugin settings: `LiteSpeed Cache > Cache > Object > Object Cache: ON`.
*   **Method:** Select `Redis` or `Memcached`.
*   **Host/Port:** Configure according to your Redis/Memcached setup (e.g., `127.0.0.1:6379`).

### 7.3 Full Page Caching

**Impact:** Drastically reduces TTFB and server load for anonymous users. Pages load almost instantly.
**Description:** Stores a static HTML version of a page after the first visit, serving it directly from the cache for subsequent requests. LiteSpeed Cache handles cache invalidation intelligently for WooCommerce.
**Config Directives/Commands:**
*   **Enable Cache:** In LiteSpeed Cache plugin settings: `LiteSpeed Cache > Cache > Enable Cache: ON`.
*   **Cache Logged-in Users:** `LiteSpeed Cache > Cache > Cache Logged-in Users: ON` (use with ESI for best results).
*   **Cache REST API:** `LiteSpeed Cache > Cache > Cache REST API: ON` (benefits headless setups/mobile apps).
*   **Crawler:** `LiteSpeed Cache > Crawler > Crawler: ON` to pre-warm cache. Configure interval and thread count.

### 7.4 Image Optimization (WebP Conversion, Lazy Load)

**Impact:** Reduces page weight significantly, leading to faster visual loading (Largest Contentful Paint - LCP) and lower bandwidth consumption.
**Description:** Converts images to modern formats like WebP (smaller file sizes with similar quality) and defers loading of off-screen images until they are needed (lazy loading).
**Config Directives/Commands:**
*   **Image Optimization:** In LiteSpeed Cache plugin settings: `LiteSpeed Cache > Image Optimization > Image Optimization Summary > Gather Image Data / Optimize Images`.
*   **WebP Conversion:** `LiteSpeed Cache > Image Optimization > WebP Conversion: ON`.
*   **Lazy Load Images:** `LiteSpeed Cache > Page Optimization > Media Settings > Lazy Load Images: ON`.

### 7.5 Minify/Combine CSS & JavaScript

**Impact:** Reduces HTTP requests and file sizes, improving initial load times and render-blocking issues.
**Description:** Removes unnecessary characters from CSS/JS files (minification) and merges multiple files into one (combination) to reduce the number of network requests.
**Config Directives/Commands:**
*   **Minify CSS:** `LiteSpeed Cache > Page Optimization > CSS Settings > CSS Minify: ON`.
*   **Combine CSS:** `LiteSpeed Cache > Page Optimization > CSS Settings > CSS Combine: ON`.
*   **Minify JS:** `LiteSpeed Cache > Page Optimization > JS Settings > JS Minify: ON`.
*   **Combine JS:** `LiteSpeed Cache > Page Optimization > JS Settings > JS Combine: ON`.
*   **JS Deferred Load:** `LiteSpeed Cache > Page Optimization > JS Settings > JS Deferred Load: ON` (can further improve render-blocking).

### 7.6 CDN Integration

**Impact:** Reduces latency by serving static assets from edge servers geographically closer to users. Improves global load times and offloads server resources.
**Description:** Integrates a Content Delivery Network (CDN) like QUIC.cloud CDN (native with LiteSpeed) or Cloudflare to distribute static content (images, CSS, JS) globally.
**Config Directives/Commands:**
*   **QUIC.cloud CDN:** `LiteSpeed Cache > CDN > QUIC.cloud CDN > Link to QUIC.cloud`.
*   **General CDN:** `LiteSpeed Cache > CDN > CDN Mapping > CDN URL`.

### 7.7 Browser Cache Policy

**Impact:** Speeds up repeat visits by instructing browsers to store static assets locally, avoiding repeated downloads.
**Description:** Configures HTTP headers (`Cache-Control`, `Expires`) to tell browsers how long to cache specific file types.
**Config Directives/Commands:**
*   **LiteSpeed Cache handles this for cached content.**
*   **Manual `.htaccess` (or LiteSpeed equivalent in `vhost.conf`/`httpd_config.conf`):**
    ```apache
    <IfModule LiteSpeed>
        <IfModule mod_expires.c>
            ExpiresActive On
            ExpiresByType image/jpg "access plus 1 year"
            ExpiresByType image/jpeg "access plus 1 year"
            ExpiresByType image/gif "access plus 1 year"
            ExpiresByType image/png "access plus 1 year"
            ExpiresByType image/webp "access plus 1 year"
            ExpiresByType text/css "access plus 1 month"
            ExpiresByType application/javascript "access plus 1 month"
        </IfModule>
    </IfModule>
    ```

### 7.8 GZIP/Brotli Compression

**Impact:** Reduces the size of transmitted data over the network, leading to faster download times for HTML, CSS, and JS.
**Description:** Compresses content before sending it to the browser. Brotli is newer and often more efficient than GZIP. LiteSpeed supports both.
**Config Directives/Commands:**
*   **Enable in LiteSpeed WebAdmin Console:** `Configuration > Server > Tuning > Enable GZIP Compression: ON`.
*   **Enable Brotli:** If available, ensure Brotli is enabled at the server level.
*   **LiteSpeed Cache plugin:** `LiteSpeed Cache > Page Optimization > Optimization Settings > HTML Minify: ON` (can indirectly improve compression efficiency).

### 7.9 Database Optimization

**Impact:** Improves overall site responsiveness and backend performance by ensuring database efficiency.
**Description:** Regularly cleans up database tables (e.g., post revisions, spam comments, transients), removes overhead, and optimizes table structures.
**Config Directives/Commands:**
*   **Database Optimizer:** In LiteSpeed Cache plugin settings: `LiteSpeed Cache > Database > Clean All` (careful with backups!).
*   **Schedule Optimization:** `LiteSpeed Cache > Database > Optimization Settings > Scheduled Clean: ON`.

### 7.10 PHP Version and Configuration (LSAPI)

**Impact:** Newer PHP versions offer significant performance improvements. Optimizing PHP settings (memory, execution time) ensures smooth operation.
**Description:** Running a modern PHP version (e.g., PHP 8.x) with LiteSpeed's highly optimized LSAPI (LiteSpeed SAPI) handler offers superior performance compared to FPM or other handlers.
**Config Directives/Commands:**
*   **Update PHP:** Ensure the server runs a modern PHP version (e.g., PHP 8.1 or higher).
*   **LiteSpeed WebAdmin Console:** `Configuration > Server > External App > PHP`. Ensure PHP is configured as `LiteSpeed SAPI`.
*   **`php.ini` tuning:** Edit `$LSWS_ROOT/lsphpX.X/etc/php.ini` (or the PHP config for your panel).
    *   `memory_limit = 256M` (or higher for WooCommerce)
    *   `max_execution_time = 300` (or higher if needed for imports/exports)
    *   `upload_max_filesize` and `post_max_size` (for media uploads)
*   **Restart PHP process:** After `php.ini` changes, restart the relevant LSAPI external application or the LiteSpeed server.
