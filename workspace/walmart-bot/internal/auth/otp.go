package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/agentwise/walmart-bot/internal/graphql"
	"github.com/agentwise/walmart-bot/internal/tlsclient"
	"github.com/agentwise/walmart-bot/pkg/gmail"
	"github.com/sirupsen/logrus"
)

type AccountConfig struct {
	Email            string
	OTPMethod        string
	GmailCredentials string
}

type OTPHandler struct {
	session   *tlsclient.Session
	account   AccountConfig
	logger    *logrus.Logger
	gmailClient *gmail.Client
}

// NewOTPHandler creates a new OTP handler
func NewOTPHandler(session *tlsclient.Session, account AccountConfig, logger *logrus.Logger) *OTPHandler {
	handler := &OTPHandler{
		session: session,
		account: account,
		logger:  logger,
	}
	
	// Initialize Gmail client if credentials are provided
	if credsPath := account.GmailCredentials; credsPath != "" {
		gmailClient, err := gmail.NewClient(credsPath)
		if err != nil {
			logger.Warnf("Failed to initialize Gmail client: %v", err)
		} else {
			handler.gmailClient = gmailClient
		}
	}
	
	return handler
}

// HandleOTP manages the complete OTP verification flow
func (oh *OTPHandler) HandleOTP() error {
	oh.logger.Info("Starting OTP verification process")
	
	// Get OTP method preference
	otpMethod := strings.TrimSpace(oh.account.OTPMethod)
	if otpMethod == "" {
		otpMethod = "email" // Default to email
	}
	
	// Request OTP
	if err := oh.requestOTP(otpMethod); err != nil {
		return fmt.Errorf("failed to request OTP: %w", err)
	}
	
	// Wait and retrieve OTP
	otpCode, err := oh.retrieveOTP(otpMethod)
	if err != nil {
		return fmt.Errorf("failed to retrieve OTP: %w", err)
	}
	
	// Verify OTP
	if err := oh.verifyOTP(otpCode); err != nil {
		return fmt.Errorf("failed to verify OTP: %w", err)
	}
	
	oh.logger.Info("OTP verification successful")
	return nil
}

// requestOTP sends OTP to the specified method
func (oh *OTPHandler) requestOTP(method string) error {
	oh.logger.Infof("Requesting OTP via %s", method)
	
	mutation := graphql.GenerateOTPMutation
	variables := map[string]interface{}{
		"input": map[string]interface{}{
			"method": method,
			"email":  oh.account.Email,
		},
	}
	
	body, err := oh.executeGraphQL(mutation, variables)
	if err != nil {
		return err
	}
	
	var response OTPRequestResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return fmt.Errorf("failed to parse OTP request response: %w", err)
	}
	
	if !response.Data.GenerateOTP.Success {
		return fmt.Errorf("OTP request failed: %s", response.Data.GenerateOTP.Message)
	}
	
	oh.logger.Info("OTP sent successfully")
	return nil
}

// retrieveOTP gets the OTP code from email or prompts for manual input
func (oh *OTPHandler) retrieveOTP(method string) (string, error) {
	if method == "email" && oh.gmailClient != nil {
		// Try to auto-fetch from Gmail
		oh.logger.Info("Attempting to auto-fetch OTP from Gmail...")
		
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		
		// Poll for OTP email
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		
		for {
			select {
			case <-ctx.Done():
				oh.logger.Warn("Timeout waiting for OTP email")
				return oh.promptForOTP()
			
			case <-ticker.C:
				otp, err := oh.gmailClient.GetLatestOTP("from:walmart.com", 5*time.Minute)
				if err != nil {
					oh.logger.Debugf("Gmail check failed: %v", err)
					continue
				}
				
				if otp != "" {
					oh.logger.Infof("OTP retrieved from Gmail: %s", otp)
					return otp, nil
				}
			}
		}
	}
	
	// Fallback to manual input
	return oh.promptForOTP()
}

// promptForOTP prompts for manual OTP input
func (oh *OTPHandler) promptForOTP() (string, error) {
	oh.logger.Info("Manual OTP input required")
	
	// In a real implementation, this would show a dialog or read from stdin
	// For now, we'll simulate with a placeholder
	fmt.Println("Please enter the OTP code:")
	
	var otp string
	fmt.Scanln(&otp)
	
	// Validate OTP format (usually 6 digits)
	otp = strings.TrimSpace(otp)
	if len(otp) != 6 {
		return "", fmt.Errorf("invalid OTP format: expected 6 digits, got %d", len(otp))
	}
	
	return otp, nil
}

// verifyOTP submits the OTP code for verification
func (oh *OTPHandler) verifyOTP(code string) error {
	oh.logger.Infof("Verifying OTP: %s", code)
	
	mutation := graphql.VerifyOTPMutation
	variables := map[string]interface{}{
		"input": map[string]interface{}{
			"code":  code,
			"email": oh.account.Email,
		},
	}
	
	body, err := oh.executeGraphQL(mutation, variables)
	if err != nil {
		return err
	}
	
	var response OTPVerifyResponse
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		return fmt.Errorf("failed to parse OTP verify response: %w", err)
	}
	
	if !response.Data.VerifyOTP.Success {
		return fmt.Errorf("OTP verification failed: %s", response.Data.VerifyOTP.Message)
	}
	
	// Mark session as authenticated
	oh.session.SetAuthenticated(true)
	// Attach token to session if provided
	if response.Data.VerifyOTP.Token != "" {
		oh.session.SetAuthToken(response.Data.VerifyOTP.Token)
	}
	
	return nil
}

// executeGraphQL executes a GraphQL query/mutation
func (oh *OTPHandler) executeGraphQL(query string, variables map[string]interface{}) (string, error) {
	payload := map[string]interface{}{
		"query":     query,
		"variables": variables,
	}
	
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("failed to marshal payload: %w", err)
	}
	
	headers := map[string]string{
		"Content-Type": "application/json",
		"Accept":       "application/json",
		"User-Agent":   "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
		"Origin":       "https://www.walmart.com",
		"Referer":      "https://www.walmart.com/",
	}
	
	// Add existing cookies
	cookies := oh.session.GetCookies()
	if sessionCookie, ok := cookies["_session"]; ok {
		headers["Cookie"] = fmt.Sprintf("_session=%s", sessionCookie)
	}
	
	resp, err := oh.session.Post(
		"https://identity.walmart.com/orchestra/idp/graphql",
		headers,
		string(payloadJSON),
	)
	
	if err != nil {
		return "", fmt.Errorf("GraphQL request failed: %w", err)
	}
	
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("GraphQL request failed with status: %d, body: %s", resp.StatusCode, resp.Body)
	}
	
	return resp.Body, nil
}

// Response structures
type OTPRequestResponse struct {
	Data struct {
		GenerateOTP struct {
			Success bool   `json:"success"`
			Message string `json:"message"`
		} `json:"generateOtp"`
	} `json:"data"`
}

type OTPVerifyResponse struct {
	Data struct {
		VerifyOTP struct {
			Success bool   `json:"success"`
			Token   string `json:"token"`
			Message string `json:"message"`
		} `json:"verifyOtp"`
	} `json:"data"`
}