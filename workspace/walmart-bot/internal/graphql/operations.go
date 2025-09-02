package graphql

import (
    "encoding/json"
    "fmt"
    "time"

    "github.com/agentwise/walmart-bot/internal/protection"
    "github.com/agentwise/walmart-bot/internal/tlsclient"
)

// Execute issues a GraphQL request through the shared TLS client session with
// PX integration, retries, and typed response body returned as string.
// Callers should unmarshal into their own response structs.
func Execute(session *tlsclient.Session, px *protection.PXSolver, endpoint string, query string, variables map[string]interface{}) (string, error) {
    if session == nil { return "", fmt.Errorf("nil session") }
    if px != nil { px.AttachToSession(session) }

    payload := map[string]any{
        "query":     query,
        "variables": variables,
    }
    b, err := json.Marshal(payload)
    if err != nil { return "", err }

    headers := map[string]string{
        "Content-Type": "application/json",
        "Accept":       "application/json",
        "User-Agent":   "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Origin":       "https://www.walmart.com",
        "Referer":      "https://www.walmart.com/",
    }

    // simple exponential backoff
    var resp *tlsclient.Response
    var lastErr error
    for attempt := 0; attempt < 3; attempt++ {
        resp, err = session.Post(endpoint, headers, string(b))
        if err != nil { lastErr = err } else {
            if px != nil && px.IsPXBlocked(resp) {
                if px.RecoverIfBlocked(session) {
                    lastErr = fmt.Errorf("px blocked; recovered; retrying")
                } else {
                    return "", fmt.Errorf("px blocked and recovery failed")
                }
            } else if resp.StatusCode >= 200 && resp.StatusCode < 300 {
                return resp.Body, nil
            } else {
                lastErr = fmt.Errorf("graphql status %d", resp.StatusCode)
            }
        }
        time.Sleep(time.Duration(500*(1<<attempt)) * time.Millisecond)
    }
    if lastErr == nil { lastErr = fmt.Errorf("graphql request failed") }
    return "", lastErr
}

// GraphQL operations for Walmart authentication and checkout

const (
	// GetLoginOptionsQuery checks if an account exists
	GetLoginOptionsQuery = `
		query GetLoginOptions($email: String!) {
			loginOptions(email: $email) {
				accountExists
				authMethods
				preferredMethod
			}
		}
	`

	// SignInWithPasswordMutation performs password authentication
	SignInWithPasswordMutation = `
		mutation SignInWithPassword($input: SignInInput!) {
			signIn(input: $input) {
				success
				requiresOtp
				token
				refreshToken
				customerId
				message
			}
		}
	`

	// GenerateOTPMutation requests an OTP code
	GenerateOTPMutation = `
		mutation GenerateOtp($input: GenerateOtpInput!) {
			generateOtp(input: $input) {
				success
				method
				maskedDestination
				expiresIn
				message
			}
		}
	`

	// VerifyOTPMutation verifies the OTP code
	VerifyOTPMutation = `
		mutation VerifyOtp($input: VerifyOtpInput!) {
			verifyOtp(input: $input) {
				success
				token
				refreshToken
				customerId
				message
			}
		}
	`

	// GetCartQuery retrieves current cart contents
	GetCartQuery = `
		query GetCart($cartId: String!) {
			cart(id: $cartId) {
				id
				items {
					id
					productId
					name
					quantity
					price
					inStock
				}
				subtotal
				tax
				total
				shipmentGroups {
					id
					deliveryOption
					items
				}
			}
		}
	`

	// AddToCartMutation adds an item to cart
	AddToCartMutation = `
		mutation AddToCart($input: AddToCartInput!) {
			addToCart(input: $input) {
				success
				cartId
				item {
					id
					productId
					quantity
					price
				}
				message
			}
		}
	`

	// GetDeliveryAddressesQuery retrieves saved addresses
	GetDeliveryAddressesQuery = `
		query GetDeliveryAddresses {
			customer {
				addresses {
					id
					isDefault
					firstName
					lastName
					addressLine1
					addressLine2
					city
					state
					postalCode
					country
					phone
				}
			}
		}
	`

	// GetPaymentMethodsQuery retrieves saved payment methods
	GetPaymentMethodsQuery = `
		query GetPaymentMethods {
			customer {
				paymentMethods {
					id
					isDefault
					type
					lastFour
					expiryMonth
					expiryYear
					cardBrand
					billingAddress {
						postalCode
					}
				}
			}
		}
	`

	// GetReviewOrderQuery retrieves order details for review
	GetReviewOrderQuery = `
		query GetReviewOrder($cartId: String!) {
			reviewOrder(cartId: $cartId) {
				orderId
				items {
					id
					name
					quantity
					price
					image
				}
				shipping {
					method
					cost
					estimatedDelivery
				}
				payment {
					method
					lastFour
				}
				totals {
					subtotal
					shipping
					tax
					total
				}
				canPlaceOrder
			}
		}
	`

	// PlaceOrderMutation submits the final order
	PlaceOrderMutation = `
		mutation PlaceOrder($input: PlaceOrderInput!) {
			placeOrder(input: $input) {
				success
				orderId
				orderNumber
				estimatedDelivery
				total
				message
				errors {
					code
					message
					field
				}
			}
		}
	`

	// GetInventoryStatusQuery checks product availability
	GetInventoryStatusQuery = `
		query GetInventoryStatus($productIds: [String!]!) {
			products(ids: $productIds) {
				id
				name
				inStock
				quantity
				maxQuantity
				price {
					current
					was
				}
				nextRestockDate
			}
		}
	`

	// RefreshTokenMutation refreshes authentication token
	RefreshTokenMutation = `
		mutation RefreshToken($refreshToken: String!) {
			refreshToken(token: $refreshToken) {
				success
				token
				refreshToken
				expiresIn
			}
		}
	`
)