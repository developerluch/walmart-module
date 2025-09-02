package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/agentwise/walmart-bot/internal/auth"
	"github.com/agentwise/walmart-bot/internal/checkout"
	"github.com/agentwise/walmart-bot/internal/inventory"
	"github.com/agentwise/walmart-bot/internal/logging"
	"github.com/agentwise/walmart-bot/internal/protection"
	"github.com/agentwise/walmart-bot/internal/proxy"
	"github.com/agentwise/walmart-bot/internal/tlsclient"
	"github.com/agentwise/walmart-bot/web/api"
	"github.com/joho/godotenv"
	"github.com/sirupsen/logrus"
)

var (
	configPath = flag.String("config", "config/config.json", "Path to configuration file")
	debugMode  = flag.Bool("debug", false, "Enable debug logging")
	dashboard  = flag.Bool("dashboard", true, "Enable monitoring dashboard")
	workers    = flag.Int("workers", 5, "Number of concurrent workers")
)

func main() {
	flag.Parse()

	// Load environment variables
	if err := godotenv.Load(); err != nil {
		log.Printf("Warning: .env file not found: %v", err)
	}

	// Initialize logger
	logger := logging.NewLogger(*debugMode)
	logger.Info("Starting Walmart Bot...")

	// Load configuration
	config, err := LoadConfig(*configPath)
	if err != nil {
		logger.Fatalf("Failed to load config: %v", err)
	}

	// Initialize TLS client
	tlsClient, err := tlsclient.NewClient()
	if err != nil {
		logger.Fatalf("Failed to initialize TLS client: %v", err)
	}
	defer tlsClient.Close()

	// TLS global toggles
	if config.Logging.CaptureRequests {
		tlsclient.SetCaptureRequests(true)
	}
	if config.Checkout.DelayMs > 0 {
		tlsclient.SetGlobalRateLimitMs(config.Checkout.DelayMs)
	}

	// Initialize proxy manager (optional)
	proxyManager, err := proxy.NewManager(config.Proxies)
	if err != nil {
		logger.Warnf("Failed to initialize proxy manager (continuing without proxies): %v", err)
		proxyManager = nil
	}

	// Initialize Discord logger
	discordLogger := logging.NewDiscordLogger(config.Logging.DiscordWebhook)
	if strings.TrimSpace(config.Logging.LogFile) != "" {
		logging.SetLogFile(logger, config.Logging.LogFile)
	}

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		logger.Info("Shutdown signal received")
		cancel()
	}()

	// Start monitoring dashboard if enabled
	if *dashboard {
		dashboardServer := api.NewServer(logger, config)
		go dashboardServer.Start(ctx, config.Monitoring.DashboardPort)
	}

	// Create worker pool
	var wg sync.WaitGroup
	queueSize := config.Queue.MaxQueueSize
	if queueSize <= 0 { queueSize = 100 }
	workQueue := make(chan WorkItem, queueSize)

	// Start workers
	effectiveWorkers := config.Queue.MaxWorkers
	if effectiveWorkers <= 0 { effectiveWorkers = *workers }
	for i := 0; i < effectiveWorkers; i++ {
		wg.Add(1)
		go worker(ctx, &wg, i, workQueue, &BotContext{
			Config:        config,
			TLSClient:     tlsClient,
			ProxyManager:  proxyManager,
			Logger:        logger,
			DiscordLogger: discordLogger,
			PXSolver:      protection.NewPXSolver(config.PX.ProtoDirectAPIKey, logger),
		})
	}

	// Main bot loop
	ticker := time.NewTicker(time.Duration(config.Checkout.DelayMs) * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logger.Info("Shutting down bot...")
			close(workQueue)
			wg.Wait()
			return

		case <-ticker.C:
			// Check inventory and create work items
			items := inventory.CheckInventory(ctx, config.Items)
			for _, item := range items {
				if item.InStock {
					workQueue <- WorkItem{
						ItemID:   item.ID,
						Quantity: 1,
						Type:     "checkout",
					}
				}
			}
		}
	}
}

type BotContext struct {
	Config        *Config
	TLSClient     *tlsclient.Client
	ProxyManager  *proxy.Manager
	Logger        *logrus.Logger
	DiscordLogger *logging.DiscordLogger
	PXSolver      *protection.PXSolver
}

type WorkItem struct {
	ItemID   string
	Quantity int
	Type     string
}

func worker(ctx context.Context, wg *sync.WaitGroup, id int, queue <-chan WorkItem, bot *BotContext) {
	defer wg.Done()
	bot.Logger.Infof("Worker %d started", id)

	for {
		select {
		case <-ctx.Done():
			bot.Logger.Infof("Worker %d stopping", id)
			return

		case item, ok := <-queue:
			if !ok {
				bot.Logger.Infof("Worker %d: queue closed", id)
				return
			}

			bot.Logger.Infof("Worker %d processing item: %s", id, item.ItemID)
			processWorkItem(ctx, bot, item)
		}
	}
}

