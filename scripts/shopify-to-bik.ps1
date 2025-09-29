# ===============================
# Shopify Fulfilled Orders → BIK
# One-time send per order
# Always builds tracking URL from AWB
# ===============================

# 🔑 Constants
$shopifyDomain   = "babyjalebigobal.myshopify.com"
$shopifyToken    = $env:SHOPIFY_TOKEN_ADI_GLOBAL
$bikWebhookUrl   = "https://bikapi.bikayi.app/chatbot/webhook/CvmfOmjgYZOuh49FxGQuDWhe4i62?flow=ordertrack5667"
$trackingBaseUrl = "https://www.babyjalebiglobal.com/pages/my-tracking-page0?awb="

# 📂 Memory file
$memoryFile = "orders_sent.json"
if (Test-Path $memoryFile) {
    $sentOrders = Get-Content $memoryFile | ConvertFrom-Json
} else {
    $sentOrders = @()
}

# 📡 Shopify API headers
$headers = @{
  "Content-Type"  = "application/json"
  "X-Shopify-Access-Token" = $shopifyToken
}

# 📦 Fetch shipped orders
$ordersUrl = "https://$shopifyDomain/admin/api/2023-10/orders.json?status=any&fulfillment_status=shipped"
$response  = Invoke-RestMethod -Uri $ordersUrl -Headers $headers -Method Get

foreach ($order in $response.orders) {
    if ($sentOrders -contains $order.id) {
        Write-Host "⚠️ Order $($order.id) already processed → skipping..."
        continue
    }

    # Collect AWBs
    $allAwbs = @()
    foreach ($fulfillment in $order.fulfillments) {
        foreach ($awb in $fulfillment.tracking_numbers) {
            if ($awb) { $allAwbs += $awb }
        }
    }

    if ($allAwbs.Count -eq 0) { continue }

    # Build tracking URLs properly
    $trackingUrls = $allAwbs | ForEach-Object { "$trackingBaseUrl$_" }

    # Customer details
    $customerEmail   = $order.email
    $customerPhone   = $order.shipping_address.phone
    $customerName    = $order.shipping_address.name
    $shippingAddress = "$($order.shipping_address.name), $($order.shipping_address.address1), $($order.shipping_address.city), $($order.shipping_address.province), $($order.shipping_address.country)"

    # ==========================
    # Case 1 → Single AWB
    # ==========================
    if ($allAwbs.Count -eq 1) {
        $trackingUrl = "$trackingBaseUrl$($allAwbs[0])"
        $templateMessage = @"
📦✨ Good news, $customerName!  
Your parcel has been dispatched and will be reaching you very soon 🚚💨  

Track your order instantly with the link below 👇  
🔗 $trackingUrl  

Thank you for shopping with Baby Jalebi 💕
"@

        $payload = @{
            order_id         = $order.id
            awb              = $allAwbs[0]
            tracking_url     = $trackingUrl
            email            = $customerEmail
            phone            = $customerPhone
            customer_name    = $customerName
            shipping_address = $shippingAddress
            template_message = $templateMessage
        } | ConvertTo-Json -Depth 3
    }

    # ==========================
    # Case 2 → Multiple AWBs
    # ==========================
    else {
        $linksBlock = ($trackingUrls | ForEach-Object { "🔗 $_" }) -join "`n"
        $templateMessage = @"
📦✨ Hi $customerName, exciting update!  
Since you ordered multiple products, we’ve assigned multiple tracking numbers for your shipments 🛍️🚚  

You can track each item using the links below 👇  

$linksBlock

We’ll keep you updated until everything reaches you safely 💕  
– Team Baby Jalebi 🌸
"@

        $payload = @{
            order_id         = $order.id
            awbs             = $allAwbs
            tracking_urls    = $trackingUrls
            email            = $customerEmail
            phone            = $customerPhone
            customer_name    = $customerName
            shipping_address = $shippingAddress
            template_message = $templateMessage
        } | ConvertTo-Json -Depth 3
    }

    # 📤 Send payload
    Write-Host "📤 Sending Order $($order.id) with $($allAwbs.Count) tracking number(s)..."

    try {
        Invoke-RestMethod -Uri $bikWebhookUrl -Method Post -Headers @{ "Content-Type" = "application/json" } -Body $payload

        # Mark order as sent
        $sentOrders += $order.id
        $sentOrders | ConvertTo-Json | Set-Content $memoryFile
    }
    catch {
        Write-Host "❌ Error sending Order $($order.id) → $($_.Exception.Message)"
    }
}
