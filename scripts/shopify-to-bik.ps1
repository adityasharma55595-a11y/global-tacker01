# ===============================
# Shopify Fulfilled Orders → BIK
# One-time send per AWB (lifetime unique)
# Single AWB → tracking_url
# Multiple AWBs → trac (newline separated)
# Only after 48 hours of shipment creation
# ===============================

# 🔑 Constants
$shopifyDomain   = $env:SHOPIFY_DOMAIN
$shopifyToken    = $env:SHOPIFY_TOKEN
$bikWebhookUrl   = $env:BIK_WEBHOOK_URL
$trackingBaseUrl = "https://parcelsapp.com/en/tracking/"   # ← (changed from babyjalebiglobal tracking page)

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

# 🗓️ Fetch only last 5 days shipped orders
$fiveDaysAgo = (Get-Date).AddDays(-5).ToString("o")
$today = (Get-Date).ToString("o")
$ordersUrl = "https://$shopifyDomain/admin/api/2023-10/orders.json?status=any&fulfillment_status=shipped&created_at_min=$fiveDaysAgo&created_at_max=$today&limit=250"
$response  = Invoke-RestMethod -Uri $ordersUrl -Headers $headers -Method Get

Write-Host "📦 Found $($response.orders.Count) shipped orders from last 5 days"

foreach ($order in $response.orders) {

    $allAwbs = @()
    $recentFulfillmentFound = $false

    foreach ($fulfillment in $order.fulfillments) {
        # Skip very recent fulfillments (less than 48 hours old)
        if ($fulfillment.created_at) {
            $fulfillmentAgeHrs = (New-TimeSpan -Start ([datetime]$fulfillment.created_at) -End (Get-Date)).TotalHours
            if ($fulfillmentAgeHrs -lt 48) {
                $recentFulfillmentFound = $true
                continue
            }
        }

        # Collect valid tracking numbers
        foreach ($awb in $fulfillment.tracking_numbers) {
            if (-not [string]::IsNullOrWhiteSpace($awb)) {
                $cleanAwb = ($awb.Trim() -replace '\s+', '')
                if ($cleanAwb.Length -gt 3) {
                    $allAwbs += $cleanAwb
                }
            }
        }
    }

    if ($recentFulfillmentFound -and $allAwbs.Count -eq 0) {
        Write-Host "🕒 Order $($order.id) has a new shipment (<48h old) → wait before sending"
        continue
    }

    if ($allAwbs.Count -eq 0) { 
        Write-Host "❌ Order $($order.id) has no valid tracking number → skipping"
        continue 
    }

    # Filter out AWBs already sent
    $newAwbs = $allAwbs | Where-Object { -not $sentAwbs.ContainsKey($_) }
    if ($newAwbs.Count -eq 0) {
        Write-Host "⚠️ All AWBs for Order $($order.id) already sent → skipping"
        continue
    }

    # Build tracking URLs
    $trackingUrls = $newAwbs | ForEach-Object { "$trackingBaseUrl$_" }

    # Customer details
    $customerEmail   = $order.email
    $customerPhone   = Normalize-Phone $order.shipping_address.phone "+971"
    $customerName    = $order.shipping_address.name
    $shippingAddress = "$($order.shipping_address.address1), $($order.shipping_address.city), $($order.shipping_address.country)"

    # Build Payload
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
    } else {
        $joinedUrls = ($trackingUrls -join "`n")
        $payload = @{
            order_id         = "$($order.id)"
            awbs             = @($newAwbs)
            trac             = $joinedUrls
            email            = $customerEmail
            phone            = $customerPhone
            customer_name    = $customerName
            shipping_address = $shippingAddress
        }
    }

    # Send to BIK Webhook
    try {
        $jsonBody = ($payload | ConvertTo-Json -Depth 5 -Compress)
        $utf8Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        Invoke-RestMethod -Uri $bikWebhookUrl -Method Post -Headers @{ "Content-Type"="application/json" } -Body $utf8Body

        Write-Host "`n📤 Sent Order $($order.id)"
        Write-Host "AWBs:`n$($newAwbs -join "`n")"
        Write-Host "Tracking URLs:`n$($trackingUrls -join "`n")`n"

        foreach ($awb in $newAwbs) { $sentAwbs[$awb] = $true }
        $sentAwbs | ConvertTo-Json -Depth 5 | Set-Content $memoryFile
    }
    catch {
        Write-Host "❌ Error sending Order $($order.id): $($_.Exception.Message)"
    }
}
