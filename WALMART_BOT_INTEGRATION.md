# Walmart Bot Integration Guide

This guide explains how to integrate the monitoring dashboard with your actual Walmart automation bot implementation.

## Integration Architecture

```
┌─────────────────┐    WebSocket    ┌──────────────────┐    HTTP/API    ┌─────────────────┐
│   Dashboard     │◄──────────────►│   Dashboard      │◄──────────────►│   Walmart Bot   │
│   (Frontend)    │                 │   Backend (Go)   │                 │   (Your Bot)    │
└─────────────────┘                 └──────────────────┘                 └─────────────────┘
```

## Bot Implementation Interface

### Required Bot Methods

Your Walmart bot should implement these methods for dashboard integration:

```go
type WalmartBotInterface interface {
    // Bot Control
    Start() error
    Stop() error
    GetStatus() BotStatus
    
    // Metrics
    GetSuccessMetrics() SuccessMetrics
    GetPerformanceMetrics() PerformanceMetrics
    
    // Proxy Management
    GetProxyHealth() []ProxyInfo
    RotateProxy() error
    
    // Order Management
    GetRecentOrders(limit int) []Order
    PlaceOrder(productID string, quantity int) (*Order, error)
    
    // Inventory Monitoring
    GetInventoryAlerts() []InventoryItem
    CheckProductAvailability(productID string) (*InventoryItem, error)
    
    // Configuration
    UpdateConfiguration(config Configuration) error
    GetConfiguration() Configuration
    
    // Logging
    GetLogs(limit int) []LogEntry
    AddLogEntry(message, level string)
}
```

### Integration Points

#### 1. Replace Mock Data with Real Bot Data

Update the `WalmartBot` struct in `walmart-bot-backend.go`:

```go
type WalmartBot struct {
    mu                sync.RWMutex
    
    // Add reference to your actual bot
    actualBot         WalmartBotInterface
    
    // Keep existing fields for caching and WebSocket management
    isRunning         bool
    clients           map[*websocket.Conn]bool
    // ... other fields
}

func NewWalmartBot(actualBot WalmartBotInterface) *WalmartBot {
    return &WalmartBot{
        actualBot: actualBot,
        // ... initialize other fields
    }
}
```

#### 2. Update Data Retrieval Methods

Replace mock data with actual bot data:

```go
func (bot *WalmartBot) GetStatus() BotStatus {
    // Instead of mock data, call your actual bot
    return bot.actualBot.GetStatus()
}

func (bot *WalmartBot) performCheck() {
    // Call actual bot methods instead of simulation
    metrics := bot.actualBot.GetSuccessMetrics()
    bot.successMetrics = metrics
    
    // Broadcast real data
    bot.broadcastMessage(WebSocketMessage{
        Type:    "success_metrics",
        Payload: metrics,
    })
}
```

#### 3. Proxy Integration

Connect to your proxy management system:

```go
func (bot *WalmartBot) proxyHealthCheck() {
    ticker := time.NewTicker(time.Duration(bot.config.ProxyHealthCheck) * time.Second)
    defer ticker.Stop()
    
    for range ticker.C {
        if !bot.isRunning {
            return
        }
        
        // Get real proxy health from your bot
        proxies := bot.actualBot.GetProxyHealth()
        
        bot.mu.Lock()
        bot.proxies = proxies
        bot.mu.Unlock()
        
        bot.broadcastMessage(WebSocketMessage{
            Type:    "proxy_health",
            Payload: proxies,
        })
    }
}
```

## Example Bot Implementation

Here's a sample implementation structure for your Walmart bot:

### 1. Main Bot Structure

