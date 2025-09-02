package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// WebSocket upgrader
var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true // Allow all origins in development
	},
}

// Data structures
type BotStatus struct {
	Status    string `json:"status"`
	Uptime    string `json:"uptime"`
	LastCheck string `json:"lastCheck"`
}

type SuccessMetrics struct {
	Successful int `json:"successful"`
	Failed     int `json:"failed"`
}

type ProxyInfo struct {
	IP      string `json:"ip"`
	Port    int    `json:"port"`
	Healthy bool   `json:"healthy"`
	LastUsed time.Time `json:"lastUsed"`
}

type Order struct {
	ID      string `json:"id"`
	Product string `json:"product"`
	Status  string `json:"status"` // completed, processing, failed
	Price   float64 `json:"price"`
	Timestamp time.Time `json:"timestamp"`
}

type InventoryItem struct {
	Name   string `json:"name"`
	Level  string `json:"level"` // high, medium, low, out
	Status string `json:"status"`
	Count  int    `json:"count"`
}

type PerformanceMetrics struct {
	AvgResponseTime   float64 `json:"avgResponseTime"`
	RequestsPerMinute int     `json:"requestsPerMinute"`
}

type Configuration struct {
	CheckInterval      int `json:"checkInterval"`
	MaxRetries        int `json:"maxRetries"`
	Timeout           int `json:"timeout"`
	ProxyRotation     int `json:"proxyRotation"`
	ProxyHealthCheck  int `json:"proxyHealthCheck"`
	ConcurrentRequests int `json:"concurrentRequests"`
}

type LogEntry struct {
	Message   string    `json:"message"`
	Level     string    `json:"level"` // info, success, warning, error
	Timestamp time.Time `json:"timestamp"`
}

type WebSocketMessage struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

type CommandMessage struct {
	Type      string      `json:"type"`
	Command   string      `json:"command"`
	Payload   interface{} `json:"payload"`
	Timestamp string      `json:"timestamp"`
}

// Bot manager structure
type WalmartBot struct {
	mu                sync.RWMutex
	isRunning         bool
	startTime         time.Time
	successMetrics    SuccessMetrics
	proxies           []ProxyInfo
	orders            []Order
	inventory         []InventoryItem
	performanceMetrics PerformanceMetrics
	config            Configuration
	logs              []LogEntry
	clients           map[*websocket.Conn]bool
}

func NewWalmartBot() *WalmartBot {
	return &WalmartBot{
		isRunning:  false,
		startTime:  time.Now(),
		successMetrics: SuccessMetrics{
			Successful: 143,
			Failed:     8,
		},
		proxies: []ProxyInfo{
			{IP: "192.168.1.101", Port: 8080, Healthy: true},
			{IP: "192.168.1.102", Port: 8080, Healthy: true},
			{IP: "192.168.1.103", Port: 8080, Healthy: false},
			{IP: "192.168.1.104", Port: 8080, Healthy: true},
		},
		orders: []Order{
			{ID: "WM-2024-001234", Product: "iPhone 15 Pro", Status: "completed", Price: 999.99, Timestamp: time.Now().Add(-time.Hour)},
			{ID: "WM-2024-001235", Product: "MacBook Air M2", Status: "processing", Price: 1199.99, Timestamp: time.Now().Add(-30 * time.Minute)},
			{ID: "WM-2024-001236", Product: "iPad Pro 12.9\"", Status: "failed", Price: 799.99, Timestamp: time.Now().Add(-15 * time.Minute)},
		},
		inventory: []InventoryItem{
			{Name: "iPhone 15 Pro 256GB", Level: "high", Status: "In Stock", Count: 47},
			{Name: "MacBook Pro M3", Level: "medium", Status: "Low Stock", Count: 5},
			{Name: "AirPods Pro 2", Level: "low", Status: "Out of Stock", Count: 0},
			{Name: "iPad Air M2", Level: "high", Status: "In Stock", Count: 23},
		},
		performanceMetrics: PerformanceMetrics{
			AvgResponseTime:   2.3,
			RequestsPerMinute: 47,
		},
		config: Configuration{
			CheckInterval:      5000,
			MaxRetries:        3,
			Timeout:           10000,
			ProxyRotation:     300,
			ProxyHealthCheck:  60,
			ConcurrentRequests: 5,
		},
		clients: make(map[*websocket.Conn]bool),
		logs:    []LogEntry{},
	}
}

func (bot *WalmartBot) Start() {
	bot.mu.Lock()
	defer bot.mu.Unlock()
	
	bot.isRunning = true
	bot.startTime = time.Now()
	bot.addLog("Bot started successfully", "success")
	
	// Start monitoring routines
	go bot.monitoringLoop()
	go bot.proxyHealthCheck()
	go bot.inventoryMonitoring()
}

func (bot *WalmartBot) Stop() {
	bot.mu.Lock()
	defer bot.mu.Unlock()
	
	bot.isRunning = false
	bot.addLog("Bot stopped", "warning")
}

