# Walmart Automation Bot Backend Architecture

## Project Structure
```
walmart-bot/
├── cmd/
│   └── main.go                 # Application entry point
├── internal/
│   ├── auth/
│   │   ├── login.go           # Login authentication
│   │   ├── otp.go             # OTP verification
│   │   └── graphql.go         # GraphQL client for identity.walmart.com
│   ├── checkout/
│   │   ├── cart.go            # Cart management
│   │   ├── payment.go         # Payment processing
│   │   └── order.go           # Order submission
│   ├── proxy/
│   │   ├── manager.go         # Proxy rotation and health checking
│   │   ├── types.go           # Proxy configuration types
│   │   └── health.go          # Health checking logic
│   ├── tlsclient/
│   │   ├── bridge.go          # Python-Go bridge
│   │   ├── client.go          # TLS client wrapper
│   │   └── fingerprint.go     # Chrome 120 fingerprint
│   ├── session/
│   │   ├── manager.go         # Session and cookie management
│   │   └── storage.go         # Persistent storage
│   ├── queue/
│   │   ├── manager.go         # Rate limiting queue
│   │   └── worker.go          # Worker pool
│   ├── logging/
│   │   ├── discord.go         # Discord webhook logging
│   │   └── replay.go          # Request/response replay
│   └── config/
│       └── config.go          # Configuration management
├── pkg/
│   └── models/
│       ├── auth.go            # Authentication models
│       ├── checkout.go        # Checkout models
│       └── proxy.go           # Proxy models
├── python/
│   ├── tls_bridge.py          # Python TLS client bridge
│   └── requirements.txt       # Python dependencies
├── go.mod
├── go.sum
└── README.md
```

## Core Components Implementation

### 1. TLS Client Bridge (tlsclient/bridge.go)

```go
package tlsclient

/*
#cgo CFLAGS: -I./python
#cgo LDFLAGS: -lpython3.11
#include <Python.h>
#include <stdlib.h>

PyObject* init_tls_client();
PyObject* make_request(PyObject* client, char* method, char* url, char* headers, char* data, char* proxy);
void cleanup_python();
*/
import "C"

import (
    "encoding/json"
    "errors"
    "fmt"
    "unsafe"
)

type TLSClient struct {
    pyClient C.PyObject
}

type RequestConfig struct {
    Method  string            `json:"method"`
    URL     string            `json:"url"`
    Headers map[string]string `json:"headers"`
    Data    string            `json:"data,omitempty"`
    Proxy   string            `json:"proxy,omitempty"`
}

type Response struct {
    StatusCode int               `json:"status_code"`
    Headers    map[string]string `json:"headers"`
    Body       string            `json:"body"`
    Cookies    map[string]string `json:"cookies"`
}

func NewTLSClient() (*TLSClient, error) {
    C.Py_Initialize()
    if C.Py_IsInitialized() == 0 {
        return nil, errors.New("failed to initialize Python")
    }
    
    pyClient := C.init_tls_client()
    if pyClient == nil {
        return nil, errors.New("failed to initialize TLS client")
    }
    
    return &TLSClient{pyClient: *pyClient}, nil
}

func (c *TLSClient) MakeRequest(config RequestConfig) (*Response, error) {
    // Convert headers and data to JSON
    headersJSON, _ := json.Marshal(config.Headers)
    
    // Convert Go strings to C strings
    method := C.CString(config.Method)
    url := C.CString(config.URL)
    headers := C.CString(string(headersJSON))
    data := C.CString(config.Data)
    proxy := C.CString(config.Proxy)
    
    defer func() {
        C.free(unsafe.Pointer(method))
        C.free(unsafe.Pointer(url))
        C.free(unsafe.Pointer(headers))
        C.free(unsafe.Pointer(data))
        C.free(unsafe.Pointer(proxy))
    }()
    
    // Make the request through Python
    pyResult := C.make_request(&c.pyClient, method, url, headers, data, proxy)
    if pyResult == nil {
        return nil, errors.New("failed to make request")
    }
    
    // Convert Python result to Go Response
    // This would need proper Python C API handling
    response := &Response{
        StatusCode: 200, // Placeholder - would extract from Python result
        Headers:    make(map[string]string),
        Body:       "", // Would extract from Python result
        Cookies:    make(map[string]string),
    }
    
    return response, nil
}

func (c *TLSClient) Close() {
    C.cleanup_python()
    C.Py_Finalize()
}
```

### 2. Chrome 120 Fingerprint (tlsclient/fingerprint.go)

