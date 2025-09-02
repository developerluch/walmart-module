package proxy

import (
	"bufio"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/sirupsen/logrus"
)

type Proxy struct {
	URL        string
	Username   string
	Password   string
	Protocol   string // http, https, socks5
	Failed     bool
	LastUsed   time.Time
	SuccessCount int
	FailCount    int
	lastHealthAt time.Time
	lastHealthy  bool
}

type Manager struct {
	proxies      []*Proxy
	current      int
	mu           sync.RWMutex
	logger       *logrus.Logger
	healthTicker *time.Ticker
	stopHealth   chan bool
	mode         string // rotate | sticky | localhost
	rotationTicker *time.Ticker
}

type Config struct {
	ListFile            string
	RotateOnFailure     bool
	HealthCheckInterval int
	Mode                string // rotate | sticky | localhost
	RotationInterval    int
}

// NewManager creates a new proxy manager
func NewManager(config Config) (*Manager, error) {
	proxies, err := loadProxies(config.ListFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load proxies: %w", err)
	}
	
	// if none loaded, we still create manager in localhost mode
	if len(proxies) == 0 && config.Mode == "" {
		config.Mode = "localhost"
	}
	
	manager := &Manager{
		proxies:    proxies,
		current:    0,
		logger:     logrus.New(),
		stopHealth: make(chan bool),
		mode:       config.Mode,
	}
	
	// Start health checking if enabled
	if config.HealthCheckInterval > 0 {
		manager.startHealthChecking(config.HealthCheckInterval)
	}
	// Start rotation ticker if configured
	if config.RotationInterval > 0 && len(proxies) > 1 && manager.mode != "sticky" {
		manager.rotationTicker = time.NewTicker(time.Duration(config.RotationInterval) * time.Second)
		go func() {
			for range manager.rotationTicker.C {
				manager.mu.Lock()
				manager.current = (manager.current + 1) % len(manager.proxies)
				manager.mu.Unlock()
			}
		}()
	}
	
	return manager, nil
}

// GetNext returns the next available proxy
func (m *Manager) GetNext() *Proxy {
	m.mu.Lock()
	defer m.mu.Unlock()
	
	if len(m.proxies) == 0 {
		return nil
	}
	
	// sticky mode: keep returning current proxy unless it failed
	if m.mode == "sticky" {
		p := m.proxies[m.current]
		if !p.Failed {
			p.LastUsed = time.Now()
			return p
		}
		// if failed, fall through to rotation to find a working one
	}
	
	// Find next working proxy (rotate)
	attempts := 0
	for attempts < len(m.proxies) {
		proxy := m.proxies[m.current]
		m.current = (m.current + 1) % len(m.proxies)
		
		if !proxy.Failed {
			proxy.LastUsed = time.Now()
			return proxy
		}
		
		attempts++
	}
	
	// All proxies failed, reset and try first one
	m.logger.Warn("All proxies marked as failed, resetting...")
	for _, p := range m.proxies {
		p.Failed = false
	}
	
	proxy := m.proxies[0]
	proxy.LastUsed = time.Now()
	return proxy
}

// MarkFailed marks a proxy as failed
func (m *Manager) MarkFailed(proxy *Proxy) {
	m.mu.Lock()
	defer m.mu.Unlock()
	
	proxy.Failed = true
	proxy.FailCount++
	m.logger.Warnf("Proxy marked as failed: %s (fail count: %d)", proxy.URL, proxy.FailCount)
	
	// If too many failures, permanently remove
	if proxy.FailCount > 10 {
		m.removeProxy(proxy)
	}
}

// MarkSuccess marks a proxy as successful
func (m *Manager) MarkSuccess(proxy *Proxy) {
	m.mu.Lock()
	defer m.mu.Unlock()
	
	proxy.Failed = false
	proxy.SuccessCount++
	proxy.lastHealthy = true
	proxy.lastHealthAt = time.Now()
	
	// Reset fail count on success
	if proxy.FailCount > 0 {
		proxy.FailCount = 0
	}
}

// GetStats returns proxy statistics
func (m *Manager) GetStats() map[string]interface{} {
	m.mu.RLock()
	defer m.mu.RUnlock()
	
	working := 0
	failed := 0
	for _, p := range m.proxies {
		if p.Failed {
			failed++
		} else {
			working++
		}
	}
	
	return map[string]interface{}{
		"total":   len(m.proxies),
		"working": working,
		"failed":  failed,
	}
}

// startHealthChecking starts periodic health checks
func (m *Manager) startHealthChecking(intervalSeconds int) {
	m.healthTicker = time.NewTicker(time.Duration(intervalSeconds) * time.Second)
	
	go func() {
		for {
			select {
			case <-m.healthTicker.C:
				m.checkProxyHealth()
			case <-m.stopHealth:
				m.healthTicker.Stop()
				return
			}
		}
	}()
}

