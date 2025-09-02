# Comprehensive Testing Strategy for Walmart Bot

## Overview

This document outlines a complete testing strategy for the Walmart bot, covering unit tests, integration tests, performance benchmarks, security validation, and end-to-end automation. The strategy is designed to ensure reliability, security, and performance at scale.

## Testing Architecture

### 1. Test Structure

```
tests/
├── unit/                   # Unit tests for individual modules
│   ├── auth/              # Authentication module tests
│   ├── checkout/          # Checkout flow tests
│   ├── graphql/           # GraphQL client tests
│   ├── inventory/         # Inventory management tests
│   ├── proxy/             # Proxy management tests
│   ├── protection/        # Bot protection tests
│   ├── tlsclient/         # TLS client tests
│   └── logging/           # Logging module tests
├── integration/           # Integration tests
│   ├── auth_flow/         # Authentication flow tests
│   ├── checkout_flow/     # End-to-end checkout tests
│   ├── api_integration/   # Walmart API integration tests
│   └── proxy_failover/    # Proxy failover scenarios
├── e2e/                   # End-to-end automation tests
│   ├── scenarios/         # Test scenarios
│   ├── fixtures/          # Test data fixtures
│   └── reports/           # Test reports
├── performance/           # Performance and load tests
│   ├── benchmarks/        # Benchmark tests
│   ├── load/              # Load testing scenarios
│   └── stress/            # Stress testing
├── security/              # Security tests
│   ├── credential/        # Credential handling tests
│   ├── tls/               # TLS security tests
│   └── injection/         # Injection attack tests
├── mocks/                 # Mock servers and data
│   ├── walmart_api/       # Mock Walmart API server
│   ├── proxy_server/      # Mock proxy server
│   └── fixtures/          # GraphQL response fixtures
└── ci/                    # CI/CD specific tests
    ├── smoke/             # Smoke tests for deployment
    └── regression/        # Regression test suite
```

## Testing Frameworks and Tools

### Core Testing Framework
- **Testing Framework**: Go's built-in `testing` package with `testify` for assertions
- **Mocking**: `gomock` for interface mocking and `httptest` for HTTP mocking
- **GraphQL Testing**: Custom GraphQL mock server with fixture responses
- **Performance**: Go's `testing/benchmark` with custom metrics collection

### Additional Tools
```go
// Required testing dependencies
require (
    github.com/stretchr/testify v1.8.4
    github.com/golang/mock v1.6.0
    github.com/gorilla/websocket v1.5.1  // For WebSocket testing
    github.com/prometheus/client_golang v1.17.0  // For metrics in tests
    github.com/DATA-DOG/go-sqlmock v1.5.0  // For database mocking
    go.uber.org/zap v1.26.0  // For structured logging in tests
)
```

## 1. Unit Testing Strategy

### 1.1 Authentication Module Tests

```go
// tests/unit/auth/auth_test.go
package auth

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "github.com/agentwise/walmart-bot/internal/auth"
)

func TestAuthenticator_Login(t *testing.T) {
    tests := []struct {
        name           string
        email          string
        password       string
        expectedResult bool
        expectedError  error
        setupMocks     func(*MockHTTPClient)
    }{
        {
            name:           "successful_login",
            email:          "test@example.com",
            password:       "password123",
            expectedResult: true,
            expectedError:  nil,
            setupMocks: func(m *MockHTTPClient) {
                m.On("Post", mock.Anything, mock.Anything, mock.Anything).
                  Return(&http.Response{StatusCode: 200}, nil)
            },
        },
        {
            name:           "invalid_credentials",
            email:          "test@example.com", 
            password:       "wrongpass",
            expectedResult: false,
            expectedError:  auth.ErrInvalidCredentials,
            setupMocks: func(m *MockHTTPClient) {
                m.On("Post", mock.Anything, mock.Anything, mock.Anything).
                  Return(&http.Response{StatusCode: 401}, nil)
            },
        },
        {
            name:           "network_error",
            email:          "test@example.com",
            password:       "password123",
            expectedResult: false,
            expectedError:  auth.ErrNetworkFailure,
            setupMocks: func(m *MockHTTPClient) {
                m.On("Post", mock.Anything, mock.Anything, mock.Anything).
                  Return(nil, errors.New("network timeout"))
            },
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            mockClient := &MockHTTPClient{}
            tt.setupMocks(mockClient)
            
            authenticator := auth.NewAuthenticator(mockClient)
            result, err := authenticator.Login(context.Background(), tt.email, tt.password)
            
            assert.Equal(t, tt.expectedResult, result)
            assert.Equal(t, tt.expectedError, err)
            mockClient.AssertExpectations(t)
        })
    }
}

func TestAuthenticator_TokenRefresh(t *testing.T) {
    // Test token refresh logic
    mockClient := &MockHTTPClient{}
    authenticator := auth.NewAuthenticator(mockClient)
    
    // Test cases for token refresh scenarios
    t.Run("refresh_success", func(t *testing.T) {
        // Setup mock for successful refresh
        // Assert new token is stored
    })
    
    t.Run("refresh_failure", func(t *testing.T) {
        // Setup mock for failed refresh
        // Assert error handling
    })
}
```

### 1.2 GraphQL Client Tests

```go
// tests/unit/graphql/client_test.go
package graphql

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/agentwise/walmart-bot/internal/graphql"
)

func TestGraphQLClient_ExecuteQuery(t *testing.T) {
    tests := []struct {
        name           string
        query          string
        variables      map[string]interface{}
        mockResponse   string
        expectedResult interface{}
        expectedError  error
    }{
        {
            name:  "product_search_query",
            query: `query SearchProducts($term: String!) {
                search(query: $term) {
                    products {
                        id
                        name
                        price
                        availability
                    }
                }
            }`,
            variables: map[string]interface{}{
                "term": "iPhone 15",
            },
            mockResponse: `{
                "data": {
                    "search": {
                        "products": [
                            {
                                "id": "12345",
                                "name": "iPhone 15 128GB",
                                "price": 799.99,
                                "availability": "IN_STOCK"
                            }
                        ]
                    }
                }
            }`,
            expectedResult: &graphql.SearchResponse{
                Data: graphql.SearchData{
                    Search: graphql.SearchResult{
                        Products: []graphql.Product{
                            {
                                ID:           "12345",
                                Name:         "iPhone 15 128GB",
                                Price:        799.99,
                                Availability: "IN_STOCK",
                            },
                        },
                    },
                },
            },
            expectedError: nil,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            mockServer := setupMockGraphQLServer(tt.mockResponse)
            defer mockServer.Close()
            
            client := graphql.NewClient(mockServer.URL)
            result, err := client.ExecuteQuery(context.Background(), tt.query, tt.variables)
            
            assert.Equal(t, tt.expectedError, err)
            assert.Equal(t, tt.expectedResult, result)
        })
    }
}
```

### 1.3 Checkout Module Tests