```go
package tlsclient

const Chrome120Fingerprint = `{
    "ja3": "771,4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,0-23-65281-10-11-35-16-5-13-18-51-45-43-27-17513,29-23-24,0",
    "ja4": "t13d1516h2_8daaf6152771_02713d6af862",
    "akamai": "1:65536,2:0,3:1000,4:6553600,6:262144|15663105|0|m,a,s,p",
    "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "headers": {
        "sec-ch-ua": "\"Not_A Brand\";v=\"8\", \"Chromium\";v=\"120\", \"Google Chrome\";v=\"120\"",
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": "\"Windows\"",
        "sec-fetch-dest": "document",
        "sec-fetch-mode": "navigate",
        "sec-fetch-site": "none",
        "sec-fetch-user": "?1",
        "upgrade-insecure-requests": "1",
        "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "accept-encoding": "gzip, deflate, br",
        "accept-language": "en-US,en;q=0.9"
    }
}`

type Fingerprint struct {
    JA3       string            `json:"ja3"`
    JA4       string            `json:"ja4"`
    Akamai    string            `json:"akamai"`
    UserAgent string            `json:"user_agent"`
    Headers   map[string]string `json:"headers"`
}

func GetChrome120Fingerprint() (*Fingerprint, error) {
    var fp Fingerprint
    err := json.Unmarshal([]byte(Chrome120Fingerprint), &fp)
    if err != nil {
        return nil, fmt.Errorf("failed to parse fingerprint: %w", err)
    }
    return &fp, nil
}
```

### 3. GraphQL Client for Authentication (auth/graphql.go)

```go
package auth

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "time"
    
    "walmart-bot/internal/tlsclient"
    "walmart-bot/pkg/models"
)

type GraphQLClient struct {
    tlsClient *tlsclient.TLSClient
    endpoint  string
    headers   map[string]string
}

type GraphQLRequest struct {
    Query     string                 `json:"query"`
    Variables map[string]interface{} `json:"variables,omitempty"`
}

type GraphQLResponse struct {
    Data   interface{} `json:"data"`
    Errors []GraphQLError `json:"errors,omitempty"`
}

type GraphQLError struct {
    Message   string `json:"message"`
    Path      []string `json:"path,omitempty"`
    Extensions map[string]interface{} `json:"extensions,omitempty"`
}

const (
    WalmartIdentityEndpoint = "https://identity.walmart.com/graphql"
    
    LoginMutation = `
        mutation SignIn($email: String!, $password: String!) {
            signIn(email: $email, password: $password) {
                user {
                    id
                    email
                    firstName
                    lastName
                }
                token
                refreshToken
                requiresOTP
                otpDeliveryMethods
            }
        }
    `
    
    OTPVerificationMutation = `
        mutation VerifyOTP($token: String!, $otpCode: String!) {
            verifyOTP(token: $token, otpCode: $otpCode) {
                user {
                    id
                    email
                    firstName
                    lastName
                }
                token
                refreshToken
                isVerified
            }
        }
    `
    
    RefreshTokenMutation = `
        mutation RefreshToken($refreshToken: String!) {
            refreshToken(refreshToken: $refreshToken) {
                token
                refreshToken
                expiresAt
            }
        }
    `
)

func NewGraphQLClient(tlsClient *tlsclient.TLSClient) *GraphQLClient {
    fp, _ := tlsclient.GetChrome120Fingerprint()
    
    headers := make(map[string]string)
    for k, v := range fp.Headers {
        headers[k] = v
    }
    headers["Content-Type"] = "application/json"
    headers["Origin"] = "https://www.walmart.com"
    headers["Referer"] = "https://www.walmart.com/"
    
    return &GraphQLClient{
        tlsClient: tlsClient,
        endpoint:  WalmartIdentityEndpoint,
        headers:   headers,
    }
}

func (c *GraphQLClient) Execute(ctx context.Context, query string, variables map[string]interface{}) (*GraphQLResponse, error) {
    request := GraphQLRequest{
        Query:     query,
        Variables: variables,
    }
    
    requestBody, err := json.Marshal(request)
    if err != nil {
        return nil, fmt.Errorf("failed to marshal request: %w", err)
    }
    
    config := tlsclient.RequestConfig{
        Method:  "POST",
        URL:     c.endpoint,
        Headers: c.headers,
        Data:    string(requestBody),
    }
    
    resp, err := c.tlsClient.MakeRequest(config)
    if err != nil {
        return nil, fmt.Errorf("failed to make request: %w", err)
    }
    
    var graphqlResp GraphQLResponse
    if err := json.Unmarshal([]byte(resp.Body), &graphqlResp); err != nil {
        return nil, fmt.Errorf("failed to unmarshal response: %w", err)
    }
    
    return &graphqlResp, nil
}

func (c *GraphQLClient) Login(ctx context.Context, email, password string) (*models.LoginResponse, error) {
    variables := map[string]interface{}{
        "email":    email,
        "password": password,
    }
    
    resp, err := c.Execute(ctx, LoginMutation, variables)
    if err != nil {
        return nil, fmt.Errorf("login failed: %w", err)
    }
    
    if len(resp.Errors) > 0 {
        return nil, fmt.Errorf("login error: %s", resp.Errors[0].Message)
    }
    
    // Parse the response data into LoginResponse
    // This would need proper type assertion and error handling
    var loginResp models.LoginResponse
    // ... parsing logic ...
    
    return &loginResp, nil
}

func (c *GraphQLClient) VerifyOTP(ctx context.Context, token, otpCode string) (*models.OTPVerificationResponse, error) {
    variables := map[string]interface{}{
        "token":   token,
        "otpCode": otpCode,
    }
    
    resp, err := c.Execute(ctx, OTPVerificationMutation, variables)
    if err != nil {
        return nil, fmt.Errorf("OTP verification failed: %w", err)
    }
    
    if len(resp.Errors) > 0 {
        return nil, fmt.Errorf("OTP error: %s", resp.Errors[0].Message)
    }
    
    var otpResp models.OTPVerificationResponse
    // ... parsing logic ...
    
    return &otpResp, nil
}
```

