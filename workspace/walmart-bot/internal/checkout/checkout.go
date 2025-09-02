package checkout

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/agentwise/walmart-bot/internal/graphql"
	"github.com/agentwise/walmart-bot/internal/protection"
	"github.com/agentwise/walmart-bot/internal/tlsclient"
	"github.com/sirupsen/logrus"
)

type Client struct {
	session *tlsclient.Session
	logger  *logrus.Logger
	cartID  string
	px      *protection.PXSolver
	paymentMethodID string
}

type CheckoutResult struct {
	Success           bool
	OrderID           string
	OrderNumber       string
	Total             float64
	EstimatedDelivery string
	Timestamp         time.Time
}

// NewClient creates a new checkout client
func NewClient(session *tlsclient.Session, logger *logrus.Logger, px *protection.PXSolver, paymentMethodID string) *Client {
	return &Client{
		session: session,
		logger:  logger,
		px:      px,
		paymentMethodID: paymentMethodID,
	}
}

// ProcessCheckout handles the complete checkout flow
func (c *Client) ProcessCheckout(itemID string, quantity int) (*CheckoutResult, error) {
	c.logger.Infof("Starting checkout for item: %s, quantity: %d", itemID, quantity)
	
	// Step 1: Add to cart
	if err := c.addToCart(itemID, quantity); err != nil {
		return nil, fmt.Errorf("failed to add to cart: %w", err)
	}
	
	// Step 2: Select delivery address
	if err := c.selectDeliveryAddress(); err != nil {
		return nil, fmt.Errorf("failed to select delivery address: %w", err)
	}
	
	// Step 3: Select payment method
	if err := c.selectPaymentMethod(); err != nil {
		return nil, fmt.Errorf("failed to select payment method: %w", err)
	}
	
	// Step 4: Review order
	orderReview, err := c.reviewOrder()
	if err != nil {
		return nil, fmt.Errorf("failed to review order: %w", err)
	}
	
	// Step 5: Place order
	result, err := c.placeOrder(orderReview)
	if err != nil {
		return nil, fmt.Errorf("failed to place order: %w", err)
	}
	
	c.logger.Infof("Checkout successful! Order ID: %s", result.OrderID)
	return result, nil
}

// addToCart adds an item to the cart
func (c *Client) addToCart(itemID string, quantity int) error {
	c.logger.Infof("Adding item to cart: %s", itemID)
	
	mutation := graphql.AddToCartMutation
	variables := map[string]interface{}{
		"input": map[string]interface{}{
			"productId": itemID,
			"quantity":  quantity,
		},
	}
	
	body, err := c.executeGraphQL(mutation, variables)
	if err != nil {
		return err
	}
	
	var response AddToCartResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return fmt.Errorf("failed to parse add to cart response: %w", err)
	}
	
	if !response.Data.AddToCart.Success {
		return fmt.Errorf("add to cart failed: %s", response.Data.AddToCart.Message)
	}
	
	c.cartID = response.Data.AddToCart.CartID
	c.logger.Infof("Item added to cart. Cart ID: %s", c.cartID)
	
	return nil
}

// selectDeliveryAddress selects or adds a delivery address
func (c *Client) selectDeliveryAddress() error {
	c.logger.Info("Selecting delivery address")
	
	// Get saved addresses
	query := graphql.GetDeliveryAddressesQuery
	body, err := c.executeGraphQL(query, nil)
	if err != nil {
		return err
	}
	
	var response DeliveryAddressesResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return fmt.Errorf("failed to parse addresses response: %w", err)
	}
	
	// Use default address if available
	for _, addr := range response.Data.Customer.Addresses {
		if addr.IsDefault {
			c.logger.Infof("Using default address: %s, %s", addr.City, addr.State)
			return c.setDeliveryAddress(addr.ID)
		}
	}
	
	// Use first address if no default
	if len(response.Data.Customer.Addresses) > 0 {
		addr := response.Data.Customer.Addresses[0]
		c.logger.Infof("Using address: %s, %s", addr.City, addr.State)
		return c.setDeliveryAddress(addr.ID)
	}
	
	return fmt.Errorf("no delivery addresses found")
}

