package tlsclient

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	stdhttp "net/http"

	http "github.com/bogdanfinn/fhttp"
	tls_client "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

// Client wraps the tls-client with Chrome 120 fingerprint
type Client struct {
	client                 tls_client.HttpClient
	mu                     sync.Mutex
	remoteEnabled          bool
	remoteBaseURL          string
	remoteAuthToken        string
	remoteClientIdentifier string
	httpClient             *stdhttp.Client
}

// Session represents an authenticated session
type Session struct {
	client         *Client
	tlsClient      tls_client.HttpClient
	proxy          *Proxy
	cookies        map[string]string
	authenticated  bool
	authToken      string
	mu             sync.Mutex
	lastRequestTime time.Time
	rateLimitMs     int64
	pxHeaders       map[string]string
	remote          bool
	remoteSessionID string
}

// Proxy configuration
type Proxy struct {
	URL      string
	Username string
	Password string
	Failed   bool
}

// Response wraps HTTP response
type Response struct {
	StatusCode int
	Body       string
	Headers    http.Header
	Cookies    map[string]string
}

// Global configuration toggles (managed by app layer)
var (
	globalRateLimitMs int64 = 0
	minRateLimitMs    int64 = 1
	maxRateLimitMs    int64 = 50000
	captureRequests   int32 // 0 false, 1 true
	defaultUserAgent  atomic.Value // string

	// Timing randomization controls
	globalRandomizeTimings int32
	globalMinDelayRandMs   int64
	globalMaxDelayRandMs   int64
)