### 4. Authentication Module (auth/login.go)

```go
package auth

import (
    "context"
    "fmt"
    "time"
    
    "walmart-bot/internal/logging"
    "walmart-bot/internal/session"
    "walmart-bot/pkg/models"
)

type AuthManager struct {
    graphqlClient  *GraphQLClient
    sessionManager *session.Manager
    logger         *logging.Logger
}

func NewAuthManager(graphqlClient *GraphQLClient, sessionManager *session.Manager, logger *logging.Logger) *AuthManager {
    return &AuthManager{
        graphqlClient:  graphqlClient,
        sessionManager: sessionManager,
        logger:         logger,
    }
}

func (am *AuthManager) Login(ctx context.Context, credentials models.LoginCredentials) (*models.AuthSession, error) {
    am.logger.Info("Starting login process", map[string]interface{}{
        "email": credentials.Email,
    })
    
    // Attempt initial login
    loginResp, err := am.graphqlClient.Login(ctx, credentials.Email, credentials.Password)
    if err != nil {
        am.logger.Error("Login failed", err, map[string]interface{}{
            "email": credentials.Email,
        })
        return nil, fmt.Errorf("login failed: %w", err)
    }
    
    // Check if OTP is required
    if loginResp.RequiresOTP {
        am.logger.Info("OTP required for login", map[string]interface{}{
            "email": credentials.Email,
            "methods": loginResp.OTPDeliveryMethods,
        })
        
        // Handle OTP flow
        return am.handleOTPFlow(ctx, loginResp, credentials)
    }
    
    // Create session
    session := &models.AuthSession{
        UserID:       loginResp.User.ID,
        Email:        loginResp.User.Email,
        Token:        loginResp.Token,
        RefreshToken: loginResp.RefreshToken,
        ExpiresAt:    time.Now().Add(24 * time.Hour), // Default expiry
        CreatedAt:    time.Now(),
    }
    
    // Store session
    if err := am.sessionManager.StoreSession(session); err != nil {
        am.logger.Error("Failed to store session", err, map[string]interface{}{
            "userID": session.UserID,
        })
        return nil, fmt.Errorf("failed to store session: %w", err)
    }
    
    am.logger.Success("Login successful", map[string]interface{}{
        "userID": session.UserID,
        "email":  session.Email,
    })
    
    return session, nil
}

func (am *AuthManager) handleOTPFlow(ctx context.Context, loginResp *models.LoginResponse, credentials models.LoginCredentials) (*models.AuthSession, error) {
    if credentials.OTPCallback == nil {
        return nil, fmt.Errorf("OTP required but no callback provided")
    }
    
    // Get OTP code from callback
    otpCode, err := credentials.OTPCallback(loginResp.OTPDeliveryMethods)
    if err != nil {
        return nil, fmt.Errorf("failed to get OTP code: %w", err)
    }
    
    // Verify OTP
    otpResp, err := am.graphqlClient.VerifyOTP(ctx, loginResp.Token, otpCode)
    if err != nil {
        am.logger.Error("OTP verification failed", err, map[string]interface{}{
            "email": credentials.Email,
        })
        return nil, fmt.Errorf("OTP verification failed: %w", err)
    }
    
    if !otpResp.IsVerified {
        return nil, fmt.Errorf("OTP verification failed: invalid code")
    }
    
    // Create session with OTP-verified token
    session := &models.AuthSession{
        UserID:       otpResp.User.ID,
        Email:        otpResp.User.Email,
        Token:        otpResp.Token,
        RefreshToken: otpResp.RefreshToken,
        ExpiresAt:    time.Now().Add(24 * time.Hour),
        CreatedAt:    time.Now(),
    }
    
    return session, nil
}

func (am *AuthManager) RefreshSession(ctx context.Context, session *models.AuthSession) error {
    refreshResp, err := am.graphqlClient.Execute(ctx, RefreshTokenMutation, map[string]interface{}{
        "refreshToken": session.RefreshToken,
    })
    if err != nil {
        return fmt.Errorf("failed to refresh token: %w", err)
    }
    
    // Update session with new tokens
    // ... update logic ...
    
    return am.sessionManager.UpdateSession(session)
}

func (am *AuthManager) ValidateSession(session *models.AuthSession) error {
    if session.ExpiresAt.Before(time.Now()) {
        return fmt.Errorf("session expired")
    }
    
    if session.Token == "" {
        return fmt.Errorf("invalid session: missing token")
    }
    
    return nil
}
```