// setDeliveryAddress sets the delivery address for the order
func (c *Client) setDeliveryAddress(addressID string) error {
	// This would make an API call to set the address
	// Implementation depends on Walmart's specific endpoint
	c.logger.Infof("Setting delivery address: %s", addressID)
	
	headers := c.getHeaders()
	resp, err := c.session.Post(
		fmt.Sprintf("https://www.walmart.com/api/checkout/v3/contract/%s/shipping-address", c.cartID),
		headers,
		fmt.Sprintf(`{"addressId":"%s"}`, addressID),
	)
	
	if err != nil {
		return err
	}
	
	if resp.StatusCode != 200 {
		return fmt.Errorf("failed to set delivery address: status %d", resp.StatusCode)
	}
	
	return nil
}

// selectPaymentMethod selects a payment method
func (c *Client) selectPaymentMethod() error {
	c.logger.Info("Selecting payment method")
	
	// Get saved payment methods
	query := graphql.GetPaymentMethodsQuery
	body, err := c.executeGraphQL(query, nil)
	if err != nil {
		return err
	}
	
	var response PaymentMethodsResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return fmt.Errorf("failed to parse payment methods response: %w", err)
	}
	
	// Prefer configured payment method if present
	if c.paymentMethodID != "" {
		for _, method := range response.Data.Customer.PaymentMethods {
			if method.ID == c.paymentMethodID {
				c.logger.Infof("Using configured payment: %s ending in %s", method.CardBrand, method.LastFour)
				return c.setPaymentMethod(method.ID)
			}
		}
	}

	// Use default payment method if available
	for _, method := range response.Data.Customer.PaymentMethods {
		if method.IsDefault {
			c.logger.Infof("Using default payment: %s ending in %s", method.CardBrand, method.LastFour)
			return c.setPaymentMethod(method.ID)
		}
	}
	
	// Use first payment method if no default
	if len(response.Data.Customer.PaymentMethods) > 0 {
		method := response.Data.Customer.PaymentMethods[0]
		c.logger.Infof("Using payment: %s ending in %s", method.CardBrand, method.LastFour)
		return c.setPaymentMethod(method.ID)
	}
	
	return fmt.Errorf("no payment methods found")
}

// setPaymentMethod sets the payment method for the order
func (c *Client) setPaymentMethod(paymentID string) error {
	c.logger.Infof("Setting payment method: %s", paymentID)
	
	headers := c.getHeaders()
	resp, err := c.session.Post(
		fmt.Sprintf("https://www.walmart.com/api/checkout/v3/contract/%s/payment", c.cartID),
		headers,
		fmt.Sprintf(`{"paymentMethodId":"%s"}`, paymentID),
	)
	
	if err != nil {
		return err
	}
	
	if resp.StatusCode != 200 {
		return fmt.Errorf("failed to set payment method: status %d", resp.StatusCode)
	}
	
	return nil
}

// reviewOrder reviews the order before placing
func (c *Client) reviewOrder() (*OrderReview, error) {
	c.logger.Info("Reviewing order")
	
	query := graphql.GetReviewOrderQuery
	variables := map[string]interface{}{
		"cartId": c.cartID,
	}
	
	body, err := c.executeGraphQL(query, variables)
	if err != nil {
		return nil, err
	}
	
	var response ReviewOrderResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return nil, fmt.Errorf("failed to parse review order response: %w", err)
	}
	
	if !response.Data.ReviewOrder.CanPlaceOrder {
		return nil, fmt.Errorf("cannot place order: review failed")
	}
	
	c.logger.Infof("Order review complete. Total: $%.2f", response.Data.ReviewOrder.Totals.Total)
	
	return &response.Data.ReviewOrder, nil
}

