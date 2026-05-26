<?php

return [
    'db' => [
        'host' => '127.0.0.1',
        'port' => 3306,
        'name' => 'techm8',
        'user' => 'root',
        'pass' => '',
        'charset' => 'utf8mb4',
    ],
    'cors_origin' => '*',
    'setup_token' => 'change-this-before-using-setup',
    'internal_products' => [
        'endpoint' => getenv('INTERNAL_PRODUCTS_ENDPOINT') ?: 'https://fwlronvmgqzkleofriis.supabase.co/functions/v1/internal-products',
        'api_key' => getenv('INTERNAL_PRODUCTS_API_KEY') ?: '',
    ],
];