### 5. Proxy Management (proxy/manager.go)

```go
package proxy

import (
    "context"
    "fmt"
    "net/url"
    "sync"
    "time"
    
    "walmart-bot/internal/logging"
    "walmart-bot/pkg/models"
)

type Manager struct {
    proxies    []models.ProxyConfig
    current    int
    mutex      sync.RWMutex
    healthChecker *HealthChecker
    logger     *logging.Logger
}

func NewManager(proxies []models.ProxyConfig, logger *logging.Logger) *Manager {
    manager := &Manager{
        proxies:    proxies,
        current:    0,
        logger:     logger,
    }
    
    manager.healthChecker = NewHealthChecker(manager, logger)
    return manager
}

func (m *Manager) GetProxy() (*models.ProxyConfig, error) {
    m.mutex.RLock()
    defer m.mutex.RUnlock()
    
    if len(m.proxies) == 0 {
        return nil, fmt.Errorf("no proxies available")
    }
    
    // Find next healthy proxy
    for i := 0; i < len(m.proxies); i++ {
        proxy := &m.proxies[(m.current+i)%len(m.proxies)]
        if proxy.IsHealthy {
            m.current = (m.current + i + 1) % len(m.proxies)
            return proxy, nil
        }
    }
    
    return nil, fmt.Errorf("no healthy proxies available")
}

func (m *Manager) RotateProxy() (*models.ProxyConfig, error) {
    m.mutex.Lock()
    defer m.mutex.Unlock()
    
    m.current = (m.current + 1) % len(m.proxies)
    return m.GetProxy()
}

func (m *Manager) MarkUnhealthy(proxyURL string) {
    m.mutex.Lock()
    defer m.mutex.Unlock()
    
    for i := range m.proxies {
        if m.proxies[i].URL == proxyURL {
            m.proxies[i].IsHealthy = false
            m.proxies[i].LastFailure = time.Now()
            m.logger.Warn("Marked proxy as unhealthy", map[string]interface{}{
                "proxy": proxyURL,
            })
            break
        }
    }
}

func (m *Manager) StartHealthChecking(ctx context.Context, interval time.Duration) {
    go m.healthChecker.Start(ctx, interval)
}

func (m *Manager) FormatProxyURL(proxy *models.ProxyConfig) string {
    if proxy.Username != "" && proxy.Password != "" {
        return fmt.Sprintf("%s://%s:%s@%s:%d", 
            proxy.Type, proxy.Username, proxy.Password, proxy.Host, proxy.Port)
    }
    return fmt.Sprintf("%s://%s:%d", proxy.Type, proxy.Host, proxy.Port)
}

func (m *Manager) ValidateProxy(proxy *models.ProxyConfig) error {
    if proxy.Host == "" {
        return fmt.Errorf("proxy host is required")
    }
    
    if proxy.Port <= 0 || proxy.Port > 65535 {
        return fmt.Errorf("invalid proxy port: %d", proxy.Port)
    }
    
    validTypes := map[string]bool{
        "http":   true,
        "https":  true,
        "socks5": true,
    }
    
    if !validTypes[proxy.Type] {
        return fmt.Errorf("unsupported proxy type: %s", proxy.Type)
    }
    
    return nil
}
```

### 6. Queue Management (queue/manager.go)