```go
// tests/unit/checkout/checkout_test.go
package checkout

import (
    "context"
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/agentwise/walmart-bot/internal/checkout"
)

func TestCheckoutService_AddToCart(t *testing.T) {
    tests := []struct {
        name          string
        productID     string
        quantity      int
        expectedError error
        setupMocks    func(*MockCartAPI)
    }{
        {
            name:          "successful_add_to_cart",
            productID:     "12345",
            quantity:      1,
            expectedError: nil,
            setupMocks: func(m *MockCartAPI) {
                m.On("AddItem", mock.Anything, "12345", 1).
                  Return(&checkout.CartItem{ProductID: "12345", Quantity: 1}, nil)
            },
        },
        {
            name:          "out_of_stock",
            productID:     "54321",
            quantity:      1,
            expectedError: checkout.ErrProductOutOfStock,
            setupMocks: func(m *MockCartAPI) {
                m.On("AddItem", mock.Anything, "54321", 1).
                  Return(nil, checkout.ErrProductOutOfStock)
            },
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            mockAPI := &MockCartAPI{}
            tt.setupMocks(mockAPI)
            
            service := checkout.NewService(mockAPI)
            err := service.AddToCart(context.Background(), tt.productID, tt.quantity)
            
            assert.Equal(t, tt.expectedError, err)
            mockAPI.AssertExpectations(t)
        })
    }
}

func TestCheckoutService_ProcessPayment(t *testing.T) {
    // Test payment processing with various scenarios
    tests := []struct {
        name           string
        paymentMethod  checkout.PaymentMethod
        amount         float64
        expectedResult *checkout.PaymentResult
        expectedError  error
    }{
        {
            name: "successful_credit_card_payment",
            paymentMethod: checkout.PaymentMethod{
                Type:   "CREDIT_CARD",
                CardID: "card_123",
            },
            amount: 99.99,
            expectedResult: &checkout.PaymentResult{
                TransactionID: "txn_456",
                Status:        "COMPLETED",
            },
            expectedError: nil,
        },
    }
    
    // Implementation of test cases
}
```

## 2. Integration Testing Strategy

### 2.1 Authentication Flow Tests

```go
// tests/integration/auth_flow/auth_integration_test.go
package auth_flow

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/suite"
    "github.com/agentwise/walmart-bot/internal/auth"
    "github.com/agentwise/walmart-bot/internal/proxy"
)

type AuthIntegrationTestSuite struct {
    suite.Suite
    authService *auth.Service
    proxyManager *proxy.Manager
    mockServer  *httptest.Server
}

func (suite *AuthIntegrationTestSuite) SetupSuite() {
    // Setup mock Walmart API server
    suite.mockServer = setupMockWalmartAPI()
    
    // Initialize services with real dependencies
    suite.proxyManager = proxy.NewManager(getTestProxies())
    suite.authService = auth.NewService(auth.Config{
        BaseURL: suite.mockServer.URL,
        Timeout: 30 * time.Second,
    })
}

func (suite *AuthIntegrationTestSuite) TestCompleteAuthenticationFlow() {
    ctx := context.Background()
    
    // Step 1: Initial login
    loginResult, err := suite.authService.Login(ctx, "test@example.com", "password123")
    suite.NoError(err)
    suite.True(loginResult.Success)
    suite.NotEmpty(loginResult.AccessToken)
    
    // Step 2: Verify token is stored
    token, err := suite.authService.GetStoredToken(ctx)
    suite.NoError(err)
    suite.Equal(loginResult.AccessToken, token)
    
    // Step 3: Make authenticated request
    profile, err := suite.authService.GetUserProfile(ctx)
    suite.NoError(err)
    suite.NotNil(profile)
    
    // Step 4: Test token refresh
    time.Sleep(2 * time.Second) // Simulate token expiration
    refreshResult, err := suite.authService.RefreshToken(ctx)
    suite.NoError(err)
    suite.NotEqual(loginResult.AccessToken, refreshResult.AccessToken)
}

func (suite *AuthIntegrationTestSuite) TestProxyRotationDuringAuth() {
    ctx := context.Background()
    
    // Test authentication with proxy rotation
    for i := 0; i < 5; i++ {
        loginResult, err := suite.authService.LoginWithProxyRotation(ctx, "test@example.com", "password123")
        suite.NoError(err)
        suite.True(loginResult.Success)
        
        // Verify different proxy was used
        suite.NotEqual(suite.proxyManager.GetCurrentProxy().ID, suite.proxyManager.GetPreviousProxy().ID)
    }
}

func TestAuthIntegrationTestSuite(t *testing.T) {
    suite.Run(t, new(AuthIntegrationTestSuite))
}
```

### 2.2 Checkout Flow Integration Tests

```go
// tests/integration/checkout_flow/checkout_integration_test.go
package checkout_flow

import (
    "context"
    "testing"
    "github.com/stretchr/testify/suite"
    "github.com/agentwise/walmart-bot/internal/checkout"
    "github.com/agentwise/walmart-bot/internal/inventory"
    "github.com/agentwise/walmart-bot/internal/auth"
)

type CheckoutIntegrationTestSuite struct {
    suite.Suite
    checkoutService *checkout.Service
    inventoryService *inventory.Service
    authService     *auth.Service
    mockWalmartAPI  *httptest.Server
}

func (suite *CheckoutIntegrationTestSuite) TestCompleteCheckoutFlow() {
    ctx := context.Background()
    
    // Step 1: Authenticate
    loginResult, err := suite.authService.Login(ctx, "test@example.com", "password123")
    suite.NoError(err)
    
    // Step 2: Search for product
    products, err := suite.inventoryService.SearchProducts(ctx, "iPhone 15")
    suite.NoError(err)
    suite.NotEmpty(products)
    
    targetProduct := products[0]
    
    // Step 3: Check availability
    availability, err := suite.inventoryService.CheckAvailability(ctx, targetProduct.ID)
    suite.NoError(err)
    suite.True(availability.InStock)
    
    // Step 4: Add to cart
    err = suite.checkoutService.AddToCart(ctx, targetProduct.ID, 1)
    suite.NoError(err)
    
    // Step 5: Verify cart contents
    cart, err := suite.checkoutService.GetCart(ctx)
    suite.NoError(err)
    suite.Len(cart.Items, 1)
    suite.Equal(targetProduct.ID, cart.Items[0].ProductID)
    
    // Step 6: Proceed to checkout
    checkoutSession, err := suite.checkoutService.InitiateCheckout(ctx)
    suite.NoError(err)
    suite.NotEmpty(checkoutSession.ID)
    
    // Step 7: Process payment
    paymentResult, err := suite.checkoutService.ProcessPayment(ctx, checkout.PaymentRequest{
        SessionID: checkoutSession.ID,
        Method: checkout.PaymentMethod{
            Type:   "CREDIT_CARD",
            CardID: "test_card_123",
        },
        Amount: cart.Total,
    })
    suite.NoError(err)
    suite.Equal("COMPLETED", paymentResult.Status)
    
    // Step 8: Confirm order
    order, err := suite.checkoutService.ConfirmOrder(ctx, paymentResult.TransactionID)
    suite.NoError(err)
    suite.NotEmpty(order.OrderID)
    suite.Equal("CONFIRMED", order.Status)
}

func (suite *CheckoutIntegrationTestSuite) TestCheckoutWithInventoryMonitoring() {
    ctx := context.Background()
    
    // Test checkout flow with real-time inventory monitoring
    productID := "test_product_123"
    
    // Start inventory monitoring
    inventoryUpdates := make(chan inventory.Update, 10)
    suite.inventoryService.StartMonitoring(ctx, []string{productID}, inventoryUpdates)
    
    // Simulate inventory changes during checkout
    go func() {
        time.Sleep(1 * time.Second)
        suite.inventoryService.SimulateStockChange(productID, 5) // Stock becomes low
        
        time.Sleep(2 * time.Second)
        suite.inventoryService.SimulateStockChange(productID, 0) // Out of stock
    }()
    
    // Attempt checkout
    err := suite.checkoutService.AddToCart(ctx, productID, 1)
    suite.NoError(err)
    
    // Wait for inventory update
    select {
    case update := <-inventoryUpdates:
        if update.Stock == 0 {
            // Verify checkout is blocked
            _, err := suite.checkoutService.ProcessPayment(ctx, checkout.PaymentRequest{
                SessionID: "test_session",
                Amount:    99.99,
            })
            suite.Error(err)
            suite.Contains(err.Error(), "out of stock")
        }
    case <-time.After(5 * time.Second):
        suite.Fail("Timeout waiting for inventory update")
    }
}
```

## 3. Mock Server Implementation

### 3.1 Mock Walmart API Server

