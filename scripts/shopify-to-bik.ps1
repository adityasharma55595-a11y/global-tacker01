# ===============================
# Shopify Fulfilled Orders → BIK
# One-time send per order/awb
# ===============================

# 🔑 Constants
$shopifyDomain   = $env:SHOPIFY_DOMAIN
$shopifyToken    = $env:SHOPIFY_TOKEN
$bikWebhookUrl   = $env:BIK_WEBHOOK_URL
$trackingBaseUrl = "https://www.babyjalebiglobal.com/pages/my-tracking-page0?awb="

# 📂 Memory file structure = { "orderId": ["awb1","awb2"] }
$memoryFile = "orders_sent.json"
if (Test-Path $memoryFile) {
    $sentOrders = Get-Content $memoryFile | ConvertFrom-Json
} else {
    $sentOrders = @{}
}

# 📡 Shopify API headers
$headers = @{
  "Content-Type"  = "application/json"
  "X-Shopify-Access-Token" = $shopifyToken
}

# 🗓️ Only last 30 days shipped orders
$thirtyDaysAgo = (Get-Date).AddDays(-30).ToString("o")
$ordersUrl = "https://$shopifyDomain/admin/api/2023-10/orders.json?status=any&fulfillment_status=shipped&created_at_min=$thirtyDaysAgo"
$response  = Invoke-RestMethod -Uri $ordersUrl -Headers $headers -Method Get

foreach ($order in $response.orders) {
    $orderId = "$($order.id)"

    if (-not $sentOrders.ContainsKey($orderId)) {
        $sentOrders[$orderId] = @()
    }

    # Collect AWBs
    $allAwbs = @()
    foreach ($fulfillment in $order.fulfillments) {
        foreach ($awb in $fulfillment.tracking_numbers) {
            if ($awb) { $allAwbs += $awb }
        }
    }

    if ($allAwbs.Count -eq 0) { continue }

    # Build tracking URLs
    $trackingUrls = $allAwbs | ForEach-Object { "$trackingBaseUrl$_" }

    # Customer details (safe fallback)
    $customerEmail   = $order.email
    $customerPhone   = $order.shipping_address.phone
    $customerName    = if ($order.shipping_address.name) { $order.shipping_address.name } else { "$($order.customer.first_name) $($order.customer.last_name)" }
    $shippingAddress = "$($order.shipping_address.address1), $($order.shipping_address.city), $($order.shipping_address.province), $($order.shipping_address.country)"

    # For each AWB → ensure it has not been sent before
    foreach ($awb in $allAwbs) {
        if ($sentOrders[$orderId] -contains $awb) {
            Write-Host "⚠️ Order $orderId / AWB $awb already processed → skipping..."
            continue
        }

        $tracking_url = "$trackingBaseUrl$awb"

        # ==========================
        # Case → Single AWB
        # ==========================
        if ($allAwbs.Count -eq 1) {
            $templateMessage = @"
📦✨ Good news, $customerName!  
Your parcel has been dispatched and will be reaching you very soon 🚚💨  

Track your order instantly with the link below 👇  
🔗 $tracking_url  

Thank you for shopping with Baby Jalebi 💕
"@

            $payload = @{
                order_id         = $orderId
                awb              = $awb
                tracking_url     = $tracking_url   # ✅ single AWB
                email            = $customerEmail
                phone            = $customerPhone
                customer_name    = $customerName
                shipping_address = $shippingAddress
                template_message = $templateMessage
            } | ConvertTo-Json -Depth 3
        }

        # ==========================
        # Case → Multiple AWBs
        # ==========================
        else {
            $trac = $trackingUrls
            $linksBlock = ($trac | ForEach-Object { "🔗 $_" }) -join "`n"

            $templateMessage = @"
📦✨ Hi $customerName, exciting update!  
Since you ordered multiple products, we’ve assigned multiple tracking numbers for your shipments 🛍️🚚  

You can track each item using the links below 👇  

$linksBlock

We’ll keep you updated until everything reaches you safely 💕  
– Team Baby Jalebi 🌸
"@

            $payload = @{
                order_id         = $orderId
                awbs             = $allAwbs
                trac             = $trac           # ✅ multiple AWBs
                email            = $customerEmail
                phone            = $customerPhone
                customer_name    = $customerName
                shipping_address = $shippingAddress
                template_message = $templateMessage
            } | ConvertTo-Json -Depth 3
        }

        # 📤 Send payload
        Write-Host "📤 Sending Order $orderId / AWB $awb..."
        try {
            Invoke-RestMethod -Uri $bikWebhookUrl -Method Post -Headers @{ "Content-Type" = "application/json" } -Body $payload

            # Mark this AWB as sent
            $sentOrders[$orderId] += $awb
            $sentOrders | ConvertTo-Json -Depth 5 | Set-Content $memoryFile
        }
        catch {
            Write-Host "❌ Error sending Order $orderId / AWB $awb → $($_.Exception.Message)"
        }
    }
}
