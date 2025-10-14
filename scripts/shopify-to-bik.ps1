# ===============================
# Shopify Fulfilled Orders → BIK
# One-time send per AWB (lifetime unique)
# Single AWB → tracking_url
# Multiple AWBs → trac
# ===============================

# 🔑 Constants
$shopifyDomain   = $env:SHOPIFY_DOMAIN
$shopifyToken    = $env:SHOPIFY_TOKEN
$bikWebhookUrl   = $env:BIK_WEBHOOK_URL
$trackingBaseUrl = "https://www.babyjalebiglobal.com/pages/my-tracking-page0?awb="

# 📂 Memory file (dictionary: { awb1: true, awb2: true })
$memoryFile = "orders_sent.json"
if (Test-Path $memoryFile) {
    try {
        $sentAwbs = Get-Content $memoryFile | ConvertFrom-Json -AsHashtable
        if (-not $sentAwbs) { $sentAwbs = @{} }
    }
    catch {
        Write-Host "⚠️ Failed to parse orders_sent.json → resetting memory file"
        $sentAwbs = @{}
    }
} else {
    $sentAwbs = @{}
}

# 📡 Shopify API headers
$headers = @{
  "Content-Type"  = "application/json"
  "X-Shopify-Access-Token" = $shopifyToken
}

# ====================================
# 📞 Helper: Normalize Phone Number
# ====================================
function Normalize-Phone($phone, $defaultCountryCode="+971") {
    if ([string]::IsNullOrWhiteSpace($phone)) { return "" }
    $clean = ($phone -replace '[^0-9+]', '')
    if ($clean.StartsWith("+")) { return $clean }
    $clean = $clean.TrimStart("0")
    return "$defaultCountryCode$clean"
}

# 🗓️ Fetch last 30 days shipped orders
$thirtyDaysAgo = (Get-Date).AddDays(-30).ToString("o")
$ordersUrl = "https://$shopifyDomain/admin/api/2023-10/orders.json?status=any&fulfillment_status=shipped&created_at_min=$thirtyDaysAgo"
$response  = Invoke-RestMethod -Uri $ordersUrl -Headers $headers -Method Get

foreach ($order in $response.orders) {

    # Collect all AWBs
    $allAwbs = @()
    foreach ($fulfillment in $order.fulfillments) {
        foreach ($awb in $fulfillment.tracking_numbers) {
            if (-not [string]::IsNullOrWhiteSpace($awb)) {
                $cleanAwb = ($awb.Trim() -replace '\s+', '')
                if ($cleanAwb.Length -gt 3) {
                    $allAwbs += $cleanAwb
                }
            }
        }
    }

    if ($allAwbs.Count -eq 0) { 
        Write-Host "❌ Order $($order.id) has no valid AWBs → skipping"
        continue 
    }

    # Filter new AWBs (never sent before)
    $newAwbs = $allAwbs | Where-Object { -not $sentAwbs.ContainsKey($_) }

    if ($newAwbs.Count -eq 0) {
        Write-Host "⚠️ All AWBs for Order $($order.id) already sent → skipping"
        continue
    }

    # Build URLs
    $trackingUrls = $newAwbs | ForEach-Object { "$trackingBaseUrl$_" }

    # Customer details
    $customerEmail   = $order.email
    $customerPhone   = Normalize-Phone $order.shipping_address.phone "+971"
    $customerName    = $order.shipping_address.name
    $shippingAddress = "$($order.shipping_address.address1), $($order.shipping_address.city), $($order.shipping_address.country)"

    # Single AWB payload
    if ($newAwbs.Count -eq 1) {
        $awb = $newAwbs[0]
        $payload = @{
            order_id         = "$($order.id)"
            awb              = $awb
            tracking_url     = "$trackingBaseUrl$awb"
            email            = $customerEmail
            phone            = $customerPhone
            customer_name    = $customerName
            shipping_address = $shippingAddress
        }
    }
    else {
        # Multi AWB payload
        $payload = @{
            order_id         = "$($order.id)"
            awbs             = @($newAwbs)
            trac             = @($trackingUrls)
            email            = $customerEmail
            phone            = $customerPhone
            customer_name    = $customerName
            shipping_address = $shippingAddress
        }
    }

    # Convert safely to JSON + UTF-8 encode
    $jsonBody = ($payload | ConvertTo-Json -Depth 5 -Compress)
    $utf8Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

    try {
        Invoke-RestMethod -Uri $bikWebhookUrl -Method Post -Headers @{ "Content-Type"="application/json" } -Body $utf8Body
        Write-Host "📤 Sent Order $($order.id) → AWBs: $($newAwbs -join ', ')"

        # Save memory once per new AWB
        foreach ($awb in $newAwbs) { $sentAwbs[$awb] = $true }
        $sentAwbs | ConvertTo-Json -Depth 5 | Set-Content $memoryFile
    }
    catch {
        Write-Host "❌ Error sending Order $($order.id): $($_.Exception.Message)"
    }
}