func processWorkItem(ctx context.Context, bot *BotContext, item WorkItem) {
	// Create session (with proxy if available)
	var session *tlsclient.Session
	if bot.ProxyManager != nil {
		if currentProxy := bot.ProxyManager.GetNext(); currentProxy != nil {
			session = bot.TLSClient.NewSession(&tlsclient.Proxy{URL: currentProxy.URL, Username: currentProxy.Username, Password: currentProxy.Password, Failed: currentProxy.Failed})
		}
	}
	if session == nil {
		session = bot.TLSClient.NewSession(nil)
	}

	// Attach PX headers/cookies
	if bot.PXSolver != nil {
		bot.PXSolver.AttachToSession(session)
	}

	// Authenticate if needed
	if !session.IsAuthenticated() {
		authClient := auth.NewClient(session, bot.Logger, bot.PXSolver)
		if err := authClient.Login(bot.Config.Account.Email, bot.Config.Account.Password); err != nil {
			bot.Logger.Errorf("Authentication failed: %v", err)
			return
		}

		// Handle OTP if required
		if authClient.RequiresOTP() {
			otpHandler := auth.NewOTPHandler(session, auth.AccountConfig{
				Email:            bot.Config.Account.Email,
				OTPMethod:        bot.Config.Account.OTPMethod,
				GmailCredentials: bot.Config.Account.GmailCredentials,
			}, bot.Logger)
			if err := otpHandler.HandleOTP(); err != nil {
				bot.Logger.Errorf("OTP verification failed: %v", err)
				return
			}
		}
	}

	// Process checkout
	checkoutClient := checkout.NewClient(session, bot.Logger, bot.PXSolver, bot.Config.Checkout.PaymentMethodID)
	result, err := checkoutClient.ProcessCheckout(item.ItemID, item.Quantity)
	if err != nil {
		bot.Logger.Errorf("Checkout failed: %v", err)
		_ = bot.DiscordLogger.LogCheckoutFailure(item.ItemID, err)
		return
	}

	// Log success (detailed)
	bot.Logger.Infof("Checkout successful: %s", result.OrderID)
	_ = bot.DiscordLogger.LogCheckoutSummary(result, bot.Config.Account.Email, "")
}

type Config struct {
	Account struct {
		Email           string `json:"email"`
		Password        string `json:"password"`
		OTPMethod       string `json:"otpMethod"`
		GmailCredentials string `json:"gmailCredentials"`
	} `json:"account"`
	Checkout struct {
		AutoCheckout    bool   `json:"autoCheckout"`
		MaxRetries      int    `json:"maxRetries"`
		DelayMs         int    `json:"delayMs"`
		SavedPayment    bool   `json:"savedPayment"`
		PaymentMethodID string `json:"paymentMethodId"`
	} `json:"checkout"`
	Proxies proxy.Config `json:"proxies"`
	Logging struct {
		Level           string `json:"level"`
		CaptureRequests bool   `json:"captureRequests"`
		DiscordWebhook  string `json:"discordWebhook"`
		LogFile         string `json:"logFile"`
	} `json:"logging"`
	Monitoring struct {
		DashboardPort  int  `json:"dashboardPort"`
		MetricsEnabled bool `json:"metricsEnabled"`
		WebsocketPort  int  `json:"websocketPort"`
	} `json:"monitoring"`
	Items []string `json:"items"`
	Protection struct {
		UserAgent        string `json:"userAgent"`
		RandomizeTimings bool   `json:"randomizeTimings"`
		MinDelay         int    `json:"minDelay"`
		MaxDelay         int    `json:"maxDelay"`
		BrowserBehavior  bool   `json:"browserBehavior"`
	} `json:"protection"`
	Queue struct {
		MaxWorkers    int     `json:"maxWorkers"`
		MaxQueueSize  int     `json:"maxQueueSize"`
		RetryBackoff  float64 `json:"retryBackoff"`
		MaxRetryDelay int     `json:"maxRetryDelay"`
	} `json:"queue"`
	PX struct {
		ProtoDirectAPIKey string `json:"protoDirectApiKey"`
		Enabled           bool   `json:"enabled"`
	} `json:"px"`
}

func LoadConfig(path string) (*Config, error) {
	if path == "" {
		return nil, errors.New("empty config path")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	var cfg Config
	if err := json.Unmarshal(b, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if cfg.Monitoring.DashboardPort == 0 {
		cfg.Monitoring.DashboardPort = 8080
	}
	if cfg.Queue.MaxWorkers == 0 {
		cfg.Queue.MaxWorkers = 5
	}
	if cfg.Checkout.MaxRetries == 0 {
		cfg.Checkout.MaxRetries = 3
	}
	if cfg.Proxies.ListFile != "" && !filepath.IsAbs(cfg.Proxies.ListFile) {
		cfg.Proxies.ListFile = filepath.Clean(filepath.Join(filepath.Dir(path), cfg.Proxies.ListFile))
	}
	return &cfg, nil
}