// checkProxyHealth tests all proxies with cache to avoid frequent rechecks
func (m *Manager) checkProxyHealth() {
	m.mu.Lock()
	proxiesToCheck := make([]*Proxy, len(m.proxies))
	copy(proxiesToCheck, m.proxies)
	m.mu.Unlock()
	
	var wg sync.WaitGroup
	for _, proxy := range proxiesToCheck {
		wg.Add(1)
		go func(p *Proxy) {
			defer wg.Done()
			// Health cache: skip if recently checked within 60s
			if time.Since(p.lastHealthAt) < 60*time.Second {
				return
			}
			if err := testProxy(p); err != nil {
				m.logger.Debugf("Proxy health check failed for %s: %v", p.URL, err)
				p.Failed = true
				p.lastHealthy = false
			} else {
				p.Failed = false
				p.lastHealthy = true
			}
			p.lastHealthAt = time.Now()
		}(proxy)
	}
	
	wg.Wait()
	m.logger.Infof("Health check complete: %v", m.GetStats())
}

// AddProxy adds a proxy dynamically
func (m *Manager) AddProxy(line string) error {
	p, err := parseProxyLine(strings.TrimSpace(line))
	if err != nil { return err }
	m.mu.Lock()
	defer m.mu.Unlock()
	m.proxies = append(m.proxies, p)
	return nil
}

// RemoveProxy removes a proxy by URL
func (m *Manager) RemoveProxy(url string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	idx := -1
	for i, p := range m.proxies {
		if p.URL == url { idx = i; break }
	}
	if idx >= 0 {
		m.proxies = append(m.proxies[:idx], m.proxies[idx+1:]...)
	}
}

// testProxy tests if a proxy is working
func testProxy(p *Proxy) error {
	proxyURL, err := url.Parse(p.URL)
	if err != nil {
		return err
	}
	
	if p.Username != "" {
		proxyURL.User = url.UserPassword(p.Username, p.Password)
	}
	
	client := &http.Client{
		Transport: &http.Transport{
			Proxy: http.ProxyURL(proxyURL),
		},
		Timeout: 10 * time.Second,
	}
	
	resp, err := client.Get("https://www.walmart.com/")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != 200 {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}
	
	return nil
}

// removeProxy removes a proxy from the list
func (m *Manager) removeProxy(proxy *Proxy) {
	newProxies := make([]*Proxy, 0, len(m.proxies)-1)
	for _, p := range m.proxies {
		if p != proxy {
			newProxies = append(newProxies, p)
		}
	}
	m.proxies = newProxies
	m.logger.Infof("Removed failed proxy: %s", proxy.URL)
}

// loadProxies loads proxies from file
func loadProxies(filename string) ([]*Proxy, error) {
	file, err := os.Open(filename)
	if err != nil {
		// Return empty list if file doesn't exist
		if os.IsNotExist(err) {
			return []*Proxy{}, nil
		}
		return nil, err
	}
	defer file.Close()
	
	var proxies []*Proxy
	scanner := bufio.NewScanner(file)
	
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		
		proxy, err := parseProxyLine(line)
		if err != nil {
			logrus.Warnf("Failed to parse proxy line: %s", line)
			continue
		}
		
		proxies = append(proxies, proxy)
	}
	
	return proxies, scanner.Err()
}

// parseProxyLine parses a proxy configuration line
// Format: protocol://[user:pass@]host:port
func parseProxyLine(line string) (*Proxy, error) {
	// Check for protocol prefix
	protocol := "http"
	if strings.HasPrefix(line, "socks5://") {
		protocol = "socks5"
		line = strings.TrimPrefix(line, "socks5://")
	} else if strings.HasPrefix(line, "https://") {
		protocol = "https"
		line = strings.TrimPrefix(line, "https://")
	} else if strings.HasPrefix(line, "http://") {
		line = strings.TrimPrefix(line, "http://")
	}
	
	proxy := &Proxy{
		Protocol: protocol,
	}
	
	// Check for auth credentials
	if strings.Contains(line, "@") {
		parts := strings.SplitN(line, "@", 2)
		if len(parts) == 2 {
			authParts := strings.SplitN(parts[0], ":", 2)
			if len(authParts) == 2 {
				proxy.Username = authParts[0]
				proxy.Password = authParts[1]
			}
			line = parts[1]
		}
	}
	
	// Set the URL
	proxy.URL = fmt.Sprintf("%s://%s", protocol, line)
	
	return proxy, nil
}

// Close stops the proxy manager
func (m *Manager) Close() {
	if m.stopHealth != nil {
		close(m.stopHealth)
	}
	if m.rotationTicker != nil {
		m.rotationTicker.Stop()
	}
}