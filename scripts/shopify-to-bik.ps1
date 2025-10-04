# ===============================
# Shopify Fulfilled Orders → BIK
# One-time send per AWB
# Single AWB → tracking_url
# Multiple AWBs → trac
# ===============================

# 🔑 Constants
$shopifyDomain   = $env:SHOPIFY_DOMAIN
$shopifyToken    = $env:SHOPIFY_TOKEN
$bikWebhookUrl   = $env:BIK_WEBHOOK_URL
$trackingBaseUrl = "https://www.babyjalebiglobal.com/pages/my-tracking-page0?awb="

# 📂 Memory file (dictionary: { orderId: [awb1, awb2] })
$memoryFile = "orders_sent.json"
if (Test-Path $memoryFile) {
    $content = Get-Content $memoryFile | ConvertFrom-Json
    if ($content -is [System.Collections.Hashtable] -or $content.PSObject.Properties.Count -gt 0) {
        $sentOrders = $content
    } else {
        # Legacy array → upgrade to dictionary
        $sentOrders = @{}
        foreach ($oid in $content) { $sentOrders["$oid"] = @() }
    }
} else {
    $sentOrders = @{}
}

# 📡 Shopify API headers
$headers = @{
  "Content-Type"  = "application/json"
  "X-Shopify-Access-Token" = $shopifyToken
}

# 🗓️ Fetch only last 30 days shipped orders
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

    # Customer details
    $customerEmail   = $order.email
    $customerPhone   = $order.shipping_address.phone
    $customerName    = if ($order.shipping_address.name) { $order.shipping_address.name } else { "$($order.customer.first_name) $($order.customer.last_name)" }
    $shippingAddress = "$($order.shipping_address.address1), $($order.shipping_address.city), $($order.shipping_address.province), $($order.shipping_address.country)"

    # ==========================
    # Single AWB
    # ==========================
    if ($allAwbs.Count -eq 1) {
        $awb = $allAwbs[0]

        if ($sentOrders[$orderId] -contains $awb) {
            Write-Host "⚠️ Skipping duplicate AWB $awb for Order $orderId"
            continue
        }

        $tracking_url = $trackingUrls[0]
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
            tracking_url     = $tracking_url
            email            = $customerEmail
            phone            = $customerPhone
            customer_name    = $customerName
            shipping_address = $shippingAddress
            template_message = $templateMessage
        } | ConvertTo-Json -Depth 3

        try {
            Invoke-RestMethod -Uri $bikWebhookUrl -Method Post -Headers @{ "Content-Type"="application/json" } -Body $payload
            Write-Host "📤 Sent Order $orderId / AWB $awb"

            # Save memory
            $sentOrders[$orderId] += $awb
            $sentOrders | ConvertTo-Json -Depth 5 | Set-Content $memoryFile
        }
        catch {
            Write-Host "❌ Error sending Order $orderId / AWB $awb → $($_.Exception.Message)"
        }
    }

    # ==========================
    # Multiple AWBs
    # ==========================
    else {
        $newAwbs = @()
        foreach ($awb in $allAwbs) {
            if (-not ($sentOrders[$orderId] -contains $awb)) {
                $newAwbs += $awb
            }
        }

        if ($newAwbs.Count -eq 0) {
            Write-Host "⚠️ All AWBs for Order $orderId already sent → skipping..."
            continue
        }

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
            trac             = $trac
            email            = $customerEmail
            phone            = $customerPhone
            customer_name    = $customerName
            shipping_address = $shippingAddress
            template_message = $templateMessage
        } | ConvertTo-Json -Depth 3

        try {
            Invoke-RestMethod -Uri $bikWebhookUrl -Method Post -Headers @{ "Content-Type"="application/json" } -Body $payload
            Write-Host "📤 Sent Order $orderId with multiple AWBs: $($newAwbs -join ', ')"

            # Save memory
            $sentOrders[$orderId] += $newAwbs
            $sentOrders | ConvertTo-Json -Depth 5 | Set-Content $memoryFile
        }
        catch {
            Write-Host "❌ Error sending Order $orderId → $($_.Exception.Message)"
        }
    }
}
