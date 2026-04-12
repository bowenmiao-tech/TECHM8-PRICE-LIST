<?php

declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

set_cors_headers();

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    send_json(['ok' => false, 'message' => 'Method not allowed.'], 405);
}

$pdo = db();
$stmt = $pdo->query('
    SELECT a_number, family_key, model_name, linked_price_list_model
    FROM apple_model_map
    ORDER BY family_key, a_number
');

$rows = $stmt->fetchAll();
$result = [];

foreach ($rows as $row) {
    $familyKey = $row['family_key'];
    if (!isset($result[$familyKey])) {
        $result[$familyKey] = [];
    }
    $result[$familyKey][$row['a_number']] = $row['model_name'];
}

send_json($result);