func (bot *WalmartBot) GetStatus() BotStatus {
	bot.mu.RLock()
	defer bot.mu.RUnlock()
	
	status := "STOPPED"
	if bot.isRunning {
		status = "ACTIVE"
	}
	
	uptime := time.Since(bot.startTime).Truncate(time.Second).String()
	lastCheck := time.Now().Format("3:04 PM")
	
	return BotStatus{
		Status:    status,
		Uptime:    uptime,
		LastCheck: lastCheck,
	}
}

func (bot *WalmartBot) addLog(message, level string) {
	entry := LogEntry{
		Message:   message,
		Level:     level,
		Timestamp: time.Now(),
	}
	
	bot.logs = append([]LogEntry{entry}, bot.logs...)
	if len(bot.logs) > 100 {
		bot.logs = bot.logs[:100]
	}
	
	// Broadcast log entry to all clients
	go bot.broadcastMessage(WebSocketMessage{
		Type:    "log_entry",
		Payload: entry,
	})
}

func (bot *WalmartBot) monitoringLoop() {
	ticker := time.NewTicker(time.Duration(bot.config.CheckInterval) * time.Millisecond)
	defer ticker.Stop()
	
	for range ticker.C {
		if !bot.isRunning {
			return
		}
		
		bot.performCheck()
	}
}

func (bot *WalmartBot) performCheck() {
	bot.mu.Lock()
	defer bot.mu.Unlock()
	
	// Simulate bot activity
	if rand.Float32() < 0.95 { // 95% success rate
		bot.successMetrics.Successful++
		products := []string{"iPhone 15 Pro", "MacBook Air M2", "iPad Pro", "AirPods Pro 2"}
		product := products[rand.Intn(len(products))]
		bot.addLog(fmt.Sprintf("Product check completed - %s: In Stock", product), "success")
	} else {
		bot.successMetrics.Failed++
		bot.addLog("Product check failed - Proxy timeout", "error")
	}
	
	// Update performance metrics
	bot.performanceMetrics.AvgResponseTime = 1.5 + rand.Float64()*2
	bot.performanceMetrics.RequestsPerMinute = 40 + rand.Intn(20)
	
	// Broadcast updates
	go bot.broadcastMessage(WebSocketMessage{Type: "success_metrics", Payload: bot.successMetrics})
	go bot.broadcastMessage(WebSocketMessage{Type: "performance_metrics", Payload: bot.performanceMetrics})
}

func (bot *WalmartBot) proxyHealthCheck() {
	ticker := time.NewTicker(time.Duration(bot.config.ProxyHealthCheck) * time.Second)
	defer ticker.Stop()
	
	for range ticker.C {
		if !bot.isRunning {
			return
		}
		
		bot.mu.Lock()
		for i := range bot.proxies {
			// Simulate proxy health changes
			if rand.Float32() < 0.1 { // 10% chance to change status
				bot.proxies[i].Healthy = !bot.proxies[i].Healthy
				status := "healthy"
				if !bot.proxies[i].Healthy {
					status = "failed"
				}
				bot.addLog(fmt.Sprintf("Proxy %s:%d health check: %s", bot.proxies[i].IP, bot.proxies[i].Port, status), "info")
			}
		}
		bot.mu.Unlock()
		
		go bot.broadcastMessage(WebSocketMessage{Type: "proxy_health", Payload: bot.proxies})
	}
}

func (bot *WalmartBot) inventoryMonitoring() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	
	for range ticker.C {
		if !bot.isRunning {
			return
		}
		
		bot.mu.Lock()
		for i := range bot.inventory {
			// Simulate inventory changes
			if rand.Float32() < 0.2 { // 20% chance to change inventory
				change := rand.Intn(10) - 5 // -5 to +5
				bot.inventory[i].Count = max(0, bot.inventory[i].Count+change)
				
				// Update level based on count
				if bot.inventory[i].Count == 0 {
					bot.inventory[i].Level = "low"
					bot.inventory[i].Status = "Out of Stock"
				} else if bot.inventory[i].Count < 10 {
					bot.inventory[i].Level = "medium"
					bot.inventory[i].Status = "Low Stock"
				} else {
					bot.inventory[i].Level = "high"
					bot.inventory[i].Status = "In Stock"
				}
				
				bot.addLog(fmt.Sprintf("Inventory updated: %s - %d units", bot.inventory[i].Name, bot.inventory[i].Count), "info")
			}
		}
		bot.mu.Unlock()
		
		go bot.broadcastMessage(WebSocketMessage{Type: "inventory_alert", Payload: bot.inventory})
	}
}

func (bot *WalmartBot) broadcastMessage(message WebSocketMessage) {
	bot.mu.RLock()
	clients := make([]*websocket.Conn, 0, len(bot.clients))
	for client := range bot.clients {
		clients = append(clients, client)
	}
	bot.mu.RUnlock()
	
	for _, client := range clients {
		err := client.WriteJSON(message)
		if err != nil {
			log.Printf("Error broadcasting message: %v", err)
			bot.mu.Lock()
			delete(bot.clients, client)
			client.Close()
			bot.mu.Unlock()
		}
	}
}

