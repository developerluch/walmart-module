package logging

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/agentwise/walmart-bot/internal/checkout"
	"github.com/sirupsen/logrus"
)

// NewLogger creates a new configured logger
func NewLogger(debug bool) *logrus.Logger {
	logger := logrus.New()
	
	if debug {
		logger.SetLevel(logrus.DebugLevel)
	} else {
		logger.SetLevel(logrus.InfoLevel)
	}
	
	logger.SetFormatter(&logrus.TextFormatter{
		TimestampFormat: "2006-01-02 15:04:05",
		FullTimestamp:   true,
	})
	
	return logger
}

// SetLogFile configures the logger to also write to a file.
func SetLogFile(logger *logrus.Logger, path string) {
	if logger == nil || strings.TrimSpace(path) == "" { return }
	_ = os.MkdirAll("logs", 0o755)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		logger.Warnf("Failed to open log file %s: %v", path, err)
		return
	}
	mw := io.MultiWriter(os.Stdout, f)
	logger.SetOutput(mw)
}

// DiscordLogger handles Discord webhook notifications
type DiscordLogger struct {
	webhookURL string
	client     *http.Client
}

// NewDiscordLogger creates a new Discord logger
func NewDiscordLogger(webhookURL string) *DiscordLogger {
	return &DiscordLogger{
		webhookURL: webhookURL,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// LogCheckoutSuccess sends success notification to Discord (basic)
func (dl *DiscordLogger) LogCheckoutSuccess(result interface{}) error {
	if dl.webhookURL == "" {
		return nil
	}
	
	orderID := fmt.Sprintf("%v", result)
	fields := []map[string]interface{}{
		{"name": "Order ID", "value": orderID, "inline": true},
		{"name": "Timestamp", "value": time.Now().Format("15:04:05"), "inline": true},
	}

	embed := map[string]interface{}{
		"title":     "✅ Checkout Successful",
		"color":     3066993, // Green
		"timestamp": time.Now().Format(time.RFC3339),
		"fields":    fields,
	}
	
	return dl.sendWebhook(embed)
}

// LogCheckoutSummary sends a detailed checkout summary to Discord
func (dl *DiscordLogger) LogCheckoutSummary(res *checkout.CheckoutResult, email string, address string) error {
	if dl.webhookURL == "" || res == nil {
		return nil
	}
	fields := []map[string]interface{}{
		{"name": "Order ID", "value": res.OrderID, "inline": true},
		{"name": "Order #", "value": res.OrderNumber, "inline": true},
		{"name": "Total", "value": fmt.Sprintf("$%.2f", res.Total), "inline": true},
	}
	if email != "" {
		fields = append(fields, map[string]interface{}{"name": "Account", "value": maskEmail(email), "inline": true})
	}
	if address != "" {
		fields = append(fields, map[string]interface{}{"name": "Ship To", "value": address, "inline": false})
	}
	if res.EstimatedDelivery != "" {
		fields = append(fields, map[string]interface{}{"name": "ETA", "value": res.EstimatedDelivery, "inline": true})
	}

	embed := map[string]interface{}{
		"title":     "✅ Checkout Summary",
		"color":     3066993,
		"timestamp": time.Now().Format(time.RFC3339),
		"fields":    fields,
	}
	return dl.sendWebhook(embed)
}

// LogCheckoutFailure sends failure notification to Discord
func (dl *DiscordLogger) LogCheckoutFailure(itemID string, err error) error {
	if dl.webhookURL == "" {
		return nil
	}
	
	embed := map[string]interface{}{
		"title":     "❌ Checkout Failed",
		"color":     15158332, // Red
		"timestamp": time.Now().Format(time.RFC3339),
		"fields": []map[string]interface{}{
			{"name": "Item ID", "value": itemID, "inline": true},
			{"name": "Error", "value": err.Error(), "inline": false},
		},
	}
	
	return dl.sendWebhook(embed)
}

// sendWebhook sends embed to Discord
func (dl *DiscordLogger) sendWebhook(embed map[string]interface{}) error {
	payload := map[string]interface{}{
		"embeds": []map[string]interface{}{embed},
	}
	
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	
	resp, err := dl.client.Post(dl.webhookURL, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != 204 && resp.StatusCode != 200 {
		return fmt.Errorf("discord webhook failed with status: %d", resp.StatusCode)
	}
	
	return nil
}

// maskEmail rudimentarily masks an email address to reduce PII exposure
func maskEmail(email string) string {
	at := strings.Index(email, "@")
	if at <= 1 { return "***" }
	name := email[:at]
	domain := email[at:]
	if len(name) <= 2 { return "***" + domain }
	return name[:1] + "***" + name[len(name)-1:] + domain
}