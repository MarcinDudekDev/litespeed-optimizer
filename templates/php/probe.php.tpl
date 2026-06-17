<?php
/**
 * litespeed-optimizer — token-guarded one-shot web-SAPI probe.
 *
 * Drop in the DOCROOT (NOT wp-content — .htaccess Denies PHP there on LiteSpeed
 * sites), fetch over HTTP with the token, self-deletes. Bare PHP, no wp-load:
 * extension_loaded() reflects the ACTUAL web SAPI that serves the site, which is
 * the whole point — CLI php / wp-cli can differ from the lsphp the vhost runs.
 *
 * Probe mechanism contributed by the agrido project (token guard + LSCache-bust
 * + self-delete, validated on Zenbox/LiteSpeed 2026-06-17). {{TOKEN}},
 * {{REDIS_HOST}}, {{REDIS_PORT}} are substituted by the driver before upload.
 */
$TOKEN = '{{TOKEN}}';
if (!isset($_GET['t']) || !hash_equals($TOKEN, (string) $_GET['t'])) {
    http_response_code(404);
    exit;
}
// Guarantee CLEAN JSON regardless of the host's php.ini: a box with
// display_errors on (or a host auto_prepend_file) would otherwise prepend a
// notice/warning before the body, making the response non-JSON and tripping the
// driver's "starts with {" guard even though valid JSON follows. (agrido review)
error_reporting(0);
ini_set('display_errors', '0');
// CRITICAL: stop LiteSpeed/LSCache caching the probe (else a 2nd fetch = stale HIT).
header('X-LiteSpeed-Cache-Control: no-cache');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Content-Type: application/json');

$out = array(
    'php_version'  => PHP_VERSION,
    'sapi'         => PHP_SAPI,
    'redis_ext'    => extension_loaded('redis') ? (phpversion('redis') ?: '1') : false,
    'igbinary'     => extension_loaded('igbinary'),
    'redis_server' => null,
);

// Prove the Redis SERVER (not just the ext) is reachable from the web SAPI.
if (extension_loaded('redis')) {
    try {
        $r = new Redis();
        $out['redis_server'] = $r->connect('{{REDIS_HOST}}', (int) '{{REDIS_PORT}}', 1.0) ? 'up' : 'down';
        $r->close();
    } catch (Throwable $e) {
        // Strip , { } so the driver's [^,}] JSON capture can't truncate mid-value.
        $out['redis_server'] = 'err:' . str_replace(array(',', '{', '}'), ' ', substr($e->getMessage(), 0, 40));
    }
}

echo json_encode($out, JSON_UNESCAPED_SLASHES);

// One-shot: remove self so it never lingers (driver backstop-rm covers perms edges).
@unlink(__FILE__);