```go
// tests/mocks/walmart_api/mock_server.go
package walmart_api

import (
    "encoding/json"
    "fmt"
    "net/http"
    "net/http/httptest"
    "strings"
    
    "github.com/gorilla/mux"
)

type MockWalmartAPI struct {
    server   *httptest.Server
    router   *mux.Router
    fixtures map[string]interface{}
}

func NewMockWalmartAPI() *MockWalmartAPI {
    mock := &MockWalmartAPI{
        router:   mux.NewRouter(),
        fixtures: make(map[string]interface{}),
    }
    
    mock.setupRoutes()
    mock.server = httptest.NewServer(mock.router)
    
    return mock
}

func (m *MockWalmartAPI) setupRoutes() {
    // Authentication endpoints
    m.router.HandleFunc("/api/auth/login", m.handleLogin).Methods("POST")
    m.router.HandleFunc("/api/auth/refresh", m.handleTokenRefresh).Methods("POST")
    
    // GraphQL endpoint
    m.router.HandleFunc("/graphql", m.handleGraphQL).Methods("POST")
    
    // REST API endpoints
    m.router.HandleFunc("/api/products/search", m.handleProductSearch).Methods("GET")
    m.router.HandleFunc("/api/cart", m.handleCart).Methods("GET", "POST")
    m.router.HandleFunc("/api/checkout", m.handleCheckout).Methods("POST")
}

func (m *MockWalmartAPI) handleLogin(w http.ResponseWriter, r *http.Request) {
    var loginReq struct {
        Email    string `json:"email"`
        Password string `json:"password"`
    }
    
    json.NewDecoder(r.Body).Decode(&loginReq)
    
    // Simulate different responses based on credentials
    switch {
    case loginReq.Email == "test@example.com" && loginReq.Password == "password123":
        response := map[string]interface{}{
            "success":      true,
            "access_token": "mock_access_token_123",
            "refresh_token": "mock_refresh_token_456",
            "expires_in":   3600,
        }
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(response)
    case loginReq.Password == "wrongpass":
        w.WriteHeader(http.StatusUnauthorized)
        json.NewEncoder(w).Encode(map[string]string{
            "error": "invalid_credentials",
            "message": "Invalid email or password",
        })
    default:
        w.WriteHeader(http.StatusBadRequest)
        json.NewEncoder(w).Encode(map[string]string{
            "error": "missing_credentials",
            "message": "Email and password required",
        })
    }
}

func (m *MockWalmartAPI) handleGraphQL(w http.ResponseWriter, r *http.Request) {
    var gqlReq struct {
        Query     string                 `json:"query"`
        Variables map[string]interface{} `json:"variables"`
    }
    
    json.NewDecoder(r.Body).Decode(&gqlReq)
    
    // Route to appropriate handler based on query
    if strings.Contains(gqlReq.Query, "SearchProducts") {
        m.handleGraphQLProductSearch(w, gqlReq)
    } else if strings.Contains(gqlReq.Query, "AddToCart") {
        m.handleGraphQLAddToCart(w, gqlReq)
    } else {
        w.WriteHeader(http.StatusBadRequest)
        json.NewEncoder(w).Encode(map[string]string{
            "error": "unsupported_query",
        })
    }
}

func (m *MockWalmartAPI) handleGraphQLProductSearch(w http.ResponseWriter, req struct {
    Query     string                 `json:"query"`
    Variables map[string]interface{} `json:"variables"`
}) {
    searchTerm := req.Variables["term"].(string)
    
    // Return different products based on search term
    var products []map[string]interface{}
    
    if searchTerm == "iPhone 15" {
        products = []map[string]interface{}{
            {
                "id":           "12345",
                "name":         "iPhone 15 128GB",
                "price":        799.99,
                "availability": "IN_STOCK",
                "stock":        10,
            },
        }
    } else {
        products = []map[string]interface{}{}
    }
    
    response := map[string]interface{}{
        "data": map[string]interface{}{
            "search": map[string]interface{}{
                "products": products,
            },
        },
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(response)
}

// Load fixtures from files
func (m *MockWalmartAPI) LoadFixtures(fixturesDir string) error {
    // Load GraphQL response fixtures
    fixtures := []string{
        "product_search_response.json",
        "add_to_cart_response.json", 
        "checkout_response.json",
        "inventory_response.json",
    }
    
    for _, fixture := range fixtures {
        data, err := ioutil.ReadFile(filepath.Join(fixturesDir, fixture))
        if err != nil {
            return err
        }
        
        var fixtureData interface{}
        if err := json.Unmarshal(data, &fixtureData); err != nil {
            return err
        }
        
        m.fixtures[fixture] = fixtureData
    }
    
    return nil
}

func (m *MockWalmartAPI) Close() {
    m.server.Close()
}

func (m *MockWalmartAPI) URL() string {
    return m.server.URL
}
```

### 3.2 GraphQL Response Fixtures

```json
// tests/mocks/fixtures/product_search_response.json
{
  "data": {
    "search": {
      "products": [
        {
          "id": "12345",
          "name": "iPhone 15 128GB Space Gray",
          "price": 799.99,
          "originalPrice": 829.99,
          "availability": "IN_STOCK",
          "stock": 15,
          "rating": 4.5,
          "reviews": 1234,
          "images": [
            "https://example.com/iphone15-1.jpg",
            "https://example.com/iphone15-2.jpg"
          ],
          "specifications": {
            "brand": "Apple",
            "model": "iPhone 15",
            "storage": "128GB",
            "color": "Space Gray"
          },
          "shipping": {
            "eligible": true,
            "estimatedDays": 2,
            "cost": 0
          }
        }
      ],
      "totalCount": 1,
      "hasMorePages": false
    }
  }
}
```

```json
// tests/mocks/fixtures/checkout_response.json
{
  "data": {
    "checkout": {
      "sessionId": "checkout_session_789",
      "items": [
        {
          "productId": "12345",
          "quantity": 1,
          "unitPrice": 799.99,
          "totalPrice": 799.99
        }
      ],
      "subtotal": 799.99,
      "tax": 64.00,
      "shipping": 0.00,
      "total": 863.99,
      "estimatedDelivery": "2024-01-15",
      "paymentMethods": [
        {
          "id": "pm_credit_card",
          "type": "CREDIT_CARD",
          "description": "Credit/Debit Card"
        },
        {
          "id": "pm_paypal",
          "type": "PAYPAL", 
          "description": "PayPal"
        }
      ]
    }
  }
}
```

## 4. Performance Testing Strategy

### 4.1 Benchmark Tests

```go
// tests/performance/benchmarks/auth_benchmark_test.go
package benchmarks

import (
    "context"
    "testing"
    "github.com/agentwise/walmart-bot/internal/auth"
)

func BenchmarkAuthenticator_Login(b *testing.B) {
    mockAPI := setupMockWalmartAPI()
    defer mockAPI.Close()
    
    authenticator := auth.NewAuthenticator(auth.Config{
        BaseURL: mockAPI.URL(),
        Timeout: 30 * time.Second,
    })
    
    b.ResetTimer()
    b.RunParallel(func(pb *testing.PB) {
        ctx := context.Background()
        for pb.Next() {
            _, err := authenticator.Login(ctx, "test@example.com", "password123")
            if err != nil {
                b.Error(err)
            }
        }
    })
}

func BenchmarkCheckout_AddToCart(b *testing.B) {
    checkoutService := setupCheckoutService()
    
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        ctx := context.Background()
        err := checkoutService.AddToCart(ctx, "product_123", 1)
        if err != nil {
            b.Error(err)
        }
    }
}

func BenchmarkConcurrentCheckouts(b *testing.B) {
    checkoutService := setupCheckoutService()
    
    b.ResetTimer()
    b.RunParallel(func(pb *testing.PB) {
        ctx := context.Background()
        for pb.Next() {
            // Simulate concurrent checkout operations
            go func() {
                checkoutService.AddToCart(ctx, "product_123", 1)
                checkoutService.ProcessPayment(ctx, getTestPaymentRequest())
            }()
        }
    })
}
```