func (bot *WalmartBot) handleCommand(cmd CommandMessage) {
	bot.mu.Lock()
	defer bot.mu.Unlock()
	
	switch cmd.Command {
	case "start_bot":
		if !bot.isRunning {
			go bot.Start()
		}
	case "stop_bot":
		bot.Stop()
	case "refresh_data":
		go bot.sendAllData()
	case "update_config":
		if configData, ok := cmd.Payload.(map[string]interface{}); ok {
			bot.updateConfiguration(configData)
		}
	default:
		bot.addLog(fmt.Sprintf("Unknown command: %s", cmd.Command), "warning")
	}
}

func (bot *WalmartBot) updateConfiguration(configData map[string]interface{}) {
	if val, ok := configData["checkInterval"].(float64); ok {
		bot.config.CheckInterval = int(val)
	}
	if val, ok := configData["maxRetries"].(float64); ok {
		bot.config.MaxRetries = int(val)
	}
	if val, ok := configData["timeout"].(float64); ok {
		bot.config.Timeout = int(val)
	}
	if val, ok := configData["proxyRotation"].(float64); ok {
		bot.config.ProxyRotation = int(val)
	}
	if val, ok := configData["proxyHealthCheck"].(float64); ok {
		bot.config.ProxyHealthCheck = int(val)
	}
	if val, ok := configData["concurrentRequests"].(float64); ok {
		bot.config.ConcurrentRequests = int(val)
	}
	
	bot.addLog("Configuration updated successfully", "success")
}

func (bot *WalmartBot) sendAllData() {
	// Send initial data to newly connected client
	messages := []WebSocketMessage{
		{Type: "bot_status", Payload: bot.GetStatus()},
		{Type: "success_metrics", Payload: bot.successMetrics},
		{Type: "proxy_health", Payload: bot.proxies},
		{Type: "order_update", Payload: bot.orders},
		{Type: "inventory_alert", Payload: bot.inventory},
		{Type: "performance_metrics", Payload: bot.performanceMetrics},
	}
	
	for _, message := range messages {
		bot.broadcastMessage(message)
	}
}

// HTTP Handlers
func (bot *WalmartBot) websocketHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}
	defer conn.Close()
	
	// Register client
	bot.mu.Lock()
	bot.clients[conn] = true
	bot.mu.Unlock()
	
	log.Printf("Client connected: %s", conn.RemoteAddr())
	bot.addLog(fmt.Sprintf("Dashboard client connected: %s", conn.RemoteAddr()), "info")
	
	// Send initial data
	go bot.sendAllData()
	
	// Handle incoming messages
	for {
		var cmd CommandMessage
		err := conn.ReadJSON(&cmd)
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error: %v", err)
			}
			break
		}
		
		go bot.handleCommand(cmd)
	}
	
	// Unregister client
	bot.mu.Lock()
	delete(bot.clients, conn)
	bot.mu.Unlock()
	
	log.Printf("Client disconnected: %s", conn.RemoteAddr())
}

func (bot *WalmartBot) statusHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	
	status := bot.GetStatus()
	json.NewEncoder(w).Encode(status)
}

func (bot *WalmartBot) metricsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	
	bot.mu.RLock()
	metrics := map[string]interface{}{
		"success_metrics":     bot.successMetrics,
		"performance_metrics": bot.performanceMetrics,
		"proxy_health":       bot.proxies,
		"inventory":          bot.inventory,
		"orders":             bot.orders,
	}
	bot.mu.RUnlock()
	
	json.NewEncoder(w).Encode(metrics)
}

func (bot *WalmartBot) configHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	
	switch r.Method {
	case http.MethodGet:
		bot.mu.RLock()
		config := bot.config
		bot.mu.RUnlock()
		json.NewEncoder(w).Encode(config)
		
	case http.MethodPost:
		var newConfig Configuration
		if err := json.NewDecoder(r.Body).Decode(&newConfig); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}
		
		bot.mu.Lock()
		bot.config = newConfig
		bot.mu.Unlock()
		
		bot.addLog("Configuration updated via API", "success")
		w.WriteHeader(http.StatusOK)
		
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func main() {
	bot := NewWalmartBot()
	
	// Start the bot
	go bot.Start()
	
	// Setup HTTP routes
	http.HandleFunc("/ws", bot.websocketHandler)
	http.HandleFunc("/api/status", bot.statusHandler)
	http.HandleFunc("/api/metrics", bot.metricsHandler)
	http.HandleFunc("/api/config", bot.configHandler)
	
	// Serve static files (dashboard)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.ServeFile(w, r, "walmart-bot-dashboard.html")
		} else {
			http.NotFound(w, r)
		}
	})
	
	port := ":8080"
	log.Printf("Walmart Bot Dashboard Server starting on port %s", port)
	log.Printf("Dashboard URL: http://localhost%s", port)
	log.Printf("WebSocket endpoint: ws://localhost%s/ws", port)
	
	if err := http.ListenAndServe(port, nil); err != nil {
		log.Fatal("Server failed to start:", err)
	}
}