```go
package queue

import (
    "context"
    "sync"
    "time"
    
    "walmart-bot/internal/logging"
    "walmart-bot/pkg/models"
)

type Manager struct {
    taskQueue    chan models.Task
    workers      []*Worker
    workerPool   chan chan models.Task
    maxWorkers   int
    rateLimiter  *RateLimiter
    logger       *logging.Logger
    mutex        sync.RWMutex
}

type RateLimiter struct {
    requests    chan struct{}
    ticker      *time.Ticker
    maxRequests int
    interval    time.Duration
}

func NewManager(maxWorkers int, queueSize int, logger *logging.Logger) *Manager {
    manager := &Manager{
        taskQueue:   make(chan models.Task, queueSize),
        workerPool:  make(chan chan models.Task, maxWorkers),
        maxWorkers:  maxWorkers,
        logger:      logger,
        rateLimiter: NewRateLimiter(10, time.Minute), // 10 requests per minute
    }
    
    // Initialize workers
    for i := 0; i < maxWorkers; i++ {
        worker := NewWorker(i, manager.workerPool, logger)
        manager.workers = append(manager.workers, worker)
    }
    
    return manager
}

func NewRateLimiter(maxRequests int, interval time.Duration) *RateLimiter {
    rl := &RateLimiter{
        requests:    make(chan struct{}, maxRequests),
        maxRequests: maxRequests,
        interval:    interval,
    }
    
    // Fill the initial bucket
    for i := 0; i < maxRequests; i++ {
        rl.requests <- struct{}{}
    }
    
    // Start refill ticker
    rl.ticker = time.NewTicker(interval / time.Duration(maxRequests))
    go rl.refill()
    
    return rl
}

func (rl *RateLimiter) refill() {
    for range rl.ticker.C {
        select {
        case rl.requests <- struct{}{}:
        default:
            // Channel is full, skip
        }
    }
}

func (rl *RateLimiter) Wait() {
    <-rl.requests
}

func (m *Manager) Start(ctx context.Context) {
    // Start all workers
    for _, worker := range m.workers {
        worker.Start(ctx)
    }
    
    // Start dispatcher
    go m.dispatch(ctx)
    
    m.logger.Info("Queue manager started", map[string]interface{}{
        "workers": m.maxWorkers,
    })
}

func (m *Manager) dispatch(ctx context.Context) {
    for {
        select {
        case task := <-m.taskQueue:
            // Wait for rate limit
            m.rateLimiter.Wait()
            
            // Get available worker
            select {
            case workerTaskQueue := <-m.workerPool:
                workerTaskQueue <- task
            case <-ctx.Done():
                return
            }
            
        case <-ctx.Done():
            return
        }
    }
}

func (m *Manager) AddTask(task models.Task) error {
    select {
    case m.taskQueue <- task:
        m.logger.Debug("Task added to queue", map[string]interface{}{
            "taskID":   task.ID,
            "taskType": task.Type,
        })
        return nil
    default:
        return fmt.Errorf("task queue is full")
    }
}

func (m *Manager) GetQueueStatus() models.QueueStatus {
    m.mutex.RLock()
    defer m.mutex.RUnlock()
    
    activeWorkers := 0
    for _, worker := range m.workers {
        if worker.IsActive() {
            activeWorkers++
        }
    }
    
    return models.QueueStatus{
        QueueSize:     len(m.taskQueue),
        ActiveWorkers: activeWorkers,
        TotalWorkers:  m.maxWorkers,
    }
}
```

### 7. Checkout Management (checkout/cart.go)

