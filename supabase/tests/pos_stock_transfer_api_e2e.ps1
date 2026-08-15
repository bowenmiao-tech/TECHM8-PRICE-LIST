param(
  [Parameter(Mandatory = $true)][string]$SessionToken,
  [Parameter(Mandatory = $true)][string]$AnonKey,
  [Parameter(Mandatory = $true)][string]$PhotoPath,
  [int]$ProductId = 1,
  [string]$StaffName = 'Bowen'
)

$ErrorActionPreference = 'Stop'
$endpoint = 'https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-stock-transfers'
$headers = @{
  apikey = $AnonKey
  Authorization = "Bearer $AnonKey"
  'x-staff-session' = $SessionToken
}
$jsonHeaders = $headers.Clone()
$jsonHeaders['Content-Type'] = 'application/json'

function Invoke-TransferJson {
  param([hashtable]$Body)
  Invoke-RestMethod -Method Post -Uri $endpoint -Headers $jsonHeaders -Body ($Body | ConvertTo-Json -Depth 12 -Compress)
}

function Add-TransferPhoto {
  param([long]$TransferId, [guid]$ReceiptKey, [string]$Category = 'receipt')
  $client = [System.Net.Http.HttpClient]::new()
  $headers.GetEnumerator() | ForEach-Object { $client.DefaultRequestHeaders.TryAddWithoutValidation($_.Key, [string]$_.Value) | Out-Null }
  $form = [System.Net.Http.MultipartFormDataContent]::new()
  $form.Add([System.Net.Http.StringContent]::new($StaffName), 'staff_name')
  $form.Add([System.Net.Http.StringContent]::new([string]$TransferId), 'transfer_id')
  $form.Add([System.Net.Http.StringContent]::new([string]$ReceiptKey), 'receipt_key')
  $form.Add([System.Net.Http.StringContent]::new($Category), 'category')
  $file = Get-Item -LiteralPath $PhotoPath
  $fileContent = [System.Net.Http.ByteArrayContent]::new([System.IO.File]::ReadAllBytes($file.FullName))
  $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('image/png')
  $form.Add($fileContent, 'photo', $file.Name)
  try {
    $response = $client.PostAsync($endpoint, $form).GetAwaiter().GetResult()
    $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) { throw $responseText }
    $responseText | ConvertFrom-Json
  } finally {
    $form.Dispose()
    $client.Dispose()
  }
}

$context = Invoke-RestMethod -Method Get -Uri "$endpoint`?mode=context&staff_name=$([uri]::EscapeDataString($StaffName))" -Headers $headers
if (-not $context.ok -or @($context.stores).Count -ne 4 -or -not $context.staff.can_transfer_all_stores) {
  throw 'Transfer context did not authorize all four POS stores.'
}

$dispatchKey = [guid]::NewGuid()
$dispatchBody = @{
  action = 'dispatch'
  staff_name = $StaffName
  source_store_slug = 'park-ridge'
  destination_store_slug = 'north-lakes'
  items = @(@{ product_id = $ProductId; quantity = 4 })
  note = 'CODEX API E2E TEST'
  request_key = [string]$dispatchKey
}
$dispatch = Invoke-TransferJson $dispatchBody
$dispatchRetry = Invoke-TransferJson $dispatchBody
if ($dispatch.transfer.id -ne $dispatchRetry.transfer.id -or $dispatch.transfer.items[0].dispatched_quantity -ne 4) {
  throw 'Dispatch idempotency failed.'
}

$transferId = [long]$dispatch.transfer.id
$transferItemId = [long]$dispatch.transfer.items[0].id
$photoRequiredKey = [guid]::NewGuid()
$missingPhotoRejected = $false
try {
  Invoke-TransferJson @{
    action = 'receive'; staff_name = $StaffName; transfer_id = $transferId
    receipt_key = [string]$photoRequiredKey; finalize = $false; note = 'Must fail without photo'
    lines = @(@{ transfer_item_id = $transferItemId; good_quantity = 1; damaged_quantity = 0 })
  } | Out-Null
} catch {
  $missingPhotoRejected = $_.ErrorDetails.Message -match 'photo'
}
if (-not $missingPhotoRejected) { throw 'Receipt without a photo was not rejected.' }

$partialKey = [guid]::NewGuid()
$partialPhotoOne = Add-TransferPhoto -TransferId $transferId -ReceiptKey $partialKey
$partialPhotoTwo = Add-TransferPhoto -TransferId $transferId -ReceiptKey $partialKey
$partialBody = @{
  action = 'receive'; staff_name = $StaffName; transfer_id = $transferId
  receipt_key = [string]$partialKey; finalize = $false; note = 'API partial receipt'
  lines = @(@{ transfer_item_id = $transferItemId; good_quantity = 2; damaged_quantity = 1 })
}
$partial = Invoke-TransferJson $partialBody
$partialRetry = Invoke-TransferJson $partialBody
if ($partial.transfer.status -ne 'partially_received' -or $partial.transfer.items[0].remaining_quantity -ne 1) {
  throw 'Partial receipt totals or status are incorrect.'
}
if ($partialRetry.transfer.items[0].received_good_quantity -ne 2 -or @($partialRetry.transfer.photos).Count -ne 2) {
  throw 'Receipt idempotency or multiple-photo retention failed.'
}

$finalKey = [guid]::NewGuid()
$finalPhoto = Add-TransferPhoto -TransferId $transferId -ReceiptKey $finalKey
$final = Invoke-TransferJson @{
  action = 'receive'; staff_name = $StaffName; transfer_id = $transferId
  receipt_key = [string]$finalKey; finalize = $true; note = 'API final receipt'
  lines = @(@{ transfer_item_id = $transferItemId; good_quantity = 1; damaged_quantity = 0 })
}
if ($final.transfer.status -ne 'completed_with_issues' -or $final.transfer.items[0].received_good_quantity -ne 3 -or $final.transfer.items[0].received_damaged_quantity -ne 1) {
  throw 'Final issue receipt totals or status are incorrect.'
}

$detail = Invoke-RestMethod -Method Get -Uri "$endpoint`?mode=detail&staff_name=$([uri]::EscapeDataString($StaffName))&id=$transferId" -Headers $headers
if (-not $detail.ok -or @($detail.transfer.photos).Count -ne 3 -or @($detail.transfer.receipts).Count -ne 2) {
  throw 'Transfer detail did not include receipts and photos.'
}

[pscustomobject]@{
  ok = $true
  transfer_id = $transferId
  transfer_number = $detail.transfer.transfer_number
  status = $detail.transfer.status
  receipt_keys = @([string]$partialKey, [string]$finalKey)
  photo_ids = @([string]$partialPhotoOne.photo.id, [string]$partialPhotoTwo.photo.id, [string]$finalPhoto.photo.id)
  source_store = $detail.transfer.source_store.slug
  destination_store = $detail.transfer.destination_store.slug
  received_good = $detail.transfer.items[0].received_good_quantity
  received_damaged = $detail.transfer.items[0].received_damaged_quantity
} | ConvertTo-Json -Depth 8
