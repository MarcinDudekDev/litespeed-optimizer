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
    'opcache'      => null,
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

// Runtime OPcache stats — web-SAPI-only (CLI has opcache.enable_cli=0), so this
// is the only honest way to read hit-rate / pool-fill / interned / key-table.
// opcache_get_status(false) skips the (huge) per-script array. (agrido harness)
if (function_exists('opcache_get_status')) {
    $s = @opcache_get_status(false);
    $c = @opcache_get_configuration();
    if (is_array($s)) {
        $mem    = isset($s['memory_usage']) ? $s['memory_usage'] : array();
        $stat   = isset($s['opcache_statistics']) ? $s['opcache_statistics'] : array();
        $intern = isset($s['interned_strings_usage']) ? $s['interned_strings_usage'] : array();
        $dir    = isset($c['directives']) ? $c['directives'] : array();
        $out['opcache'] = array(
            'enabled'            => !empty($s['opcache_enabled']),
            'mem_total'          => isset($dir['opcache.memory_consumption']) ? $dir['opcache.memory_consumption'] : null,
            'mem_used'           => isset($mem['used_memory']) ? $mem['used_memory'] : null,
            'mem_free'           => isset($mem['free_memory']) ? $mem['free_memory'] : null,
            'mem_wasted'         => isset($mem['wasted_memory']) ? $mem['wasted_memory'] : null,
            'hit_rate'           => isset($stat['opcache_hit_rate']) ? round($stat['opcache_hit_rate'], 1) : null,
            'num_cached_keys'    => isset($stat['num_cached_keys']) ? $stat['num_cached_keys'] : null,
            'max_cached_keys'    => isset($stat['max_cached_keys']) ? $stat['max_cached_keys'] : null,
            'num_cached_scripts' => isset($stat['num_cached_scripts']) ? $stat['num_cached_scripts'] : null,
            'oom_restarts'       => isset($stat['oom_restarts']) ? $stat['oom_restarts'] : null,
            'interned_used'      => isset($intern['used_memory']) ? $intern['used_memory'] : null,
            'interned_free'      => isset($intern['free_memory']) ? $intern['free_memory'] : null,
            'interned_buffer'    => isset($intern['buffer_size']) ? $intern['buffer_size'] : null,
        );
    }
}

echo json_encode($out, JSON_UNESCAPED_SLASHES);

// One-shot: remove self so it never lingers (driver backstop-rm covers perms edges).
@unlink(__FILE__);