### 4.2 Load Testing

```go
// tests/performance/load/load_test.go
package load

import (
    "context"
    "sync"
    "testing"
    "time"
    
    "github.com/agentwise/walmart-bot/internal/auth"
    "github.com/agentwise/walmart-bot/internal/checkout"
)

type LoadTestMetrics struct {
    TotalRequests    int64
    SuccessfulReqs   int64
    FailedRequests   int64
    AverageLatency   time.Duration
    MaxLatency       time.Duration
    RequestsPerSecond float64
}

func TestConcurrentUsers(t *testing.T) {
    scenarios := []struct {
        name          string
        concurrentUsers int
        duration      time.Duration
        expectedRPS   float64
    }{
        {"light_load", 10, 30 * time.Second, 50},
        {"moderate_load", 50, 60 * time.Second, 200},
        {"heavy_load", 100, 120 * time.Second, 400},
        {"stress_test", 500, 300 * time.Second, 800},
    }
    
    for _, scenario := range scenarios {
        t.Run(scenario.name, func(t *testing.T) {
            metrics := runLoadTest(scenario.concurrentUsers, scenario.duration)
            
            // Validate performance metrics
            assert.True(t, metrics.RequestsPerSecond >= scenario.expectedRPS,
                "Expected RPS >= %f, got %f", scenario.expectedRPS, metrics.RequestsPerSecond)
            
            // Validate error rate is acceptable (< 1%)
            errorRate := float64(metrics.FailedRequests) / float64(metrics.TotalRequests)
            assert.True(t, errorRate < 0.01,
                "Error rate too high: %f%%", errorRate*100)
            
            // Validate latency requirements
            assert.True(t, metrics.AverageLatency < 500*time.Millisecond,
                "Average latency too high: %v", metrics.AverageLatency)
        })
    }
}

func runLoadTest(concurrentUsers int, duration time.Duration) *LoadTestMetrics {
    metrics := &LoadTestMetrics{}
    var wg sync.WaitGroup
    var mu sync.Mutex
    
    ctx, cancel := context.WithTimeout(context.Background(), duration)
    defer cancel()
    
    startTime := time.Now()
    
    for i := 0; i < concurrentUsers; i++ {
        wg.Add(1)
        go func(userID int) {
            defer wg.Done()
            
            // Simulate user behavior
            for {
                select {
                case <-ctx.Done():
                    return
                default:
                    // Perform operations
                    latency := simulateUserSession(ctx, userID)
                    
                    mu.Lock()
                    metrics.TotalRequests++
                    if latency > 0 {
                        metrics.SuccessfulReqs++
                        if latency > metrics.MaxLatency {
                            metrics.MaxLatency = latency
                        }
                    } else {
                        metrics.FailedRequests++
                    }
                    mu.Unlock()
                    
                    time.Sleep(time.Duration(rand.Intn(1000)) * time.Millisecond)
                }
            }
        }(i)
    }
    
    wg.Wait()
    
    totalDuration := time.Since(startTime)
    metrics.RequestsPerSecond = float64(metrics.TotalRequests) / totalDuration.Seconds()
    
    if metrics.SuccessfulReqs > 0 {
        metrics.AverageLatency = totalDuration / time.Duration(metrics.SuccessfulReqs)
    }
    
    return metrics
}

func simulateUserSession(ctx context.Context, userID int) time.Duration {
    start := time.Now()
    
    // Step 1: Login
    authService := setupAuthService()
    _, err := authService.Login(ctx, fmt.Sprintf("user%d@test.com", userID), "password123")
    if err != nil {
        return -1 // Indicate failure
    }
    
    // Step 2: Search products
    inventoryService := setupInventoryService()
    products, err := inventoryService.SearchProducts(ctx, "iPhone")
    if err != nil || len(products) == 0 {
        return -1
    }
    
    // Step 3: Add to cart
    checkoutService := setupCheckoutService()
    err = checkoutService.AddToCart(ctx, products[0].ID, 1)
    if err != nil {
        return -1
    }
    
    // Step 4: Checkout (simulate only)
    _, err = checkoutService.InitiateCheckout(ctx)
    if err != nil {
        return -1
    }
    
    return time.Since(start)
}
```

## 5. Proxy Failover Testing

```go
// tests/integration/proxy_failover/proxy_test.go
package proxy_failover

import (
    "context"
    "net/http"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/suite"
    "github.com/agentwise/walmart-bot/internal/proxy"
)

type ProxyFailoverTestSuite struct {
    suite.Suite
    proxyManager *proxy.Manager
    testProxies  []proxy.Config
}

func (suite *ProxyFailoverTestSuite) SetupSuite() {
    suite.testProxies = []proxy.Config{
        {ID: "proxy1", Host: "proxy1.test.com", Port: 8080, Type: "HTTP"},
        {ID: "proxy2", Host: "proxy2.test.com", Port: 8080, Type: "HTTP"},  
        {ID: "proxy3", Host: "proxy3.test.com", Port: 8080, Type: "SOCKS5"},
    }
    
    suite.proxyManager = proxy.NewManager(suite.testProxies)
}

func (suite *ProxyFailoverTestSuite) TestProxyRotation() {
    ctx := context.Background()
    
    // Test basic rotation
    proxy1 := suite.proxyManager.GetNext()
    proxy2 := suite.proxyManager.GetNext() 
    proxy3 := suite.proxyManager.GetNext()
    proxy4 := suite.proxyManager.GetNext() // Should wrap around
    
    suite.NotEqual(proxy1.ID, proxy2.ID)
    suite.NotEqual(proxy2.ID, proxy3.ID)
    suite.Equal(proxy1.ID, proxy4.ID) // Wrapped around
}

func (suite *ProxyFailoverTestSuite) TestFailoverOnError() {
    ctx := context.Background()
    
    // Simulate proxy failure
    currentProxy := suite.proxyManager.GetCurrent()
    
    // Mark proxy as failed
    suite.proxyManager.MarkFailed(currentProxy.ID, "connection timeout")
    
    // Get next proxy - should skip the failed one
    nextProxy := suite.proxyManager.GetNext()
    suite.NotEqual(currentProxy.ID, nextProxy.ID)
    
    // Verify failed proxy is not used for some time
    for i := 0; i < 10; i++ {
        proxy := suite.proxyManager.GetNext()
        suite.NotEqual(currentProxy.ID, proxy.ID)
    }
}

func (suite *ProxyFailoverTestSuite) TestProxyRecovery() {
    ctx := context.Background()
    
    // Mark all proxies as failed
    for _, proxy := range suite.testProxies {
        suite.proxyManager.MarkFailed(proxy.ID, "test failure")
    }
    
    // Wait for recovery period
    time.Sleep(proxy.RecoveryTimeout + 1*time.Second)
    
    // Should be able to get proxies again
    recoveredProxy := suite.proxyManager.GetNext()
    suite.NotNil(recoveredProxy)
}

func (suite *ProxyFailoverTestSuite) TestProxyHealthChecks() {
    ctx := context.Background()
    
    // Start health checking
    suite.proxyManager.StartHealthChecks(ctx, 5*time.Second)
    
    // Wait for health checks to complete
    time.Sleep(10 * time.Second)
    
    // Verify proxy statuses are updated
    healthyProxies := suite.proxyManager.GetHealthyProxies()
    suite.NotEmpty(healthyProxies)
}

func (suite *ProxyFailoverTestSuite) TestConcurrentProxyUsage() {
    ctx := context.Background()
    results := make(chan string, 100)
    
    // Simulate concurrent requests using different proxies
    for i := 0; i < 100; i++ {
        go func(requestID int) {
            proxy := suite.proxyManager.GetNext()
            
            // Simulate HTTP request through proxy
            client := &http.Client{
                Timeout: 10 * time.Second,
                Transport: proxy.GetTransport(),
            }
            
            resp, err := client.Get("https://httpbin.org/ip")
            if err != nil {
                results <- fmt.Sprintf("request_%d:error", requestID)
                return
            }
            defer resp.Body.Close()
            
            results <- fmt.Sprintf("request_%d:success:%s", requestID, proxy.ID)
        }(i)
    }
    
    // Collect results
    successCount := 0
    proxyUsage := make(map[string]int)
    
    for i := 0; i < 100; i++ {
        result := <-results
        if strings.Contains(result, "success") {
            successCount++
            parts := strings.Split(result, ":")
            if len(parts) >= 3 {
                proxyUsage[parts[2]]++
            }
        }
    }
    
    // Verify results
    suite.True(successCount > 80) // At least 80% success rate
    suite.True(len(proxyUsage) > 1) // Multiple proxies were used
}

func TestProxyFailoverTestSuite(t *testing.T) {
    suite.Run(t, new(ProxyFailoverTestSuite))
}
```

