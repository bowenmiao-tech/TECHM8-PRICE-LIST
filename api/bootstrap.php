<?php

declare(strict_types=1);

$config = require __DIR__ . '/config.php';

function send_json($data, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function send_text(string $text, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: text/plain; charset=utf-8');
    echo $text;
    exit;
}

function get_json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || $raw === '') {
      return [];
    }

    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        send_json(['ok' => false, 'message' => 'Invalid JSON body.'], 400);
    }

    return $decoded;
}

function db(): PDO
{
    static $pdo = null;

    if ($pdo instanceof PDO) {
        return $pdo;
    }

    global $config;

    $db = $config['db'];
    $dsn = sprintf(
        'mysql:host=%s;port=%d;dbname=%s;charset=%s',
        $db['host'],
        $db['port'],
        $db['name'],
        $db['charset']
    );

    try {
        $pdo = new PDO($dsn, $db['user'], $db['pass'], [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
    } catch (Throwable $e) {
        send_json([
            'ok' => false,
            'message' => 'Database connection failed.',
            'error' => $e->getMessage(),
        ], 500);
    }

    return $pdo;
}

function normalize_price_row(array $row): array
{
    return [
        'brand' => trim((string)($row['brand'] ?? '')),
        'model' => trim((string)($row['model'] ?? '')),
        'issue' => trim((string)($row['issue'] ?? '')),
        'price' => trim((string)($row['price'] ?? '')),
        'time' => trim((string)($row['time'] ?? '')),
    ];
}

function set_cors_headers(): void
{
    global $config;

    header('Access-Control-Allow-Origin: ' . ($config['cors_origin'] ?? '*'));
    header('Access-Control-Allow-Headers: Content-Type');
    header('Access-Control-Allow-Methods: GET, POST, OPTIONS');

    if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
        http_response_code(204);
        exit;
    }
}