func init() {
	defaultUserAgent.Store("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
	rand.Seed(time.Now().UnixNano())
}

// SetGlobalRateLimitMs sets the global inter-request delay in milliseconds (clamped to [1, 50000])
func SetGlobalRateLimitMs(ms int) {
	if ms <= 0 {
		atomic.StoreInt64(&globalRateLimitMs, 0)
		return
	}
	v := int64(ms)
	if v < minRateLimitMs {
		v = minRateLimitMs
	}
	if v > maxRateLimitMs {
		v = maxRateLimitMs
	}
	atomic.StoreInt64(&globalRateLimitMs, v)
}

// SetGlobalTimingRandomization enables randomized per-request delays between minMs and maxMs
func SetGlobalTimingRandomization(minMs, maxMs int, enable bool) {
	if minMs < 1 { minMs = 1 }
	if maxMs < minMs { maxMs = minMs }
	atomic.StoreInt64(&globalMinDelayRandMs, int64(minMs))
	atomic.StoreInt64(&globalMaxDelayRandMs, int64(maxMs))
	if enable {
		atomic.StoreInt32(&globalRandomizeTimings, 1)
	} else {
		atomic.StoreInt32(&globalRandomizeTimings, 0)
	}
}

// GetGlobalRateLimitMs returns the current global delay in ms (0 means disabled)
func GetGlobalRateLimitMs() int {
	return int(atomic.LoadInt64(&globalRateLimitMs))
}

// SetCaptureRequests toggles raw request/response capture
func SetCaptureRequests(enabled bool) {
	if enabled {
		atomic.StoreInt32(&captureRequests, 1)
	} else {
		atomic.StoreInt32(&captureRequests, 0)
	}
}

// SetDefaultUserAgent overrides the default UA used in requests (falls back to Chrome 120 UA)
func SetDefaultUserAgent(ua string) {
	if strings.TrimSpace(ua) == "" {
		return
	}
	defaultUserAgent.Store(ua)
}

// NewClient creates a new TLS client with Chrome 120 fingerprint
func NewClient() (*Client, error) {
	// Create the TLS client with Chrome 120 profile
	options := []tls_client.HttpClientOption{
		tls_client.WithTimeoutSeconds(30),
		tls_client.WithClientProfile(profiles.Chrome_120),
		tls_client.WithRandomTLSExtensionOrder(),
		tls_client.WithNotFollowRedirects(),
	}

	client, err := tls_client.NewHttpClient(tls_client.NewNoopLogger(), options...)
	if err != nil {
		return nil, fmt.Errorf("failed to create TLS client: %w", err)
	}

	return &Client{
		client: client,
	}, nil
}

// NewRemoteClient creates a client that proxies requests through ParallaxSystems TLS-Client API
func NewRemoteClient(baseURL, authToken, clientIdentifier string) (*Client, error) {
	if strings.TrimSpace(baseURL) == "" {
		baseURL = "https://api.parallaxsystems.io"
	}
	baseURL = strings.TrimRight(baseURL, "/")
	if strings.TrimSpace(clientIdentifier) == "" {
		clientIdentifier = "chrome_133"
	}
	return &Client{
		remoteEnabled:          true,
		remoteBaseURL:          baseURL,
		remoteAuthToken:        authToken,
		remoteClientIdentifier: clientIdentifier,
		httpClient: &stdhttp.Client{Timeout: 30 * time.Second},
	}, nil
}

// NewSession creates a new session with optional proxy
func (c *Client) NewSession(proxy *Proxy) *Session {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Use remote TLS-Client API
	if c.remoteEnabled {
		sID, err := c.remoteInitSession(proxy)
		if err != nil {
			return nil
		}
		return &Session{
			client:         c,
			cookies:        make(map[string]string),
			pxHeaders:      make(map[string]string),
			remote:         true,
			remoteSessionID: sID,
		}
	}

	// Create session-specific client (local)
	options := []tls_client.HttpClientOption{
		tls_client.WithTimeoutSeconds(30),
		tls_client.WithClientProfile(profiles.Chrome_120),
		tls_client.WithRandomTLSExtensionOrder(),
		tls_client.WithCookieJar(tls_client.NewCookieJar()),
	}

	// Add proxy if provided
	if proxy != nil && !proxy.Failed {
		proxyURL := proxy.URL
		if proxy.Username != "" {
			proxyURL = fmt.Sprintf("http://%s:%s@%s", proxy.Username, proxy.Password, strings.TrimPrefix(proxy.URL, "http://"))
		}
		options = append(options, tls_client.WithProxyUrl(proxyURL))
	}

	sessionClient, err := tls_client.NewHttpClient(tls_client.NewNoopLogger(), options...)
	if err != nil {
		return nil
	}

	return &Session{
		client:    c,
		tlsClient: sessionClient,
		proxy:     proxy,
		cookies:   make(map[string]string),
		pxHeaders: make(map[string]string),
	}
}

// Request performs an HTTP request with TLS fingerprinting
func (s *Session) Request(method, url string, headers map[string]string, body string) (*Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Compute delay: per-session override > randomization > global fixed
	delayMs := s.rateLimitMs
	if delayMs <= 0 {
		if atomic.LoadInt32(&globalRandomizeTimings) == 1 {
			min := atomic.LoadInt64(&globalMinDelayRandMs)
			max := atomic.LoadInt64(&globalMaxDelayRandMs)
			if max < min { max = min }
			delta := max - min + 1
			if delta <= 0 { delta = 1 }
			delayMs = min + rand.Int63n(delta)
		} else {
			delayMs = atomic.LoadInt64(&globalRateLimitMs)
		}
	}
	if delayMs > 0 {
		now := time.Now()
		if !s.lastRequestTime.IsZero() {
			elapsed := now.Sub(s.lastRequestTime)
			delay := time.Duration(delayMs) * time.Millisecond
			if elapsed < delay {
				// Add small jitter
				jitter := time.Duration(rand.Intn(75)) * time.Millisecond
				time.Sleep(delay - elapsed + jitter)
			}
		}
		s.lastRequestTime = time.Now()
	}

	// Remote path
	if s.remote {
		finalHeaders := map[string]string{
			"User-Agent":      defaultUserAgent.Load().(string),
			"Accept":          "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
			"Accept-Language": "en-US,en;q=0.5",
			"Accept-Encoding": "gzip, deflate, br",
			"DNT":             "1",
			"Connection":      "keep-alive",
			"Upgrade-Insecure-Requests": "1",
			"Sec-Fetch-Dest":  "document",
			"Sec-Fetch-Mode":  "navigate",
			"Sec-Fetch-Site":  "none",
			"Sec-Fetch-User":  "?1",
			"Cache-Control":   "max-age=0",
		}
		for k, v := range headers { finalHeaders[k] = v }
		if s.authToken != "" { finalHeaders["Authorization"] = fmt.Sprintf("Bearer %s", s.authToken) }
		for k, v := range s.pxHeaders { if v != "" { finalHeaders[k] = v } }
		// Ensure Cookie header
		if _, ok := finalHeaders["Cookie"]; !ok && len(s.cookies) > 0 {
			var b strings.Builder
			first := true
			for name, val := range s.cookies {
				if !first { b.WriteString("; ") } else { first = false }
				b.WriteString(name)
				b.WriteString("=")
				b.WriteString(val)
			}
			finalHeaders["Cookie"] = b.String()
		}
		return s.remoteForward(method, url, finalHeaders, body)
	}

	// Local path: Create request
	var bodyReader io.Reader
	if body != "" {
		bodyReader = strings.NewReader(body)
	}

	req, err := http.NewRequest(method, url, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	// Set default headers for Chrome 120
	req.Header.Set("User-Agent", defaultUserAgent.Load().(string))
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8")
	req.Header.Set("Accept-Language", "en-US,en;q=0.5")
	req.Header.Set("Accept-Encoding", "gzip, deflate, br")
	req.Header.Set("DNT", "1")
	req.Header.Set("Connection", "keep-alive")
	req.Header.Set("Upgrade-Insecure-Requests", "1")
	req.Header.Set("Sec-Fetch-Dest", "document")
	req.Header.Set("Sec-Fetch-Mode", "navigate")
	req.Header.Set("Sec-Fetch-Site", "none")
	req.Header.Set("Sec-Fetch-User", "?1")
	req.Header.Set("Cache-Control", "max-age=0")

	// Apply custom headers
	for key, value := range headers {
		req.Header.Set(key, value)
	}

	// Add auth token if authenticated
	if s.authToken != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", s.authToken))
	}

	// Attach PX headers if any
	for k, v := range s.pxHeaders {
		if v != "" {
			req.Header.Set(k, v)
		}
	}

	// Attach session cookies explicitly (in addition to cookie jar)
	if len(s.cookies) > 0 && req.Header.Get("Cookie") == "" {
		var b strings.Builder
		first := true
		for name, val := range s.cookies {
			if !first { b.WriteString("; ") } else { first = false }
			b.WriteString(name)
			b.WriteString("=")
			b.WriteString(val)
		}
		req.Header.Set("Cookie", b.String())
	}

	// Perform request
	resp, err := s.tlsClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	// Read response body
	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Extract cookies
	cookies := make(map[string]string)
	for _, cookie := range resp.Cookies() {
		cookies[cookie.Name] = cookie.Value
		s.cookies[cookie.Name] = cookie.Value
	}

	r := &Response{
		StatusCode: resp.StatusCode,
		Body:       string(bodyBytes),
		Headers:    resp.Header,
		Cookies:    cookies,
	}

	if atomic.LoadInt32(&captureRequests) == 1 {
		fmt.Printf("[tlsclient] %s %s -> %d\n", method, url, r.StatusCode)
	}

	return r, nil
}

// Get performs a GET request
func (s *Session) Get(url string, headers map[string]string) (*Response, error) {
	return s.Request("GET", url, headers, "")
}

// Post performs a POST request
func (s *Session) Post(url string, headers map[string]string, data string) (*Response, error) {
	return s.Request("POST", url, headers, data)
}

// PostJSON performs a POST request with JSON data
func (s *Session) PostJSON(url string, headers map[string]string, data interface{}) (*Response, error) {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal JSON: %w", err)
	}

	if headers == nil {
		headers = make(map[string]string)
	}
	headers["Content-Type"] = "application/json"

	return s.Post(url, headers, string(jsonData))
}