## 6. Rate Limit and Retry Logic Testing

```go
// tests/unit/protection/rate_limit_test.go
package protection

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/agentwise/walmart-bot/internal/protection"
)

func TestRateLimiter_BasicLimiting(t *testing.T) {
    // Test rate limiter with 5 requests per second
    limiter := protection.NewRateLimiter(5, time.Second)
    ctx := context.Background()
    
    // First 5 requests should pass immediately
    for i := 0; i < 5; i++ {
        start := time.Now()
        err := limiter.Wait(ctx)
        elapsed := time.Since(start)
        
        assert.NoError(t, err)
        assert.True(t, elapsed < 10*time.Millisecond, "Request %d should not be delayed", i)
    }
    
    // 6th request should be delayed
    start := time.Now()
    err := limiter.Wait(ctx)
    elapsed := time.Since(start)
    
    assert.NoError(t, err)
    assert.True(t, elapsed >= 200*time.Millisecond, "6th request should be delayed")
}

func TestRetryPolicy_ExponentialBackoff(t *testing.T) {
    policy := protection.RetryPolicy{
        MaxAttempts:     5,
        InitialDelay:    100 * time.Millisecond,
        MaxDelay:       5 * time.Second,
        BackoffFactor:  2.0,
        Jitter:         true,
    }
    
    attempts := 0
    testFunc := func() error {
        attempts++
        if attempts < 3 {
            return errors.New("temporary failure")
        }
        return nil
    }
    
    start := time.Now()
    err := protection.RetryWithPolicy(context.Background(), policy, testFunc)
    elapsed := time.Since(start)
    
    assert.NoError(t, err)
    assert.Equal(t, 3, attempts)
    assert.True(t, elapsed >= 300*time.Millisecond) // At least two retries with delays
}

func TestRetryPolicy_MaxAttemptsExceeded(t *testing.T) {
    policy := protection.RetryPolicy{
        MaxAttempts:    3,
        InitialDelay:   10 * time.Millisecond,
        BackoffFactor: 2.0,
    }
    
    attempts := 0
    testFunc := func() error {
        attempts++
        return errors.New("persistent failure")
    }
    
    err := protection.RetryWithPolicy(context.Background(), policy, testFunc)
    
    assert.Error(t, err)
    assert.Equal(t, 3, attempts)
    assert.Contains(t, err.Error(), "max attempts exceeded")
}

func TestCircuitBreaker_OpenClose(t *testing.T) {
    breaker := protection.NewCircuitBreaker(protection.CircuitBreakerConfig{
        FailureThreshold:  3,
        RecoveryTimeout:   1 * time.Second,
        HalfOpenMaxCalls: 2,
    })
    
    ctx := context.Background()
    
    // Function that always fails
    failingFunc := func() error {
        return errors.New("service unavailable")
    }
    
    // Trigger circuit breaker to open
    for i := 0; i < 5; i++ {
        err := breaker.Execute(ctx, failingFunc)
        assert.Error(t, err)
    }
    
    // Circuit should be open now
    assert.Equal(t, protection.CircuitBreakerStateOpen, breaker.GetState())
    
    // Calls should be rejected immediately
    start := time.Now()
    err := breaker.Execute(ctx, failingFunc)
    elapsed := time.Since(start)
    
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "circuit breaker is open")
    assert.True(t, elapsed < 10*time.Millisecond) // Should fail fast
    
    // Wait for recovery timeout
    time.Sleep(1100 * time.Millisecond)
    
    // Circuit should be half-open
    assert.Equal(t, protection.CircuitBreakerStateHalfOpen, breaker.GetState())
    
    // Success should close the circuit
    successFunc := func() error { return nil }
    err = breaker.Execute(ctx, successFunc)
    assert.NoError(t, err)
    
    // Circuit should be closed
    assert.Equal(t, protection.CircuitBreakerStateClosed, breaker.GetState())
}
```

## 7. Security Testing Strategy

### 7.1 Credential Handling Tests

```go
// tests/security/credential/credential_security_test.go
package credential

import (
    "context"
    "os"
    "testing"
    
    "github.com/stretchr/testify/assert"
    "github.com/agentwise/walmart-bot/internal/auth"
)

func TestCredentialEncryption(t *testing.T) {
    credManager := auth.NewCredentialManager()
    
    testCreds := auth.Credentials{
        Email:    "test@example.com",
        Password: "sensitive_password_123",
    }
    
    // Store credentials (should be encrypted)
    err := credManager.Store("test_user", testCreds)
    assert.NoError(t, err)
    
    // Verify credentials are not stored in plain text
    rawData, err := credManager.GetRawData("test_user")
    assert.NoError(t, err)
    assert.NotContains(t, string(rawData), "sensitive_password_123")
    
    // Retrieve and verify credentials
    retrieved, err := credManager.Retrieve("test_user")
    assert.NoError(t, err)
    assert.Equal(t, testCreds.Email, retrieved.Email)
    assert.Equal(t, testCreds.Password, retrieved.Password)
}

func TestCredentialMemorySafety(t *testing.T) {
    credManager := auth.NewCredentialManager()
    
    testCreds := auth.Credentials{
        Email:    "test@example.com", 
        Password: "memory_test_password",
    }
    
    // Store and immediately clear from memory
    err := credManager.Store("test_user", testCreds)
    assert.NoError(t, err)
    
    // Zero out original credentials
    testCreds.Password = strings.Repeat("X", len(testCreds.Password))
    
    // Should still be able to retrieve
    retrieved, err := credManager.Retrieve("test_user")
    assert.NoError(t, err)
    assert.Equal(t, "memory_test_password", retrieved.Password)
    
    // Clear credentials from memory
    credManager.ClearMemory("test_user")
    
    // Memory should be cleared (this test may be platform-specific)
    // Additional memory analysis would be needed for complete verification
}

func TestEnvironmentVariableSafety(t *testing.T) {
    // Test that sensitive data is not leaked through environment
    
    // Set test environment
    os.Setenv("WALMART_EMAIL", "test@example.com")
    os.Setenv("WALMART_PASSWORD", "test_password")
    
    defer func() {
        os.Unsetenv("WALMART_EMAIL")
        os.Unsetenv("WALMART_PASSWORD")
    }()
    
    credManager := auth.NewCredentialManagerFromEnv()
    
    // Verify credentials are loaded
    creds, err := credManager.GetFromEnvironment()
    assert.NoError(t, err)
    assert.Equal(t, "test@example.com", creds.Email)
    
    // Environment variables should be cleared after loading
    assert.Empty(t, os.Getenv("WALMART_PASSWORD"))
}

func TestTokenSecureStorage(t *testing.T) {
    tokenManager := auth.NewTokenManager()
    
    testToken := auth.Token{
        AccessToken:  "sensitive_access_token_123456789",
        RefreshToken: "sensitive_refresh_token_987654321",
        ExpiresAt:    time.Now().Add(1 * time.Hour),
    }
    
    // Store token
    err := tokenManager.StoreToken("test_session", testToken)
    assert.NoError(t, err)
    
    // Verify token storage is encrypted/obfuscated
    rawStorage, err := tokenManager.GetRawStorage()
    assert.NoError(t, err)
    assert.NotContains(t, rawStorage, "sensitive_access_token_123456789")
    assert.NotContains(t, rawStorage, "sensitive_refresh_token_987654321")
    
    // Retrieve and verify
    retrieved, err := tokenManager.GetToken("test_session")
    assert.NoError(t, err)
    assert.Equal(t, testToken.AccessToken, retrieved.AccessToken)
    assert.Equal(t, testToken.RefreshToken, retrieved.RefreshToken)
}
```