```go
package checkout

import (
    "context"
    "fmt"
    "time"
    
    "walmart-bot/internal/session"
    "walmart-bot/internal/tlsclient"
    "walmart-bot/pkg/models"
)

type CartManager struct {
    tlsClient      *tlsclient.TLSClient
    sessionManager *session.Manager
    baseURL        string
}

func NewCartManager(tlsClient *tlsclient.TLSClient, sessionManager *session.Manager) *CartManager {
    return &CartManager{
        tlsClient:      tlsClient,
        sessionManager: sessionManager,
        baseURL:        "https://www.walmart.com/api",
    }
}

func (cm *CartManager) AddToCart(ctx context.Context, sessionID string, item models.CartItem) error {
    session, err := cm.sessionManager.GetSession(sessionID)
    if err != nil {
        return fmt.Errorf("failed to get session: %w", err)
    }
    
    headers := map[string]string{
        "Authorization":    fmt.Sprintf("Bearer %s", session.Token),
        "Content-Type":     "application/json",
        "X-Requested-With": "XMLHttpRequest",
    }
    
    requestBody := fmt.Sprintf(`{
        "itemId": "%s",
        "quantity": %d,
        "sellerId": "%s"
    }`, item.ItemID, item.Quantity, item.SellerID)
    
    config := tlsclient.RequestConfig{
        Method:  "POST",
        URL:     fmt.Sprintf("%s/cart/add", cm.baseURL),
        Headers: headers,
        Data:    requestBody,
    }
    
    resp, err := cm.tlsClient.MakeRequest(config)
    if err != nil {
        return fmt.Errorf("failed to add item to cart: %w", err)
    }
    
    if resp.StatusCode != 200 {
        return fmt.Errorf("failed to add item to cart: status %d", resp.StatusCode)
    }
    
    return nil
}

func (cm *CartManager) GetCart(ctx context.Context, sessionID string) (*models.Cart, error) {
    session, err := cm.sessionManager.GetSession(sessionID)
    if err != nil {
        return nil, fmt.Errorf("failed to get session: %w", err)
    }
    
    headers := map[string]string{
        "Authorization": fmt.Sprintf("Bearer %s", session.Token),
    }
    
    config := tlsclient.RequestConfig{
        Method:  "GET",
        URL:     fmt.Sprintf("%s/cart", cm.baseURL),
        Headers: headers,
    }
    
    resp, err := cm.tlsClient.MakeRequest(config)
    if err != nil {
        return nil, fmt.Errorf("failed to get cart: %w", err)
    }
    
    var cart models.Cart
    if err := json.Unmarshal([]byte(resp.Body), &cart); err != nil {
        return nil, fmt.Errorf("failed to parse cart response: %w", err)
    }
    
    return &cart, nil
}

func (cm *CartManager) UpdateQuantity(ctx context.Context, sessionID string, itemID string, quantity int) error {
    session, err := cm.sessionManager.GetSession(sessionID)
    if err != nil {
        return fmt.Errorf("failed to get session: %w", err)
    }
    
    headers := map[string]string{
        "Authorization": fmt.Sprintf("Bearer %s", session.Token),
        "Content-Type":  "application/json",
    }
    
    requestBody := fmt.Sprintf(`{
        "itemId": "%s",
        "quantity": %d
    }`, itemID, quantity)
    
    config := tlsclient.RequestConfig{
        Method:  "PUT",
        URL:     fmt.Sprintf("%s/cart/item/%s", cm.baseURL, itemID),
        Headers: headers,
        Data:    requestBody,
    }
    
    resp, err := cm.tlsClient.MakeRequest(config)
    if err != nil {
        return fmt.Errorf("failed to update cart item: %w", err)
    }
    
    if resp.StatusCode != 200 {
        return fmt.Errorf("failed to update cart item: status %d", resp.StatusCode)
    }
    
    return nil
}

func (cm *CartManager) ClearCart(ctx context.Context, sessionID string) error {
    session, err := cm.sessionManager.GetSession(sessionID)
    if err != nil {
        return fmt.Errorf("failed to get session: %w", err)
    }
    
    headers := map[string]string{
        "Authorization": fmt.Sprintf("Bearer %s", session.Token),
    }
    
    config := tlsclient.RequestConfig{
        Method:  "DELETE",
        URL:     fmt.Sprintf("%s/cart/clear", cm.baseURL),
        Headers: headers,
    }
    
    resp, err := cm.tlsClient.MakeRequest(config)
    if err != nil {
        return fmt.Errorf("failed to clear cart: %w", err)
    }
    
    if resp.StatusCode != 200 {
        return fmt.Errorf("failed to clear cart: status %d", resp.StatusCode)
    }
    
    return nil
}
```

### 8. Discord Logging (logging/discord.go)

