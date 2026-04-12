<?php

declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

set_cors_headers();

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    send_json(['ok' => false, 'message' => 'Method not allowed.'], 405);
}

$body = get_json_body();

$customerName = trim((string)($body['customerName'] ?? ''));
$customerPhone = trim((string)($body['customerPhone'] ?? ''));
$customerEmail = trim((string)($body['customerEmail'] ?? ''));

if ($customerName === '') {
    send_json(['ok' => false, 'message' => 'Customer name is required.'], 422);
}

if ($customerPhone === '' && $customerEmail === '') {
    send_json(['ok' => false, 'message' => 'Phone or email is required.'], 422);
}

$pdo = db();

$stmt = $pdo->prepare('
    INSERT INTO repair_intakes (
        source_type,
        customer_name,
        customer_phone,
        customer_email,
        contact_method,
        device_type,
        device_model,
        quoted_price,
        repair_issue,
        estimated_time,
        password_type,
        password_text,
        pattern_value,
        password_none_reason,
        device_id_type,
        device_id_imei,
        device_id_sn,
        device_id_unavailable_reason,
        testable,
        test_profile,
        cannot_test_reason,
        test_notes,
        test_results_json,
        quote_data_json,
        intake_json
    ) VALUES (
        :source_type,
        :customer_name,
        :customer_phone,
        :customer_email,
        :contact_method,
        :device_type,
        :device_model,
        :quoted_price,
        :repair_issue,
        :estimated_time,
        :password_type,
        :password_text,
        :pattern_value,
        :password_none_reason,
        :device_id_type,
        :device_id_imei,
        :device_id_sn,
        :device_id_unavailable_reason,
        :testable,
        :test_profile,
        :cannot_test_reason,
        :test_notes,
        :test_results_json,
        :quote_data_json,
        :intake_json
    )
');

try {
    $stmt->execute([
        'source_type' => trim((string)($body['sourceType'] ?? 'quote')),
        'customer_name' => $customerName,
        'customer_phone' => $customerPhone,
        'customer_email' => $customerEmail,
        'contact_method' => trim((string)($body['contactMethod'] ?? 'Phone')),
        'device_type' => trim((string)($body['deviceType'] ?? '')),
        'device_model' => trim((string)($body['deviceModel'] ?? '')),
        'quoted_price' => trim((string)($body['quotedPrice'] ?? '')),
        'repair_issue' => trim((string)($body['quoteIssue'] ?? '')),
        'estimated_time' => trim((string)($body['estimatedTime'] ?? '')),
        'password_type' => trim((string)($body['passwordType'] ?? 'text')),
        'password_text' => trim((string)($body['passwordText'] ?? '')),
        'pattern_value' => trim((string)($body['patternValue'] ?? '')),
        'password_none_reason' => trim((string)($body['passwordNoneReason'] ?? '')),
        'device_id_type' => trim((string)($body['deviceIdType'] ?? 'imei')),
        'device_id_imei' => trim((string)($body['deviceIdImei'] ?? '')),
        'device_id_sn' => trim((string)($body['deviceIdSn'] ?? '')),
        'device_id_unavailable_reason' => trim((string)($body['deviceIdNoneReason'] ?? '')),
        'testable' => trim((string)($body['testable'] ?? 'yes')),
        'test_profile' => trim((string)($body['testProfile'] ?? 'mobile')),
        'cannot_test_reason' => trim((string)($body['cannotTestReason'] ?? '')),
        'test_notes' => trim((string)($body['testNotes'] ?? '')),
        'test_results_json' => json_encode($body['testResults'] ?? [], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        'quote_data_json' => json_encode($body['quoteData'] ?? [], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        'intake_json' => json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
    ]);
} catch (Throwable $e) {
    send_json([
        'ok' => false,
        'message' => 'Failed to save intake.',
        'error' => $e->getMessage(),
    ], 500);
}

send_json([
    'ok' => true,
    'message' => 'Repair intake saved.',
    'id' => (int)$pdo->lastInsertId(),
]);