```go
package main

import (
    "context"
    "fmt"
    "net/http"
    "sync"
    "time"
)

type WalmartAutomationBot struct {
    mu              sync.RWMutex
    client          *http.Client
    proxies         []*ProxyManager
    currentProxy    int
    isRunning       bool
    
    // Walmart-specific fields
    cookies         map[string]string
    sessionToken    string
    cartItems       []CartItem
    
    // Metrics tracking
    successCount    int
    failureCount    int
    lastCheck       time.Time
    
    // Configuration
    config          BotConfiguration
}

type BotConfiguration struct {
    CheckInterval      time.Duration
    MaxRetries         int
    RequestTimeout     time.Duration
    ProxyRotationTime  time.Duration
    UserAgent          string
    MaxConcurrent      int
}

func NewWalmartBot(config BotConfiguration) *WalmartAutomationBot {
    return &WalmartAutomationBot{
        client: &http.Client{
            Timeout: config.RequestTimeout,
        },
        config: config,
        cookies: make(map[string]string),
    }
}
```

### 2. Core Bot Methods

```go
func (bot *WalmartAutomationBot) Start() error {
    bot.mu.Lock()
    defer bot.mu.Unlock()
    
    if bot.isRunning {
        return fmt.Errorf("bot is already running")
    }
    
    bot.isRunning = true
    
    // Initialize session
    if err := bot.initializeSession(); err != nil {
        return fmt.Errorf("failed to initialize session: %v", err)
    }
    
    // Start monitoring goroutines
    go bot.inventoryMonitoringLoop()
    go bot.proxyHealthMonitoring()
    
    return nil
}

func (bot *WalmartAutomationBot) Stop() error {
    bot.mu.Lock()
    defer bot.mu.Unlock()
    
    bot.isRunning = false
    return nil
}

func (bot *WalmartAutomationBot) GetStatus() BotStatus {
    bot.mu.RLock()
    defer bot.mu.RUnlock()
    
    status := "STOPPED"
    if bot.isRunning {
        status = "ACTIVE"
    }
    
    return BotStatus{
        Status:    status,
        Uptime:    time.Since(bot.lastCheck).String(),
        LastCheck: bot.lastCheck.Format("3:04 PM"),
    }
}
```

### 3. Product Monitoring

```go
func (bot *WalmartAutomationBot) CheckProductAvailability(productID string) (*InventoryItem, error) {
    url := fmt.Sprintf("https://www.walmart.com/api/product-page/v2/product/%s", productID)
    
    req, err := http.NewRequest("GET", url, nil)
    if err != nil {
        return nil, err
    }
    
    // Add headers and cookies
    bot.addRequestHeaders(req)
    
    // Use current proxy
    resp, err := bot.makeRequest(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    
    // Parse response and extract inventory information
    item, err := bot.parseProductResponse(resp)
    if err != nil {
        return nil, err
    }
    
    return item, nil
}

func (bot *WalmartAutomationBot) inventoryMonitoringLoop() {
    ticker := time.NewTicker(bot.config.CheckInterval)
    defer ticker.Stop()
    
    for range ticker.C {
        if !bot.isRunning {
            return
        }
        
        // Monitor your target products
        products := bot.getTargetProducts()
        
        for _, productID := range products {
            item, err := bot.CheckProductAvailability(productID)
            if err != nil {
                bot.failureCount++
                continue
            }
            
            bot.successCount++
            
            // Check if product became available
            if bot.shouldPurchase(item) {
                go bot.attemptPurchase(productID)
            }
        }
        
        bot.lastCheck = time.Now()
    }
}
```

### 4. Order Processing

