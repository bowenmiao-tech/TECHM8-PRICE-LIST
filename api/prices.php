<?php

declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

set_cors_headers();

$pdo = db();

if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    $stmt = $pdo->query('
        SELECT brand, model, issue, price, turnaround_time AS time
        FROM repair_prices
        ORDER BY brand, model, issue
    ');

    send_json($stmt->fetchAll());
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    send_json(['ok' => false, 'message' => 'Method not allowed.'], 405);
}

$body = get_json_body();
$rows = $body['rows'] ?? null;

if (!is_array($rows)) {
    send_json(['ok' => false, 'message' => 'rows must be an array.'], 400);
}

$cleaned = [];
foreach ($rows as $row) {
    if (!is_array($row)) {
        continue;
    }

    $normalized = normalize_price_row($row);
    if ($normalized['brand'] === '' || $normalized['model'] === '' || $normalized['issue'] === '') {
        send_json(['ok' => false, 'message' => 'brand, model, and issue are required for every row.'], 422);
    }
    $cleaned[] = $normalized;
}

$pdo->beginTransaction();

try {
    if (!empty($body['replace_all'])) {
        $pdo->exec('DELETE FROM repair_prices');
    }

    $stmt = $pdo->prepare('
        INSERT INTO repair_prices (brand, model, issue, price, turnaround_time)
        VALUES (:brand, :model, :issue, :price, :time)
        ON DUPLICATE KEY UPDATE
            price = VALUES(price),
            turnaround_time = VALUES(turnaround_time),
            updated_at = CURRENT_TIMESTAMP
    ');

    foreach ($cleaned as $row) {
        $stmt->execute($row);
    }

    $pdo->commit();
} catch (Throwable $e) {
    $pdo->rollBack();
    send_json([
        'ok' => false,
        'message' => 'Failed to save price rows.',
        'error' => $e->getMessage(),
    ], 500);
}

send_json([
    'ok' => true,
    'message' => 'Prices saved successfully.',
    'saved' => count($cleaned),
]);