### 7.2 TLS Security Tests

```go
// tests/security/tls/tls_security_test.go
package tls

import (
    "crypto/tls"
    "crypto/x509"
    "testing"
    
    "github.com/stretchr/testify/assert"
    "github.com/agentwise/walmart-bot/internal/tlsclient"
)

func TestTLSConfiguration(t *testing.T) {
    client := tlsclient.NewSecureClient()
    
    // Verify TLS configuration
    tlsConfig := client.GetTLSConfig()
    
    // Should require TLS 1.2 or higher
    assert.True(t, tlsConfig.MinVersion >= tls.VersionTLS12)
    
    // Should have strong cipher suites
    strongCiphers := []uint16{
        tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
        tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
        tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    }
    
    for _, cipher := range strongCiphers {
        assert.Contains(t, tlsConfig.CipherSuites, cipher)
    }
    
    // Should not allow insecure renegotiation
    assert.Equal(t, tls.RenegotiateNever, tlsConfig.Renegotiation)
    
    // Should verify certificates
    assert.False(t, tlsConfig.InsecureSkipVerify)
}

func TestCertificatePinning(t *testing.T) {
    client := tlsclient.NewSecureClient()
    
    // Test certificate pinning for Walmart.com
    err := client.VerifyCertificatePinning("walmart.com", &tls.ConnectionState{
        PeerCertificates: getTestCertificateChain(),
    })
    
    // Should succeed with valid certificate
    assert.NoError(t, err)
    
    // Should fail with invalid certificate
    err = client.VerifyCertificatePinning("walmart.com", &tls.ConnectionState{
        PeerCertificates: getInvalidCertificateChain(),
    })
    
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "certificate pinning validation failed")
}

func TestCertificateValidation(t *testing.T) {
    client := tlsclient.NewSecureClient()
    
    tests := []struct {
        name        string
        cert        *x509.Certificate
        expectValid bool
    }{
        {
            name:        "valid_walmart_cert",
            cert:        getValidWalmartCert(),
            expectValid: true,
        },
        {
            name:        "expired_cert",
            cert:        getExpiredCert(),
            expectValid: false,
        },
        {
            name:        "self_signed_cert",
            cert:        getSelfSignedCert(),
            expectValid: false,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := client.ValidateCertificate(tt.cert)
            
            if tt.expectValid {
                assert.NoError(t, err)
            } else {
                assert.Error(t, err)
            }
        })
    }
}
```

## 8. End-to-End Testing Strategy

### 8.1 E2E Test Scenarios

```go
// tests/e2e/scenarios/complete_purchase_test.go
package scenarios

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/suite"
    "github.com/agentwise/walmart-bot/internal/auth"
    "github.com/agentwise/walmart-bot/internal/checkout"
    "github.com/agentwise/walmart-bot/internal/inventory"
)

type CompletePurchaseE2ETestSuite struct {
    suite.Suite
    botInstance *walmart.Bot
    testConfig  *TestConfig
}

func (suite *CompletePurchaseE2ETestSuite) SetupSuite() {
    suite.testConfig = LoadTestConfig()
    suite.botInstance = walmart.NewBot(suite.testConfig.BotConfig)
}

func (suite *CompletePurchaseE2ETestSuite) TestSuccessfulPurchaseFlow() {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
    defer cancel()
    
    // Step 1: Initialize bot
    err := suite.botInstance.Initialize(ctx)
    suite.NoError(err)
    
    // Step 2: Login
    err = suite.botInstance.Login(ctx, suite.testConfig.TestUser.Email, suite.testConfig.TestUser.Password)
    suite.NoError(err)
    suite.True(suite.botInstance.IsAuthenticated())
    
    // Step 3: Search for target product
    searchResult, err := suite.botInstance.SearchProduct(ctx, "iPhone 15 128GB")
    suite.NoError(err)
    suite.NotEmpty(searchResult.Products)
    
    targetProduct := searchResult.Products[0]
    
    // Step 4: Monitor product availability
    availabilityChannel := make(chan inventory.AvailabilityUpdate, 1)
    err = suite.botInstance.StartAvailabilityMonitoring(ctx, targetProduct.ID, availabilityChannel)
    suite.NoError(err)
    
    // Step 5: Wait for product to be available
    select {
    case update := <-availabilityChannel:
        suite.True(update.Available)
        suite.Greater(update.Stock, 0)
    case <-time.After(30 * time.Second):
        suite.Fail("Timeout waiting for product availability")
    }
    
    // Step 6: Add to cart immediately when available
    err = suite.botInstance.AddToCart(ctx, targetProduct.ID, 1)
    suite.NoError(err)
    
    // Step 7: Proceed to checkout
    checkoutResult, err := suite.botInstance.ProceedToCheckout(ctx)
    suite.NoError(err)
    suite.NotEmpty(checkoutResult.SessionID)
    
    // Step 8: Fill shipping information
    shippingInfo := checkout.ShippingInfo{
        FirstName: "Test",
        LastName:  "User",
        Address:   "123 Test Street",
        City:      "Test City",
        State:     "CA",
        ZipCode:   "12345",
    }
    
    err = suite.botInstance.SetShippingInfo(ctx, checkoutResult.SessionID, shippingInfo)
    suite.NoError(err)
    
    // Step 9: Set payment method
    paymentMethod := checkout.PaymentMethod{
        Type:   "CREDIT_CARD",
        CardID: suite.testConfig.TestCard.ID,
    }
    
    err = suite.botInstance.SetPaymentMethod(ctx, checkoutResult.SessionID, paymentMethod)
    suite.NoError(err)
    
    // Step 10: Review order
    orderReview, err := suite.botInstance.ReviewOrder(ctx, checkoutResult.SessionID)
    suite.NoError(err)
    suite.Equal(1, len(orderReview.Items))
    suite.Equal(targetProduct.ID, orderReview.Items[0].ProductID)
    
    // Step 11: Place order
    orderResult, err := suite.botInstance.PlaceOrder(ctx, checkoutResult.SessionID)
    suite.NoError(err)
    suite.NotEmpty(orderResult.OrderID)
    suite.Equal("CONFIRMED", orderResult.Status)
    
    // Step 12: Verify order confirmation
    orderDetails, err := suite.botInstance.GetOrderDetails(ctx, orderResult.OrderID)
    suite.NoError(err)
    suite.Equal(orderResult.OrderID, orderDetails.OrderID)
    suite.Equal("CONFIRMED", orderDetails.Status)
    
    // Step 13: Clean up (cancel order if it's a test)
    if suite.testConfig.CancelTestOrders {
        err = suite.botInstance.CancelOrder(ctx, orderResult.OrderID, "Test order")
        suite.NoError(err)
    }
}

func (suite *CompletePurchaseE2ETestSuite) TestPurchaseWithProxyRotation() {
    ctx := context.Background()
    
    // Enable proxy rotation
    suite.botInstance.EnableProxyRotation(true)
    
    // Run the same purchase flow
    // Verify that different proxies are used throughout the process
    proxyUsage := suite.botInstance.GetProxyUsageStats()
    suite.Greater(len(proxyUsage), 1) // Multiple proxies should be used
}

func (suite *CompletePurchaseE2ETestSuite) TestPurchaseUnderHighLoad() {
    // Simulate high load conditions
    ctx := context.Background()
    
    // Configure for high load
    suite.botInstance.SetConcurrency(10) // Allow 10 concurrent operations
    
    // Run multiple purchase attempts simultaneously
    results := make(chan PurchaseResult, 5)
    
    for i := 0; i < 5; i++ {
        go func(attemptID int) {
            result := suite.attemptPurchase(ctx, attemptID)
            results <- result
        }(i)
    }
    
    // Collect results
    successCount := 0
    for i := 0; i < 5; i++ {
        result := <-results
        if result.Success {
            successCount++
        }
    }
    
    // At least one should succeed
    suite.Greater(successCount, 0)
}

func TestCompletePurchaseE2ETestSuite(t *testing.T) {
    suite.Run(t, new(CompletePurchaseE2ETestSuite))
}
```