```go
func (bot *WalmartAutomationBot) PlaceOrder(productID string, quantity int) (*Order, error) {
    bot.mu.Lock()
    defer bot.mu.Unlock()
    
    // Add to cart
    if err := bot.addToCart(productID, quantity); err != nil {
        return nil, fmt.Errorf("failed to add to cart: %v", err)
    }
    
    // Proceed to checkout
    order, err := bot.checkout()
    if err != nil {
        return nil, fmt.Errorf("checkout failed: %v", err)
    }
    
    return order, nil
}

func (bot *WalmartAutomationBot) addToCart(productID string, quantity int) error {
    url := "https://www.walmart.com/api/v3/cart/:CRT/items"
    
    payload := map[string]interface{}{
        "products": []map[string]interface{}{
            {
                "productId": productID,
                "quantity":  quantity,
            },
        },
    }
    
    req, err := bot.createJSONRequest("POST", url, payload)
    if err != nil {
        return err
    }
    
    resp, err := bot.makeRequest(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()
    
    if resp.StatusCode != http.StatusOK {
        return fmt.Errorf("add to cart failed with status: %d", resp.StatusCode)
    }
    
    return nil
}

func (bot *WalmartAutomationBot) checkout() (*Order, error) {
    // Implement checkout logic
    // This would include:
    // 1. Review cart
    // 2. Select shipping method
    // 3. Apply payment method
    // 4. Submit order
    
    order := &Order{
        ID:        bot.generateOrderID(),
        Status:    "processing",
        Timestamp: time.Now(),
    }
    
    return order, nil
}
```

### 5. Proxy Management

```go
type ProxyManager struct {
    IP       string
    Port     int
    Username string
    Password string
    Healthy  bool
    LastUsed time.Time
    FailCount int
}

func (bot *WalmartAutomationBot) GetProxyHealth() []ProxyInfo {
    bot.mu.RLock()
    defer bot.mu.RUnlock()
    
    var proxies []ProxyInfo
    for _, proxy := range bot.proxies {
        proxies = append(proxies, ProxyInfo{
            IP:       proxy.IP,
            Port:     proxy.Port,
            Healthy:  proxy.Healthy,
            LastUsed: proxy.LastUsed,
        })
    }
    
    return proxies
}

func (bot *WalmartAutomationBot) proxyHealthMonitoring() {
    ticker := time.NewTicker(1 * time.Minute)
    defer ticker.Stop()
    
    for range ticker.C {
        if !bot.isRunning {
            return
        }
        
        for i, proxy := range bot.proxies {
            if bot.testProxyHealth(proxy) {
                bot.proxies[i].Healthy = true
                bot.proxies[i].FailCount = 0
            } else {
                bot.proxies[i].FailCount++
                if bot.proxies[i].FailCount >= 3 {
                    bot.proxies[i].Healthy = false
                }
            }
        }
    }
}

func (bot *WalmartAutomationBot) makeRequest(req *http.Request) (*http.Response, error) {
    // Implement request with current proxy
    proxy := bot.getCurrentProxy()
    if proxy == nil {
        return nil, fmt.Errorf("no healthy proxies available")
    }
    
    // Set proxy for the client
    // ... proxy configuration logic
    
    return bot.client.Do(req)
}
```

## Dashboard Integration Steps

### 1. Update Main Function

```go
func main() {
    // Initialize your actual Walmart bot
    botConfig := BotConfiguration{
        CheckInterval:     5 * time.Second,
        MaxRetries:       3,
        RequestTimeout:   30 * time.Second,
        ProxyRotationTime: 5 * time.Minute,
    }
    
    actualBot := NewWalmartBot(botConfig)
    
    // Create dashboard bot with your actual bot
    dashboardBot := NewWalmartBot(actualBot)
    
    // Start the dashboard server
    // ... rest of server setup
}
```

### 2. Environment Configuration

Create a `.env` file for configuration:

```env
# Walmart Bot Configuration
WALMART_CHECK_INTERVAL=5s
WALMART_MAX_RETRIES=3
WALMART_REQUEST_TIMEOUT=30s
WALMART_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

# Proxy Configuration
PROXY_ROTATION_INTERVAL=300s
PROXY_HEALTH_CHECK_INTERVAL=60s
PROXY_LIST="proxy1:port:user:pass,proxy2:port:user:pass"

# Dashboard Configuration
DASHBOARD_PORT=8080
DASHBOARD_HOST=0.0.0.0

# Security
ENABLE_HTTPS=false
SSL_CERT_PATH=""
SSL_KEY_PATH=""
```