// IsAuthenticated returns whether the session is authenticated
func (s *Session) IsAuthenticated() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.authenticated
}

// SetAuthenticated marks the session as authenticated
func (s *Session) SetAuthenticated(auth bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.authenticated = auth
}

// SetAuthToken sets the authentication token
func (s *Session) SetAuthToken(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.authToken = token
}

// GetAuthToken returns the authentication token
func (s *Session) GetAuthToken() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.authToken
}

// GetCookies returns the current session cookies
func (s *Session) GetCookies() map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	cookies := make(map[string]string)
	for k, v := range s.cookies {
		cookies[k] = v
	}
	return cookies
}

// SaveToFile persists session cookies and token to disk
func (s *Session) SaveToFile(path string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if strings.TrimSpace(path) == "" { return fmt.Errorf("empty path") }
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	payload := struct {
		AuthToken string            `json:"authToken"`
		Cookies   map[string]string `json:"cookies"`
	}{
		AuthToken: s.authToken,
		Cookies:   s.cookies,
	}
	b, _ := json.MarshalIndent(payload, "", "  ")
	return os.WriteFile(path, b, 0o600)
}

// LoadFromFile loads session cookies and token from disk
func (s *Session) LoadFromFile(path string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if strings.TrimSpace(path) == "" { return fmt.Errorf("empty path") }
	b, err := os.ReadFile(path)
	if err != nil { return err }
	var payload struct {
		AuthToken string            `json:"authToken"`
		Cookies   map[string]string `json:"cookies"`
	}
	if err := json.Unmarshal(b, &payload); err != nil { return err }
	if payload.Cookies != nil {
		if s.cookies == nil { s.cookies = make(map[string]string) }
		for k, v := range payload.Cookies { s.cookies[k] = v }
	}
	s.authToken = payload.AuthToken
	if s.authToken != "" { s.authenticated = true }
	return nil
}