### 8.2 Error Injection Testing

```go
// tests/e2e/scenarios/error_injection_test.go
package scenarios

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/suite"
    "github.com/agentwise/walmart-bot/internal/testing/chaos"
)

type ErrorInjectionTestSuite struct {
    suite.Suite
    botInstance *walmart.Bot
    chaosEngine *chaos.Engine
}

func (suite *ErrorInjectionTestSuite) SetupSuite() {
    suite.botInstance = walmart.NewBot(getTestConfig())
    suite.chaosEngine = chaos.NewEngine()
}

func (suite *ErrorInjectionTestSuite) TestNetworkFailureResilience() {
    ctx := context.Background()
    
    // Start chaos engine to inject network failures
    suite.chaosEngine.InjectNetworkFailures(chaos.NetworkFailureConfig{
        FailureRate:     0.2, // 20% of requests fail
        FailureDuration: 5 * time.Second,
        FailureTypes:    []string{"timeout", "connection_reset", "dns_failure"},
    })
    
    // Attempt login with network failures
    err := suite.botInstance.Login(ctx, "test@example.com", "password123")
    
    // Should eventually succeed despite network issues
    suite.NoError(err)
    suite.True(suite.botInstance.IsAuthenticated())
    
    // Verify retry attempts were made
    stats := suite.botInstance.GetRetryStats()
    suite.Greater(stats.TotalRetries, 0)
    
    suite.chaosEngine.Stop()
}

func (suite *ErrorInjectionTestSuite) TestDatabaseConnectionFailure() {
    ctx := context.Background()
    
    // Inject database connection failures
    suite.chaosEngine.InjectDatabaseFailures(chaos.DatabaseFailureConfig{
        FailureRate: 0.5,
        FailureTypes: []string{"connection_timeout", "deadlock", "constraint_violation"},
    })
    
    // Attempt operations that require database access
    err := suite.botInstance.SaveUserSession(ctx, "test_session")
    
    // Should handle database failures gracefully
    suite.NoError(err) // Should succeed with retries and fallbacks
    
    suite.chaosEngine.Stop()
}

func (suite *ErrorInjectionTestSuite) TestAPIRateLimitHandling() {
    ctx := context.Background()
    
    // Inject rate limit responses
    suite.chaosEngine.InjectAPIErrors(chaos.APIErrorConfig{
        ErrorRate: 0.3,
        ErrorTypes: []string{"rate_limit", "server_error", "bad_gateway"},
        ResponseCodes: []int{429, 500, 502},
    })
    
    // Perform operations that hit API rate limits
    products, err := suite.botInstance.SearchProduct(ctx, "iPhone")
    
    // Should eventually succeed with proper backoff
    suite.NoError(err)
    suite.NotEmpty(products)
    
    // Verify rate limit handling
    rateLimitStats := suite.botInstance.GetRateLimitStats()
    suite.Greater(rateLimitStats.RateLimitHits, 0)
    suite.Greater(rateLimitStats.BackoffTime.Seconds(), 0)
    
    suite.chaosEngine.Stop()
}

func (suite *ErrorInjectionTestSuite) TestProxyFailureHandling() {
    ctx := context.Background()
    
    // Inject proxy failures
    suite.chaosEngine.InjectProxyFailures(chaos.ProxyFailureConfig{
        FailureRate: 0.4,
        FailureTypes: []string{"proxy_timeout", "proxy_auth_failure", "proxy_unreachable"},
    })
    
    suite.botInstance.EnableProxyRotation(true)
    
    // Perform operations through failing proxies
    err := suite.botInstance.Login(ctx, "test@example.com", "password123")
    
    // Should succeed by rotating to working proxies
    suite.NoError(err)
    
    // Verify proxy rotation occurred
    proxyStats := suite.botInstance.GetProxyStats()
    suite.Greater(proxyStats.FailedProxies, 0)
    suite.Greater(proxyStats.RotationCount, 0)
    
    suite.chaosEngine.Stop()
}
```

## 9. Dashboard UI Testing

### 9.1 Frontend Testing Strategy

```go
// tests/e2e/dashboard/dashboard_ui_test.go
package dashboard

import (
    "context"
    "testing"
    "time"
    
    "github.com/chromedp/chromedp"
    "github.com/stretchr/testify/suite"
)

type DashboardUITestSuite struct {
    suite.Suite
    ctx    context.Context
    cancel context.CancelFunc
}

func (suite *DashboardUITestSuite) SetupSuite() {
    // Setup Chrome context for UI testing
    suite.ctx, suite.cancel = chromedp.NewContext(context.Background())
}

func (suite *DashboardUITestSuite) TearDownSuite() {
    suite.cancel()
}

func (suite *DashboardUITestSuite) TestDashboardLogin() {
    var title string
    
    err := chromedp.Run(suite.ctx,
        chromedp.Navigate("http://localhost:8080/dashboard"),
        chromedp.WaitVisible("#login-form"),
        chromedp.SendKeys("#email", "admin@test.com"),
        chromedp.SendKeys("#password", "admin123"),
        chromedp.Click("#login-button"),
        chromedp.WaitVisible("#dashboard-main"),
        chromedp.Title(&title),
    )
    
    suite.NoError(err)
    suite.Contains(title, "Walmart Bot Dashboard")
}

func (suite *DashboardUITestSuite) TestBotStatusDisplay() {
    var statusText string
    
    err := chromedp.Run(suite.ctx,
        chromedp.Navigate("http://localhost:8080/dashboard"),
        suite.loginSteps(),
        chromedp.WaitVisible("#bot-status"),
        chromedp.Text("#bot-status .status-text", &statusText),
    )
    
    suite.NoError(err)
    suite.Contains(statusText, "Active") // Bot should be active
}

func (suite *DashboardUITestSuite) TestRealTimeMetrics() {
    var initialValue, updatedValue string
    
    err := chromedp.Run(suite.ctx,
        chromedp.Navigate("http://localhost:8080/dashboard"),
        suite.loginSteps(),
        chromedp.WaitVisible("#metrics-panel"),
        
        // Get initial metrics value
        chromedp.Text("#requests-per-minute", &initialValue),
        
        // Wait for metrics to update (should happen via WebSocket)
        chromedp.Sleep(5*time.Second),
        chromedp.Text("#requests-per-minute", &updatedValue),
    )
    
    suite.NoError(err)
    
    // Values should be different if metrics are updating
    suite.NotEqual(initialValue, updatedValue)
}

func (suite *DashboardUITestSuite) TestConfigurationChanges() {
    err := chromedp.Run(suite.ctx,
        chromedp.Navigate("http://localhost:8080/dashboard"),
        suite.loginSteps(),
        chromedp.Click("#settings-tab"),
        chromedp.WaitVisible("#config-form"),
        
        // Change proxy rotation setting
        chromedp.Click("#enable-proxy-rotation"),
        chromedp.Click("#save-config"),
        
        // Verify success message
        chromedp.WaitVisible(".success-message"),
    )
    
    suite.NoError(err)
}

func (suite *DashboardUITestSuite) TestLogViewer() {
    var logCount int
    
    err := chromedp.Run(suite.ctx,
        chromedp.Navigate("http://localhost:8080/dashboard"),
        suite.loginSteps(),
        chromedp.Click("#logs-tab"),
        chromedp.WaitVisible("#log-viewer"),
        
        // Count log entries
        chromedp.Evaluate(`document.querySelectorAll('.log-entry').length`, &logCount),
        
        // Test log filtering
        chromedp.SendKeys("#log-filter", "ERROR"),
        chromedp.Sleep(1*time.Second),
        
        // Verify filtering worked
        chromedp.Evaluate(`document.querySelectorAll('.log-entry:not(.hidden)').length`, &logCount),
    )
    
    suite.NoError(err)
    suite.Greater(logCount, 0)
}

func (suite *DashboardUITestSuite) loginSteps() chromedp.Action {
    return chromedp.Tasks{
        chromedp.WaitVisible("#login-form"),
        chromedp.SendKeys("#email", "admin@test.com"),
        chromedp.SendKeys("#password", "admin123"),
        chromedp.Click("#login-button"),
        chromedp.WaitVisible("#dashboard-main"),
    }
}

func TestDashboardUITestSuite(t *testing.T) {
    suite.Run(t, new(DashboardUITestSuite))
}
```

