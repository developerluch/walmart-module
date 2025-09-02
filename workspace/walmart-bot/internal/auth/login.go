package auth

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/agentwise/walmart-bot/internal/graphql"
	"github.com/agentwise/walmart-bot/internal/protection"
	"github.com/agentwise/walmart-bot/internal/tlsclient"
	"github.com/sirupsen/logrus"
)

type AuthClient struct {
	session   *tlsclient.Session
	logger    *logrus.Logger
	needsOTP  bool
	authToken string
	px        *protection.PXSolver
	refreshToken string
}

// NewClient creates a new authentication client
func NewClient(session *tlsclient.Session, logger *logrus.Logger, px *protection.PXSolver) *AuthClient {
	return &AuthClient{
		session: session,
		logger:  logger,
		px:      px,
	}
}

// Login performs email/password authentication
func (ac *AuthClient) Login(email, password string) error {
	ac.logger.Info("Starting authentication process")
	
	// Pre-flight homepage to establish baseline cookies/CSRF
	ac.bootstrapSession()
	
	// Step 1: Get login options
	loginOptions, err := ac.getLoginOptions(email)
	if err != nil {
		return fmt.Errorf("failed to get login options: %w", err)
	}
	
	// Step 2: Check if account exists
	if !loginOptions.AccountExists {
		return fmt.Errorf("account not found for email: %s", email)
	}
	
	// Step 3: Perform password authentication
	authResult, err := ac.signInWithPassword(email, password)
	if err != nil {
		return fmt.Errorf("password authentication failed: %w", err)
	}
	
	// Check if OTP is required
	if authResult.RequiresOTP {
		ac.needsOTP = true
		ac.logger.Info("OTP verification required")
		return nil
	}
	
	// Store tokens
	ac.authToken = authResult.Token
	ac.refreshToken = authResult.RefreshToken
	ac.session.SetAuthenticated(true)
	ac.session.SetAuthToken(ac.authToken)
	
	// Verify session
	if err := ac.verifySession(); err != nil {
		return fmt.Errorf("session verification failed: %w", err)
	}
	
	ac.logger.Info("Authentication successful")
	return nil
}

// getLoginOptions checks if account exists
func (ac *AuthClient) getLoginOptions(email string) (*LoginOptionsResponse, error) {
	query := graphql.GetLoginOptionsQuery
	variables := map[string]interface{}{
		"email": email,
	}
	
	body, err := ac.executeGraphQL(query, variables)
	if err != nil {
		return nil, err
	}
	
	var response LoginOptionsResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return nil, fmt.Errorf("failed to parse login options: %w", err)
	}
	
	return &response, nil
}

// signInWithPassword performs password authentication
func (ac *AuthClient) signInWithPassword(email, password string) (*AuthResponse, error) {
	query := graphql.SignInWithPasswordMutation
	variables := map[string]interface{}{
		"input": map[string]interface{}{
			"email":    email,
			"password": password,
		},
	}
	
	body, err := ac.executeGraphQL(query, variables)
	if err != nil {
		return nil, err
	}
	
	var response AuthResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return nil, fmt.Errorf("failed to parse auth response: %w", err)
	}
	
	return &response, nil
}

// verifySession validates the authenticated session
func (ac *AuthClient) verifySession() error {
	headers := map[string]string{
		"Authorization": fmt.Sprintf("Bearer %s", ac.authToken),
		"Accept":        "application/json",
		"User-Agent":    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
	}
	
	resp, err := ac.session.Get("https://www.walmart.com/account/api/customer/me", headers)
	if err != nil {
		return fmt.Errorf("session verification request failed: %w", err)
	}
	
	if resp.StatusCode != 200 {
		return fmt.Errorf("session verification failed with status: %d", resp.StatusCode)
	}
	
	var out map[string]interface{}
	if err := json.Unmarshal([]byte(resp.Body), &out); err != nil {
		return fmt.Errorf("failed to parse session response: %w", err)
	}
	if _, ok := out["customerId"]; !ok {
		return fmt.Errorf("invalid session response: missing customerId")
	}
	
	return nil
}

// executeGraphQL executes a GraphQL query/mutation via central executor
func (ac *AuthClient) executeGraphQL(query string, variables map[string]interface{}) (string, error) {
	return graphql.Execute(ac.session, ac.px, "https://identity.walmart.com/orchestra/idp/graphql", query, variables)
}

// bootstrapSession makes a pre-flight request to establish CSRF/cookies where required
func (ac *AuthClient) bootstrapSession() {
	_, _ = ac.session.Get("https://www.walmart.com/", map[string]string{})
}

// RefreshSession refreshes the auth token using the refresh token (if present)
func (ac *AuthClient) RefreshSession() error {
	if strings.TrimSpace(ac.refreshToken) == "" { return fmt.Errorf("no refresh token") }
	vars := map[string]interface{}{"refreshToken": ac.refreshToken}
	body, err := graphql.Execute(ac.session, ac.px, "https://identity.walmart.com/orchestra/idp/graphql", graphql.RefreshTokenMutation, vars)
	if err != nil { return err }
	var resp struct {
		Data struct {
			RefreshToken struct {
				Success bool   `json:"success"`
				Token   string `json:"token"`
				RefreshToken string `json:"refreshToken"`
			} `json:"refreshToken"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &resp); err != nil { return err }
	if !resp.Data.RefreshToken.Success { return fmt.Errorf("refresh failed") }
	ac.authToken = resp.Data.RefreshToken.Token
	ac.refreshToken = resp.Data.RefreshToken.RefreshToken
	ac.session.SetAuthToken(ac.authToken)
	ac.session.SetAuthenticated(true)
	return nil
}

// RequiresOTP returns whether OTP verification is needed
func (ac *AuthClient) RequiresOTP() bool {
	return ac.needsOTP
}

// GetAuthToken returns the authentication token
func (ac *AuthClient) GetAuthToken() string {
	return ac.authToken
}

// Response structures
type LoginOptionsResponse struct {
	Data struct {
		LoginOptions struct {
			AccountExists bool `json:"accountExists"`
		} `json:"loginOptions"`
	} `json:"data"`
	AccountExists bool `json:"accountExists"`
}

type AuthResponse struct {
	Data struct {
		SignIn struct {
			Success       bool   `json:"success"`
			RequiresOTP   bool   `json:"requiresOtp"`
			Token         string `json:"token"`
			RefreshToken  string `json:"refreshToken"`
			Message       string `json:"message"`
		} `json:"signIn"`
	} `json:"data"`
	RequiresOTP  bool   `json:"requiresOtp"`
	Token        string `json:"token"`
	RefreshToken string `json:"refreshToken"`
}