// Close cleans up the session
func (s *Session) Close() {
	if s.tlsClient != nil {
		s.tlsClient.CloseIdleConnections()
	}
}

// Close cleans up the client
func (c *Client) Close() {
	if c.client != nil {
		c.client.CloseIdleConnections()
	}
}

// SetRateLimitMs sets a per-session delay that overrides the global one (0 disables per-session override)
func (s *Session) SetRateLimitMs(ms int) {
	if ms <= 0 {
		s.rateLimitMs = 0
		return
	}
	v := int64(ms)
	if v < minRateLimitMs { v = minRateLimitMs }
	if v > maxRateLimitMs { v = maxRateLimitMs }
	s.rateLimitMs = v
}

// AddPXHeader adds a header to be included in every request (e.g., PX-related headers)
func (s *Session) AddPXHeader(key, value string) {
	if s.pxHeaders == nil { s.pxHeaders = make(map[string]string) }
	s.pxHeaders[key] = value
}

// AddPXCookie stores a PX-related cookie for subsequent requests
func (s *Session) AddPXCookie(name, value string) {
	if s.cookies == nil { s.cookies = make(map[string]string) }
	s.cookies[name] = value
}

// remoteInitSession initializes a new remote TLS session
func (c *Client) remoteInitSession(p *Proxy) (string, error) {
	if !c.remoteEnabled { return "", fmt.Errorf("remote not enabled") }
	payload := map[string]interface{}{
		"tlsClientIdentifier": c.remoteClientIdentifier,
		"withRandomTLSExtensionOrder": true,
		"followRedirects": false,
	}
	if p != nil && !p.Failed {
		proxyURL := p.URL
		if p.Username != "" {
			u := proxyURL
			if strings.Contains(u, "://") && !strings.Contains(u, "@") {
				parts := strings.SplitN(u, "://", 2)
				u = parts[0] + "://" + p.Username + ":" + p.Password + "@" + parts[1]
			}
			proxyURL = u
		}
		payload["proxyUrl"] = proxyURL
	}
	b, _ := json.Marshal(payload)
	req, _ := stdhttp.NewRequest("POST", c.remoteBaseURL+"/init", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-auth-token", c.remoteAuthToken)
	resp, err := c.httpClient.Do(req)
	if err != nil { return "", err }
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("remote /init status %d", resp.StatusCode)
	}
	var out struct { Success bool `json:"success"`; SessionID string `json:"sessionId"` }
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil { return "", err }
	if !out.Success || out.SessionID == "" { return "", fmt.Errorf("remote init failed") }
	return out.SessionID, nil
}

// remoteForward forwards a request via the remote TLS client
func (s *Session) remoteForward(method, url string, headers map[string]string, body string) (*Response, error) {
	c := s.client
	if c == nil || !c.remoteEnabled { return nil, fmt.Errorf("remote not enabled") }
	// Convert headers map to ordered pairs; start with common order
	order := []string{"Content-Type","User-Agent","Accept","Accept-Language","Origin","Referer","Cookie"}
	pairs := make([][2]string, 0, len(headers))
	seen := make(map[string]bool)
	for _, k := range order {
		if v, ok := headers[k]; ok {
			pairs = append(pairs, [2]string{k, v})
			seen[k] = true
		}
	}
	for k, v := range headers {
		if !seen[k] {
			pairs = append(pairs, [2]string{k, v})
		}
	}
	payload := map[string]interface{}{
		"sessionId": s.remoteSessionID,
		"uri":       url,
		"method":    method,
		"body":      body,
		"headers":   pairs,
	}
	b, _ := json.Marshal(payload)
	req, _ := stdhttp.NewRequest("POST", c.remoteBaseURL+"/forward", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-auth-token", c.remoteAuthToken)
	resp, err := c.httpClient.Do(req)
	if err != nil { return nil, err }
	defer resp.Body.Close()
	var out struct {
		Status  int               `json:"status"`
		Body    string            `json:"body"`
		Headers map[string][]string `json:"headers"`
		Cookies map[string]string `json:"cookies"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil { return nil, err }
	if out.Cookies != nil {
		for k, v := range out.Cookies { s.cookies[k] = v }
	}
	// Build http.Header
	h := http.Header{}
	for k, vs := range out.Headers { for _, v := range vs { h.Add(k, v) } }
	return &Response{ StatusCode: out.Status, Body: out.Body, Headers: h, Cookies: s.cookies }, nil
}