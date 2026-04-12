<?php

declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

set_cors_headers();

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    send_json(['ok' => false, 'message' => 'Method not allowed.'], 405);
}

$body = get_json_body();
$token = trim((string)($body['token'] ?? ''));

global $config;
if ($token === '' || $token !== ($config['setup_token'] ?? '')) {
    send_json(['ok' => false, 'message' => 'Invalid setup token.'], 403);
}

$priceJsonPath = dirname(__DIR__) . '/data.json';
$appleMapPath = dirname(__DIR__) . '/apple_a_model_map.json';

if (!is_file($priceJsonPath) || !is_file($appleMapPath)) {
    send_json(['ok' => false, 'message' => 'Required JSON source files are missing.'], 500);
}

$priceRows = json_decode((string)file_get_contents($priceJsonPath), true);
$appleMap = json_decode((string)file_get_contents($appleMapPath), true);

if (!is_array($priceRows) || !is_array($appleMap)) {
    send_json(['ok' => false, 'message' => 'Source JSON files are invalid.'], 500);
}

$pdo = db();
$pdo->beginTransaction();

try {
    $pdo->exec('DELETE FROM repair_prices');
    $priceStmt = $pdo->prepare('
        INSERT INTO repair_prices (brand, model, issue, price, turnaround_time)
        VALUES (:brand, :model, :issue, :price, :time)
    ');

    foreach ($priceRows as $row) {
        if (!is_array($row)) {
            continue;
        }
        $normalized = normalize_price_row($row);
        if ($normalized['brand'] === '' || $normalized['model'] === '' || $normalized['issue'] === '') {
            continue;
        }
        $priceStmt->execute($normalized);
    }

    $pdo->exec('DELETE FROM apple_model_map');
    $appleStmt = $pdo->prepare('
        INSERT INTO apple_model_map (a_number, family_key, model_name, linked_price_list_model)
        VALUES (:a_number, :family_key, :model_name, :linked_price_list_model)
    ');

    foreach (['iphone', 'ipad'] as $familyKey) {
        foreach (($appleMap[$familyKey] ?? []) as $aNumber => $modelName) {
            $appleStmt->execute([
                'a_number' => $aNumber,
                'family_key' => $familyKey,
                'model_name' => $modelName,
                'linked_price_list_model' => null,
            ]);
        }
    }

    foreach (($appleMap['mac'] ?? []) as $familyKey => $familyRows) {
        if ($familyKey === 'normalization_notes' || !is_array($familyRows)) {
            continue;
        }
        foreach ($familyRows as $aNumber => $modelName) {
            $appleStmt->execute([
                'a_number' => $aNumber,
                'family_key' => $familyKey,
                'model_name' => $modelName,
                'linked_price_list_model' => null,
            ]);
        }
    }

    $pdo->commit();
} catch (Throwable $e) {
    $pdo->rollBack();
    send_json([
        'ok' => false,
        'message' => 'Seeding failed.',
        'error' => $e->getMessage(),
    ], 500);
}

send_json([
    'ok' => true,
    'message' => 'Database seeded from local JSON files.',
]);
