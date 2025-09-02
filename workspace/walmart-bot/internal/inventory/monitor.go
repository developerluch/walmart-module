package inventory

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/agentwise/walmart-bot/internal/graphql"
	"github.com/agentwise/walmart-bot/internal/protection"
	"github.com/agentwise/walmart-bot/internal/tlsclient"
)

// Item represents a product to monitor
type Item struct {
	ID       string
	URL      string
	Name     string
	InStock  bool
	Price    float64
	Quantity int
}

// CheckInventory checks the inventory status of items (stubbed)
func CheckInventory(ctx context.Context, itemURLs []string) []Item {
	items := make([]Item, 0, len(itemURLs))
	var mu sync.Mutex
	var wg sync.WaitGroup
	
	for _, url := range itemURLs {
		wg.Add(1)
		go func(itemURL string) {
			defer wg.Done()
			
			// Extract item ID from URL
			itemID := extractItemID(itemURL)
			if itemID == "" {
				return
			}
			
			// Check item status (simplified for testing)
			item := Item{
				ID:      itemID,
				URL:     itemURL,
				Name:    fmt.Sprintf("Item %s", itemID),
				InStock: checkStock(itemID),
				Price:   99.99,
				Quantity: 1,
			}
			
			mu.Lock()
			items = append(items, item)
			mu.Unlock()
		}(url)
	}
	
	wg.Wait()
	return items
}

// CheckInventoryReal performs real availability/price checks using GraphQL via TLS+PX
func CheckInventoryReal(ctx context.Context, session *tlsclient.Session, px *protection.PXSolver, itemIDs []string) ([]Item, error) {
	if session == nil { return nil, fmt.Errorf("nil session") }
	vars := map[string]interface{}{"productIds": itemIDs}
	body, err := graphql.Execute(session, px, "https://www.walmart.com/orchestra/graphql", graphql.GetInventoryStatusQuery, vars)
	if err != nil { return nil, err }
	var resp struct {
		Data struct {
			Products []struct {
				ID       string  `json:"id"`
				Name     string  `json:"name"`
				InStock  bool    `json:"inStock"`
				Quantity int     `json:"quantity"`
				Price    struct { Current float64 `json:"current"` } `json:"price"`
			} `json:"products"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &resp); err != nil { return nil, err }
	items := make([]Item, 0, len(resp.Data.Products))
	for _, p := range resp.Data.Products {
		items = append(items, Item{ ID: p.ID, Name: p.Name, InStock: p.InStock, Price: p.Price.Current, Quantity: p.Quantity })
	}
	return items, nil
}

// extractItemID extracts the item ID from a Walmart URL
func extractItemID(url string) string {
	// Example: https://www.walmart.com/ip/item-name/123456789
	parts := strings.Split(url, "/")
	if len(parts) > 0 {
		return parts[len(parts)-1]
	}
	return ""
}

// checkStock simulates checking if an item is in stock
func checkStock(itemID string) bool {
	// Simplified: alternate between in/out of stock for testing
	return time.Now().Unix()%2 == 0
}

// Monitor continuously monitors items for stock changes
type Monitor struct {
	items    []string
	interval time.Duration
	updates  chan Item
	stop     chan bool
}

// NewMonitor creates a new inventory monitor
func NewMonitor(items []string, interval time.Duration) *Monitor {
	return &Monitor{
		items:    items,
		interval: interval,
		updates:  make(chan Item, 100),
		stop:     make(chan bool),
	}
}

// Start begins monitoring
func (m *Monitor) Start(ctx context.Context) {
	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()
	
	for {
		select {
		case <-ctx.Done():
			return
		case <-m.stop:
			return
		case <-ticker.C:
			items := CheckInventory(ctx, m.items)
			for _, item := range items {
				if item.InStock {
					select {
					case m.updates <- item:
					default:
						// Channel full, skip
					}
				}
			}
		}
	}
}

// GetUpdates returns the updates channel
func (m *Monitor) GetUpdates() <-chan Item {
	return m.updates
}

// Stop stops the monitor
func (m *Monitor) Stop() {
	close(m.stop)
}