package gmail

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"regexp"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
	"google.golang.org/api/gmail/v1"
	"google.golang.org/api/option"
)

// Client wraps Gmail API client
type Client struct {
	service *gmail.Service
	userID  string
}

// NewClient creates a new Gmail client
func NewClient(credentialsPath string) (*Client, error) {
	ctx := context.Background()

	// Read credentials file
	b, err := os.ReadFile(credentialsPath)
	if err != nil {
		return nil, fmt.Errorf("unable to read credentials file: %w", err)
	}

	// Parse OAuth2 config
	config, err := google.ConfigFromJSON(b, gmail.GmailReadonlyScope)
	if err != nil {
		return nil, fmt.Errorf("unable to parse client config: %w", err)
	}

	// Get token from cache or prompt for authorization
	token, err := getToken(config)
	if err != nil {
		return nil, fmt.Errorf("unable to get token: %w", err)
	}

	// Create Gmail service
	service, err := gmail.NewService(ctx, option.WithTokenSource(config.TokenSource(ctx, token)))
	if err != nil {
		return nil, fmt.Errorf("unable to create Gmail service: %w", err)
	}

	return &Client{
		service: service,
		userID:  "me",
	}, nil
}

// GetLatestOTP searches for the latest OTP in emails
func (c *Client) GetLatestOTP(query string, maxAge time.Duration) (string, error) {
	// Calculate time filter
	after := time.Now().Add(-maxAge).Unix()
	fullQuery := fmt.Sprintf("%s after:%d", query, after)

	// List messages
	call := c.service.Users.Messages.List(c.userID).Q(fullQuery).MaxResults(10)
	response, err := call.Do()
	if err != nil {
		return "", fmt.Errorf("unable to list messages: %w", err)
	}

	if len(response.Messages) == 0 {
		return "", fmt.Errorf("no messages found")
	}

	// Check each message for OTP
	for _, msg := range response.Messages {
		message, err := c.service.Users.Messages.Get(c.userID, msg.Id).Do()
		if err != nil {
			continue
		}

		// Extract body
		body := extractBody(message.Payload)
		
		// Look for OTP patterns
		otp := extractOTP(body)
		if otp != "" {
			return otp, nil
		}
	}

	return "", fmt.Errorf("no OTP found in recent emails")
}

// extractBody extracts the body from Gmail message payload
func extractBody(payload *gmail.MessagePart) string {
	var body string

	// Check parts
	if payload.Parts != nil {
		for _, part := range payload.Parts {
			if part.MimeType == "text/plain" || part.MimeType == "text/html" {
				data, err := base64.URLEncoding.DecodeString(part.Body.Data)
				if err == nil {
					body += string(data)
				}
			}
			// Recursively check nested parts
			if part.Parts != nil {
				body += extractBody(part)
			}
		}
	}

	// Check direct body
	if payload.Body != nil && payload.Body.Data != "" {
		data, err := base64.URLEncoding.DecodeString(payload.Body.Data)
		if err == nil {
			body += string(data)
		}
	}

	return body
}

// extractOTP finds OTP codes in text
func extractOTP(text string) string {
	// Common OTP patterns
	patterns := []string{
		`\b(\d{6})\b`,                          // 6 digits
		`code:\s*(\d{6})`,                      // "code: 123456"
		`verification code:\s*(\d{6})`,         // "verification code: 123456"
		`OTP:\s*(\d{6})`,                       // "OTP: 123456"
		`Your code is:\s*(\d{6})`,             // "Your code is: 123456"
		`Enter this code:\s*(\d{6})`,          // "Enter this code: 123456"
	}

	for _, pattern := range patterns {
		re := regexp.MustCompile(pattern)
		matches := re.FindStringSubmatch(text)
		if len(matches) > 1 {
			return matches[1]
		}
	}

	return ""
}

// getToken retrieves a token from cache or prompts for authorization
func getToken(config *oauth2.Config) (*oauth2.Token, error) {
	// Token cache file
	tokFile := "token.json"
	
	// Try to read cached token
	tok, err := tokenFromFile(tokFile)
	if err != nil {
		// Get new token
		tok = getTokenFromWeb(config)
		saveToken(tokFile, tok)
	}
	
	return tok, nil
}

// getTokenFromWeb requests a token from the web
func getTokenFromWeb(config *oauth2.Config) *oauth2.Token {
	authURL := config.AuthCodeURL("state-token", oauth2.AccessTypeOffline)
	fmt.Printf("Go to the following link in your browser:\n%v\n", authURL)
	fmt.Print("Enter authorization code: ")

	var authCode string
	if _, err := fmt.Scan(&authCode); err != nil {
		log.Fatalf("Unable to read authorization code: %v", err)
	}

	tok, err := config.Exchange(context.Background(), authCode)
	if err != nil {
		log.Fatalf("Unable to retrieve token: %v", err)
	}
	
	return tok
}

// tokenFromFile retrieves a token from file
func tokenFromFile(file string) (*oauth2.Token, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	
	tok := &oauth2.Token{}
	err = json.NewDecoder(f).Decode(tok)
	return tok, err
}

// saveToken saves a token to file
func saveToken(path string, token *oauth2.Token) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		log.Fatalf("Unable to cache oauth token: %v", err)
	}
	defer f.Close()
	
	json.NewEncoder(f).Encode(token)
}