### 3. Add Configuration Loading

```go
func loadConfiguration() BotConfiguration {
    return BotConfiguration{
        CheckInterval:     getDuration("WALMART_CHECK_INTERVAL", 5*time.Second),
        MaxRetries:        getInt("WALMART_MAX_RETRIES", 3),
        RequestTimeout:    getDuration("WALMART_REQUEST_TIMEOUT", 30*time.Second),
        ProxyRotationTime: getDuration("PROXY_ROTATION_INTERVAL", 5*time.Minute),
        UserAgent:         getString("WALMART_USER_AGENT", defaultUserAgent),
        MaxConcurrent:     getInt("WALMART_MAX_CONCURRENT", 5),
    }
}
```

## Security Considerations

### 1. Rate Limiting

```go
type RateLimiter struct {
    requests chan time.Time
    ticker   *time.Ticker
}

func NewRateLimiter(maxRequests int, duration time.Duration) *RateLimiter {
    rl := &RateLimiter{
        requests: make(chan time.Time, maxRequests),
        ticker:   time.NewTicker(duration / time.Duration(maxRequests)),
    }
    
    go func() {
        for t := range rl.ticker.C {
            select {
            case rl.requests <- t:
            default:
            }
        }
    }()
    
    return rl
}

func (rl *RateLimiter) Wait() {
    <-rl.requests
}
```

### 2. Request Fingerprinting Prevention

```go
func (bot *WalmartAutomationBot) addRequestHeaders(req *http.Request) {
    headers := map[string]string{
        "User-Agent":      bot.config.UserAgent,
        "Accept":          "application/json,text/html,application/xhtml+xml",
        "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "gzip, deflate, br",
        "DNT":            "1",
        "Connection":     "keep-alive",
        "Upgrade-Insecure-Requests": "1",
    }
    
    for key, value := range headers {
        req.Header.Set(key, value)
    }
    
    // Add cookies
    for name, value := range bot.cookies {
        req.AddCookie(&http.Cookie{Name: name, Value: value})
    }
}
```

### 3. Session Management

```go
func (bot *WalmartAutomationBot) initializeSession() error {
    // Visit homepage to get initial cookies
    req, err := http.NewRequest("GET", "https://www.walmart.com", nil)
    if err != nil {
        return err
    }
    
    bot.addRequestHeaders(req)
    
    resp, err := bot.makeRequest(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()
    
    // Extract and store cookies
    for _, cookie := range resp.Cookies() {
        bot.cookies[cookie.Name] = cookie.Value
    }
    
    return nil
}
```

## Testing and Debugging

### 1. Mock Mode for Testing

```go
type MockWalmartBot struct {
    // Implement WalmartBotInterface for testing
}

func NewMockWalmartBot() *MockWalmartBot {
    return &MockWalmartBot{}
}

// Use mock bot for development
func main() {
    var actualBot WalmartBotInterface
    
    if os.Getenv("MOCK_MODE") == "true" {
        actualBot = NewMockWalmartBot()
    } else {
        actualBot = NewWalmartBot(loadConfiguration())
    }
    
    dashboardBot := NewWalmartBot(actualBot)
    // ... continue with setup
}
```

### 2. Logging Integration

```go
import "go.uber.org/zap"

func (bot *WalmartAutomationBot) setupLogging() {
    config := zap.NewProductionConfig()
    config.OutputPaths = []string{"logs/walmart-bot.log", "stdout"}
    
    logger, err := config.Build()
    if err != nil {
        panic(err)
    }
    
    bot.logger = logger
}
```

This integration guide provides a complete framework for connecting your actual Walmart automation bot to the monitoring dashboard. The key is implementing the `WalmartBotInterface` methods in your bot and replacing the mock data sources in the dashboard backend.