```go
package logging

import (
    "bytes"
    "encoding/json"
    "fmt"
    "net/http"
    "time"
)

type DiscordLogger struct {
    webhookURL string
    client     *http.Client
}

type DiscordMessage struct {
    Content string           `json:"content,omitempty"`
    Embeds  []DiscordEmbed   `json:"embeds,omitempty"`
}

type DiscordEmbed struct {
    Title       string              `json:"title,omitempty"`
    Description string              `json:"description,omitempty"`
    Color       int                 `json:"color,omitempty"`
    Fields      []DiscordEmbedField `json:"fields,omitempty"`
    Timestamp   string              `json:"timestamp,omitempty"`
}

type DiscordEmbedField struct {
    Name   string `json:"name"`
    Value  string `json:"value"`
    Inline bool   `json:"inline,omitempty"`
}

const (
    ColorSuccess = 0x00ff00 // Green
    ColorWarning = 0xffff00 // Yellow  
    ColorError   = 0xff0000 // Red
    ColorInfo    = 0x0099ff // Blue
)

func NewDiscordLogger(webhookURL string) *DiscordLogger {
    return &DiscordLogger{
        webhookURL: webhookURL,
        client: &http.Client{
            Timeout: 10 * time.Second,
        },
    }
}

func (dl *DiscordLogger) LogCheckoutSuccess(orderID, email string, total float64, items []string) error {
    embed := DiscordEmbed{
        Title:       "✅ Checkout Successful",
        Description: fmt.Sprintf("Order completed successfully for %s", email),
        Color:       ColorSuccess,
        Timestamp:   time.Now().Format(time.RFC3339),
        Fields: []DiscordEmbedField{
            {
                Name:   "Order ID",
                Value:  orderID,
                Inline: true,
            },
            {
                Name:   "Total",
                Value:  fmt.Sprintf("$%.2f", total),
                Inline: true,
            },
            {
                Name:   "Items",
                Value:  fmt.Sprintf("%d items", len(items)),
                Inline: true,
            },
        },
    }
    
    if len(items) > 0 && len(items) <= 5 {
        itemsList := ""
        for _, item := range items {
            itemsList += fmt.Sprintf("• %s\n", item)
        }
        embed.Fields = append(embed.Fields, DiscordEmbedField{
            Name:   "Product Details",
            Value:  itemsList,
            Inline: false,
        })
    }
    
    return dl.sendMessage(DiscordMessage{Embeds: []DiscordEmbed{embed}})
}

func (dl *DiscordLogger) LogCheckoutFailure(email, reason string, retryCount int) error {
    embed := DiscordEmbed{
        Title:       "❌ Checkout Failed",
        Description: fmt.Sprintf("Checkout failed for %s", email),
        Color:       ColorError,
        Timestamp:   time.Now().Format(time.RFC3339),
        Fields: []DiscordEmbedField{
            {
                Name:   "Reason",
                Value:  reason,
                Inline: false,
            },
            {
                Name:   "Retry Count",
                Value:  fmt.Sprintf("%d", retryCount),
                Inline: true,
            },
        },
    }
    
    return dl.sendMessage(DiscordMessage{Embeds: []DiscordEmbed{embed}})
}

func (dl *DiscordLogger) LogLoginAttempt(email string, success bool, requiresOTP bool) error {
    var title, color string
    if success {
        if requiresOTP {
            title = "🔐 Login Successful (OTP Required)"
            color = ColorWarning
        } else {
            title = "✅ Login Successful"
            color = ColorSuccess
        }
    } else {
        title = "❌ Login Failed"
        color = ColorError
    }
    
    embed := DiscordEmbed{
        Title:     title,
        Color:     color,
        Timestamp: time.Now().Format(time.RFC3339),
        Fields: []DiscordEmbedField{
            {
                Name:   "Email",
                Value:  email,
                Inline: true,
            },
        },
    }
    
    if requiresOTP {
        embed.Fields = append(embed.Fields, DiscordEmbedField{
            Name:   "Status",
            Value:  "Waiting for OTP verification",
            Inline: true,
        })
    }
    
    return dl.sendMessage(DiscordMessage{Embeds: []DiscordEmbed{embed}})
}

func (dl *DiscordLogger) LogSystemStatus(status string, details map[string]interface{}) error {
    embed := DiscordEmbed{
        Title:     "🔧 System Status Update",
        Color:     ColorInfo,
        Timestamp: time.Now().Format(time.RFC3339),
        Fields: []DiscordEmbedField{
            {
                Name:   "Status",
                Value:  status,
                Inline: false,
            },
        },
    }
    
    for key, value := range details {
        embed.Fields = append(embed.Fields, DiscordEmbedField{
            Name:   key,
            Value:  fmt.Sprintf("%v", value),
            Inline: true,
        })
    }
    
    return dl.sendMessage(DiscordMessage{Embeds: []DiscordEmbed{embed}})
}

func (dl *DiscordLogger) sendMessage(message DiscordMessage) error {
    jsonData, err := json.Marshal(message)
    if err != nil {
        return fmt.Errorf("failed to marshal discord message: %w", err)
    }
    
    resp, err := dl.client.Post(dl.webhookURL, "application/json", bytes.NewBuffer(jsonData))
    if err != nil {
        return fmt.Errorf("failed to send discord message: %w", err)
    }
    defer resp.Body.Close()
    
    if resp.StatusCode < 200 || resp.StatusCode >= 300 {
        return fmt.Errorf("discord webhook returned status %d", resp.StatusCode)
    }
    
    return nil
}
```

### 9. Python TLS Bridge (python/tls_bridge.py)

```python
import json
import tls_client
from typing import Dict, Optional, Any

class TLSClientBridge:
    def __init__(self):
        self.session = None
        self._init_session()
    
    def _init_session(self):
        """Initialize TLS client with Chrome 120 fingerprint"""
        self.session = tls_client.Session(
            client_identifier="chrome_120",
            random_tls_extension_order=True
        )
        
        # Set Chrome 120 specific headers
        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
            "Sec-Ch-Ua": '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
            "Sec-Ch-Ua-Mobile": "?0",
            "Sec-Ch-Ua-Platform": '"Windows"',
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-User": "?1",
            "Upgrade-Insecure-Requests": "1"
        })

    def make_request(self, method: str, url: str, headers: Optional[Dict] = None, 
                    data: Optional[str] = None, proxy: Optional[str] = None) -> Dict[str, Any]:
        """Make HTTP request with TLS fingerprinting"""
        try:
            # Update headers if provided
            if headers:
                request_headers = self.session.headers.copy()
                request_headers.update(json.loads(headers) if isinstance(headers, str) else headers)
            else:
                request_headers = self.session.headers
            
            # Set proxy if provided
            if proxy:
                self.session.proxies = {
                    "http": proxy,
                    "https": proxy
                }
            
            # Make request
            response = self.session.request(
                method=method.upper(),
                url=url,
                headers=request_headers,
                data=data,
                timeout=30
            )
            
            # Extract cookies
            cookies = {}
            for cookie in self.session.cookies:
                cookies[cookie.name] = cookie.value
            
            # Return response data
            return {
                "status_code": response.status_code,
                "headers": dict(response.headers),
                "body": response.text,
                "cookies": cookies,
                "url": response.url
            }
            
        except Exception as e:
            return {
                "error": str(e),
                "status_code": 0,
                "headers": {},
                "body": "",
                "cookies": {}
            }

# Global client instance
_client = None

def init_tls_client():
    """Initialize TLS client - called from Go"""
    global _client
    _client = TLSClientBridge()
    return _client

def make_request(method: str, url: str, headers: str = "", 
                data: str = "", proxy: str = "") -> str:
    """Make request - called from Go"""
    global _client
    if _client is None:
        _client = TLSClientBridge()
    
    result = _client.make_request(
        method=method,
        url=url,
        headers=headers if headers else None,
        data=data if data else None,
        proxy=proxy if proxy else None
    )
    
    return json.dumps(result)

def cleanup():
    """Cleanup resources"""
    global _client
    if _client and _client.session:
        _client.session.close()
    _client = None
```