// placeOrder submits the final order
func (c *Client) placeOrder(review *OrderReview) (*CheckoutResult, error) {
	c.logger.Info("Placing order")
	
	mutation := graphql.PlaceOrderMutation
	variables := map[string]interface{}{
		"input": map[string]interface{}{
			"cartId":  c.cartID,
			"orderId": review.OrderID,
		},
	}
	
	body, err := c.executeGraphQL(mutation, variables)
	if err != nil {
		return nil, err
	}
	
	var response PlaceOrderResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return nil, fmt.Errorf("failed to parse place order response: %w", err)
	}
	
	if !response.Data.PlaceOrder.Success {
		msg := response.Data.PlaceOrder.Message
		if containsCI(msg, "3ds") || containsCI(msg, "challenge") || containsCI(msg, "verification") {
			return nil, fmt.Errorf("payment_challenge: %s", msg)
		}
		return nil, fmt.Errorf("order placement failed: %s", msg)
	}
	
	return &CheckoutResult{
		Success:           true,
		OrderID:           response.Data.PlaceOrder.OrderID,
		OrderNumber:       response.Data.PlaceOrder.OrderNumber,
		Total:             response.Data.PlaceOrder.Total,
		EstimatedDelivery: response.Data.PlaceOrder.EstimatedDelivery,
		Timestamp:         time.Now(),
	}, nil
}

// executeGraphQL executes a GraphQL query/mutation
func (c *Client) executeGraphQL(query string, variables map[string]interface{}) (string, error) {
	return graphql.Execute(c.session, c.px, "https://www.walmart.com/orchestra/graphql", query, variables)
}

// getHeaders returns common headers for requests
func (c *Client) getHeaders() map[string]string {
	return map[string]string{
		"Content-Type": "application/json",
		"Accept":       "application/json",
		"User-Agent":   "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
		"Origin":       "https://www.walmart.com",
		"Referer":      "https://www.walmart.com/checkout/",
	}
}

// containsCI checks substring case-insensitively
func containsCI(s, sub string) bool {
	s = strings.ToLower(s)
	sub = strings.ToLower(sub)
	return strings.Contains(s, sub)
}

// Response structures
type AddToCartResponse struct {
	Data struct {
		AddToCart struct {
			Success bool   `json:"success"`
			CartID  string `json:"cartId"`
			Message string `json:"message"`
		} `json:"addToCart"`
	} `json:"data"`
}

type DeliveryAddressesResponse struct {
	Data struct {
		Customer struct {
			Addresses []struct {
				ID          string `json:"id"`
				IsDefault   bool   `json:"isDefault"`
				City        string `json:"city"`
				State       string `json:"state"`
				PostalCode  string `json:"postalCode"`
			} `json:"addresses"`
		} `json:"customer"`
	} `json:"data"`
}

type PaymentMethodsResponse struct {
	Data struct {
		Customer struct {
			PaymentMethods []struct {
				ID        string `json:"id"`
				IsDefault bool   `json:"isDefault"`
				CardBrand string `json:"cardBrand"`
				LastFour  string `json:"lastFour"`
			} `json:"paymentMethods"`
		} `json:"customer"`
	} `json:"data"`
}

type OrderReview struct {
	OrderID       string  `json:"orderId"`
	CanPlaceOrder bool    `json:"canPlaceOrder"`
	Totals        struct {
		Total float64 `json:"total"`
	} `json:"totals"`
}

type ReviewOrderResponse struct {
	Data struct {
		ReviewOrder OrderReview `json:"reviewOrder"`
	} `json:"data"`
}

type PlaceOrderResponse struct {
	Data struct {
		PlaceOrder struct {
			Success           bool    `json:"success"`
			OrderID           string  `json:"orderId"`
			OrderNumber       string  `json:"orderNumber"`
			Total             float64 `json:"total"`
			EstimatedDelivery string  `json:"estimatedDelivery"`
			Message           string  `json:"message"`
		} `json:"placeOrder"`
	} `json:"data"`
}