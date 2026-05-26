<?php

declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

set_cors_headers();

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    send_json(['ok' => false, 'message' => 'Method not allowed.'], 405);
}

$settings = $config['internal_products'] ?? [];
$endpoint = trim((string)($settings['endpoint'] ?? ''));
$apiKey = trim((string)($settings['api_key'] ?? ''));

if ($endpoint === '' || $apiKey === '') {
    send_json([
        'ok' => false,
        'message' => 'Internal products API is not configured on the server.',
    ], 500);
}

$page = max(1, (int)($_GET['page'] ?? 1));
$limit = max(1, min(500, (int)($_GET['limit'] ?? 500)));

$query = [
    'page' => $page,
    'limit' => $limit,
];

if (isset($_GET['search']) && trim((string)$_GET['search']) !== '') {
    $query['search'] = trim((string)$_GET['search']);
}

if (isset($_GET['category']) && trim((string)$_GET['category']) !== '') {
    $query['category'] = trim((string)$_GET['category']);
}

$url = $endpoint . (str_contains($endpoint, '?') ? '&' : '?') . http_build_query($query);

$headers = [
    'Accept: application/json',
    'x-api-key: ' . $apiKey,
];

try {
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_TIMEOUT => 20,
        ]);

        $body = curl_exec($ch);
        $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error = curl_error($ch);
        curl_close($ch);

        if ($body === false) {
            send_json(['ok' => false, 'message' => 'Product API request failed.', 'error' => $error], 502);
        }
    } else {
        $context = stream_context_create([
            'http' => [
                'method' => 'GET',
                'header' => implode("\r\n", $headers),
                'timeout' => 20,
                'ignore_errors' => true,
            ],
        ]);
        $body = file_get_contents($url, false, $context);
        $status = 200;

        if (isset($http_response_header[0]) && preg_match('/\s(\d{3})\s/', $http_response_header[0], $matches)) {
            $status = (int)$matches[1];
        }

        if ($body === false) {
            send_json(['ok' => false, 'message' => 'Product API request failed.'], 502);
        }
    }
} catch (Throwable $e) {
    send_json([
        'ok' => false,
        'message' => 'Product API request failed.',
        'error' => $e->getMessage(),
    ], 502);
}

$decoded = json_decode((string)$body, true);
if (!is_array($decoded)) {
    send_json(['ok' => false, 'message' => 'Product API returned invalid JSON.'], 502);
}

send_json($decoded, $status >= 200 && $status < 600 ? $status : 502);