### 10. Main Application Entry (cmd/main.go)

```go
package main

import (
    "context"
    "log"
    "os"
    "os/signal"
    "syscall"
    "time"
    
    "walmart-bot/internal/auth"
    "walmart-bot/internal/checkout"
    "walmart-bot/internal/config"
    "walmart-bot/internal/logging"
    "walmart-bot/internal/proxy"
    "walmart-bot/internal/queue"
    "walmart-bot/internal/session"
    "walmart-bot/internal/tlsclient"
)

func main() {
    // Load configuration
    cfg, err := config.Load()
    if err != nil {
        log.Fatalf("Failed to load config: %v", err)
    }
    
    // Initialize logger
    logger := logging.NewLogger(cfg.Discord.WebhookURL)
    
    // Initialize TLS client
    tlsClient, err := tlsclient.NewTLSClient()
    if err != nil {
        log.Fatalf("Failed to initialize TLS client: %v", err)
    }
    defer tlsClient.Close()
    
    // Initialize proxy manager
    proxyManager := proxy.NewManager(cfg.Proxies, logger)
    
    // Initialize session manager
    sessionManager := session.NewManager(cfg.Session.StoragePath, logger)
    
    // Initialize GraphQL client
    graphqlClient := auth.NewGraphQLClient(tlsClient)
    
    // Initialize auth manager
    authManager := auth.NewAuthManager(graphqlClient, sessionManager, logger)
    
    // Initialize checkout components
    cartManager := checkout.NewCartManager(tlsClient, sessionManager)
    paymentManager := checkout.NewPaymentManager(tlsClient, sessionManager, logger)
    orderManager := checkout.NewOrderManager(tlsClient, sessionManager, logger)
    
    // Initialize queue manager
    queueManager := queue.NewManager(cfg.Queue.MaxWorkers, cfg.Queue.QueueSize, logger)
    
    // Create context for graceful shutdown
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    
    // Start services
    queueManager.Start(ctx)
    proxyManager.StartHealthChecking(ctx, 5*time.Minute)
    
    // Start API server (if needed)
    // go startAPIServer(ctx, cfg, authManager, cartManager, paymentManager, orderManager, queueManager)
    
    logger.LogSystemStatus("System Started", map[string]interface{}{
        "workers": cfg.Queue.MaxWorkers,
        "proxies": len(cfg.Proxies),
    })
    
    // Wait for interrupt signal
    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
    
    <-sigChan
    logger.LogSystemStatus("System Shutting Down", map[string]interface{}{
        "reason": "interrupt signal received",
    })
    
    cancel()
    
    // Give services time to shutdown gracefully
    time.Sleep(5 * time.Second)
    
    logger.LogSystemStatus("System Stopped", map[string]interface{}{
        "status": "clean shutdown completed",
    })
}
```

## Key Integration Points

### 1. **Python-Go Bridge Communication**
- Uses CGO to embed Python interpreter
- Python tls-client handles TLS fingerprinting
- Go manages business logic and concurrency
- Shared memory for efficient data exchange

### 2. **GraphQL Authentication Flow**
- Structured queries for Walmart's identity service
- Automatic OTP handling with callback support
- Token refresh mechanism
- Session persistence with cookie management

### 3. **Proxy Management**
- Health checking with automatic failover
- Support for HTTP/HTTPS/SOCKS5 protocols
- Request routing through healthy proxies
- Automatic rotation on failures

### 4. **Concurrency Management**
- Worker pool pattern for parallel operations
- Rate limiting to prevent detection
- Queue-based task distribution
- Graceful shutdown handling

### 5. **Logging and Monitoring**
- Discord webhooks for real-time notifications
- Request/response replay capability
- Performance metrics collection
- Error tracking and alerting

This architecture provides a robust, scalable foundation for Walmart automation with proper separation of concerns, error handling, and monitoring capabilities.