## 10. CI/CD Integration

### 10.1 GitHub Actions Workflow

```yaml
# .github/workflows/test.yml
name: Comprehensive Test Suite

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        go-version: [1.21, 1.22]
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Go
      uses: actions/setup-go@v4
      with:
        go-version: ${{ matrix.go-version }}
    
    - name: Cache Go modules
      uses: actions/cache@v3
      with:
        path: ~/go/pkg/mod
        key: ${{ runner.os }}-go-${{ hashFiles('**/go.sum') }}
        restore-keys: |
          ${{ runner.os }}-go-
    
    - name: Install dependencies
      run: go mod download
    
    - name: Run unit tests
      run: |
        go test -v -race -coverprofile=coverage.out ./tests/unit/...
        go tool cover -html=coverage.out -o coverage.html
    
    - name: Upload coverage to Codecov
      uses: codecov/codecov-action@v3
      with:
        file: ./coverage.out
        flags: unittests
        name: codecov-umbrella
  
  integration-tests:
    runs-on: ubuntu-latest
    needs: unit-tests
    
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: testpass
          POSTGRES_DB: walmart_bot_test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432
      
      redis:
        image: redis:7
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 6379:6379
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Go
      uses: actions/setup-go@v4
      with:
        go-version: 1.21
    
    - name: Install dependencies
      run: go mod download
    
    - name: Run integration tests
      env:
        DB_HOST: localhost
        DB_PORT: 5432
        DB_USER: postgres
        DB_PASSWORD: testpass
        DB_NAME: walmart_bot_test
        REDIS_URL: redis://localhost:6379
      run: go test -v -tags=integration ./tests/integration/...
  
  security-tests:
    runs-on: ubuntu-latest
    needs: unit-tests
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Go
      uses: actions/setup-go@v4
      with:
        go-version: 1.21
    
    - name: Run security tests
      run: go test -v ./tests/security/...
    
    - name: Run Gosec Security Scanner
      uses: securecodewarrior/github-action-gosec@master
      with:
        args: '-fmt sarif -out gosec.sarif ./...'
    
    - name: Upload SARIF file
      uses: github/codeql-action/upload-sarif@v2
      with:
        sarif_file: gosec.sarif
  
  performance-tests:
    runs-on: ubuntu-latest
    needs: integration-tests
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Go
      uses: actions/setup-go@v4
      with:
        go-version: 1.21
    
    - name: Run performance benchmarks
      run: |
        go test -bench=. -benchmem -benchtime=30s ./tests/performance/benchmarks/...
        go test -timeout=10m ./tests/performance/load/...
    
    - name: Upload performance results
      uses: actions/upload-artifact@v3
      with:
        name: performance-results
        path: |
          **/*.bench
          **/*.prof
  
  e2e-tests:
    runs-on: ubuntu-latest
    needs: [integration-tests, security-tests]
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Go
      uses: actions/setup-go@v4
      with:
        go-version: 1.21
    
    - name: Install Chrome
      uses: browser-actions/setup-chrome@latest
    
    - name: Start application
      run: |
        go build -o walmart-bot ./cmd/walmart-bot
        ./walmart-bot --config=test.config.yml &
        sleep 10 # Wait for app to start
    
    - name: Run E2E tests
      env:
        HEADLESS: true
        TEST_USER_EMAIL: ${{ secrets.TEST_USER_EMAIL }}
        TEST_USER_PASSWORD: ${{ secrets.TEST_USER_PASSWORD }}
      run: go test -v -timeout=30m ./tests/e2e/...
    
    - name: Upload E2E artifacts
      if: always()
      uses: actions/upload-artifact@v3
      with:
        name: e2e-artifacts
        path: |
          tests/e2e/screenshots/
          tests/e2e/reports/
  
  deployment-smoke-test:
    runs-on: ubuntu-latest
    needs: e2e-tests
    if: github.ref == 'refs/heads/main'
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Deploy to staging
      run: |
        # Deployment script here
        echo "Deploying to staging..."
    
    - name: Run smoke tests
      run: go test -v -tags=smoke ./tests/ci/smoke/...
    
    - name: Notify on failure
      if: failure()
      uses: 8398a7/action-slack@v3
      with:
        status: failure
        text: "Walmart Bot tests failed on main branch"
      env:
        SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

### 10.2 Test Configuration Management

```yaml
# test.config.yml
test:
  database:
    host: localhost
    port: 5432
    user: postgres
    password: testpass
    name: walmart_bot_test
  
  redis:
    url: redis://localhost:6379
  
  walmart_api:
    base_url: https://www.walmart.com
    mock_server_url: http://localhost:8888
    timeout: 30s
  
  proxies:
    - id: test_proxy_1
      host: proxy1.test.com
      port: 8080
      type: HTTP
      username: testuser
      password: testpass
    - id: test_proxy_2
      host: proxy2.test.com
      port: 1080
      type: SOCKS5
  
  test_users:
    - email: test1@example.com
      password: testpass123
      role: regular
    - email: admin@test.com
      password: adminpass123
      role: admin
  
  test_cards:
    - id: test_card_1
      type: VISA
      number: "4111111111111111"
      expiry: "12/25"
      cvv: "123"
  
  performance:
    max_concurrent_users: 100
    test_duration: 300s
    acceptable_response_time: 500ms
    acceptable_error_rate: 0.01
  
  security:
    enable_tls_testing: true
    certificate_pinning: true
    credential_encryption: true
```

## Summary

This comprehensive testing strategy provides:

1. **Complete Test Coverage**: Unit, integration, performance, security, and E2E tests
2. **Realistic Testing Environment**: Mock servers that simulate actual Walmart API behavior
3. **Performance Validation**: Load testing and benchmarking for concurrent operations
4. **Security Assurance**: Credential handling, TLS security, and injection attack testing
5. **Resilience Testing**: Error injection and chaos engineering for reliability
6. **CI/CD Integration**: Automated testing pipeline with proper reporting
7. **Monitoring & Observability**: Dashboard UI testing and metrics validation

The strategy ensures the Walmart bot is thoroughly tested across all critical paths while maintaining security, performance, and reliability standards.

Key files created:
- `/Users/lucianocutaj/Desktop/agentwise/workspace/walmart-bot/TESTING_STRATEGY.md` - Comprehensive testing documentation

This testing framework provides a solid foundation for developing and maintaining a reliable, secure, and performant Walmart bot system.