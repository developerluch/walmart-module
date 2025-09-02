# Walmart Automation Bot - Pure Go Implementation

Advanced e-commerce automation bot with TLS fingerprinting, bot protection evasion, and complete checkout automation - now 100% Go!

## 🚀 Features

- **TLS Fingerprinting**: Chrome 120 fingerprint using Bogdan Finn's Go tls-client
- **Pure Go Implementation**: No Python dependencies required
- **Authentication**: Email/password login with OTP/2FA support
- **Checkout Automation**: Complete cart-to-order automation
- **Proxy Support**: HTTP/HTTPS/SOCKS5 with rotation and health checking
- **Bot Protection**: Advanced anti-detection measures
- **Monitoring Dashboard**: Real-time status and metrics
- **Discord Integration**: Checkout notifications and logging
- **Gmail Integration**: Automatic OTP retrieval (Go implementation)

## 🏗️ Architecture

```
├── cmd/                    # Application entry point
├── internal/               # Core business logic
│   ├── auth/              # Authentication & OTP
│   ├── tlsclient/         # Pure Go TLS fingerprinting
│   ├── checkout/          # Checkout automation
│   ├── inventory/         # Stock monitoring
│   ├── proxy/             # Proxy management
│   ├── protection/        # Anti-detection
│   ├── graphql/           # GraphQL operations
│   └── logging/           # Logging & Discord
├── pkg/                   # Shared packages
│   ├── gmail/             # Go Gmail API client
│   └── utils/             # Utilities
├── web/                   # Monitoring dashboard
└── config/                # Configuration files
```

## 📋 Prerequisites

### Required
- **Go 1.21+** - Primary language for all functionality
- **Gmail API credentials** (optional, for auto-OTP)

### NO Python Required! 
This is a pure Go implementation using the native Go version of Bogdan Finn's tls-client.

## 🔧 Installation

### 1. Clone the repository
```bash
git clone https://github.com/agentwise/walmart-bot
cd walmart-bot
```

### 2. Install Go dependencies
```bash
go mod download
go mod tidy
```

### 3. Configure the bot
```bash
cp config/config.example.json config/config.json
# Edit config/config.json with your settings
```

### 4. Build the bot
```bash
go build -o walmart-bot cmd/main.go
```

## ⚙️ Configuration

### Basic Configuration

```json
{
  "account": {
    "email": "your-email@example.com",
    "password": "your-password",
    "otpMethod": "email",
    "gmailCredentials": "config/gmail_credentials.json"
  },
  "checkout": {
    "autoCheckout": true,
    "delayMs": 3333,
    "savedPayment": true
  },
  "proxies": {
    "listFile": "config/proxies.txt",
    "rotateOnFailure": true,
    "healthCheckInterval": 60
  },
  "logging": {
    "discordWebhook": "https://discord.com/api/webhooks/...",
    "level": "info"
  },
  "monitoring": {
    "dashboardPort": 8080,
    "metricsEnabled": true
  },
  "items": [
    "https://www.walmart.com/ip/item-id-1",
    "https://www.walmart.com/ip/item-id-2"
  ]
}
```

### Gmail Integration (Optional)

1. Enable Gmail API in Google Cloud Console
2. Download credentials JSON
3. Place in `config/gmail_credentials.json`
4. Run the bot - it will prompt for OAuth authorization on first run

### Proxy Configuration

Add proxies to `config/proxies.txt`:
```
http://proxy1.example.com:8080
http://user:pass@proxy2.example.com:8080
socks5://proxy3.example.com:1080
```

## 🚀 Usage

### Running the Bot

```bash
# Basic usage
./walmart-bot

# With custom config
./walmart-bot -config custom-config.json

# Debug mode
./walmart-bot -debug

# With more workers
./walmart-bot -workers 10

# With dashboard disabled
./walmart-bot -dashboard=false
```

### Docker Deployment

```bash
# Build image
docker build -t walmart-bot .

# Run container
docker run -v $(pwd)/config:/app/config walmart-bot
```

## 🛡️ TLS Fingerprinting

The bot uses Bogdan Finn's Go tls-client library for advanced TLS fingerprinting:

- **Chrome 120 Profile**: Exact browser fingerprint
- **JA3/JA4 Signatures**: Matching Chrome 120
- **H2 Settings**: Proper HTTP/2 configuration
- **Header Order**: Chrome-specific header ordering
- **Cipher Suites**: Exact Chrome 120 cipher configuration

## 📊 Monitoring Dashboard

Access the web dashboard at `http://localhost:8080`:

- Real-time bot status
- Success/failure metrics
- Proxy health monitoring
- Order history
- Live request/response logs
- WebSocket for real-time updates

## 🔌 API Endpoints

- `GET /api/status` - Bot status
- `GET /api/metrics` - Performance metrics
- `GET /api/proxies` - Proxy statistics
- `GET /api/orders` - Order history
- `GET /api/config` - Current configuration
- `WS /ws` - WebSocket for real-time updates

## 🧪 Testing

```bash
# Run all tests
go test ./...

# Run with coverage
go test -cover ./...

# Run specific package tests
go test ./internal/tlsclient

# Run with verbose output
go test -v ./...

# Run benchmarks
go test -bench=. ./...
```

## 🏗️ Building

### Cross-Platform Builds

```bash
# Windows
GOOS=windows GOARCH=amd64 go build -o walmart-bot.exe cmd/main.go

# macOS Intel
GOOS=darwin GOARCH=amd64 go build -o walmart-bot-mac cmd/main.go

# macOS Apple Silicon
GOOS=darwin GOARCH=arm64 go build -o walmart-bot-m1 cmd/main.go

# Linux
GOOS=linux GOARCH=amd64 go build -o walmart-bot-linux cmd/main.go
```

## 🐛 Troubleshooting

### Common Issues

1. **Build Errors**
   ```bash
   go mod download
   go mod tidy
   ```

2. **TLS Client Issues**
   ```bash
   # Update to latest version
   go get -u github.com/bogdanfinn/tls-client
   ```

3. **Proxy Connection Failed**
   - Verify proxy format in `proxies.txt`
   - Test proxies manually
   - Check proxy authentication

4. **OTP Not Received**
   - Check Gmail API credentials
   - Verify OAuth token is valid
   - Check email filters

## 🔒 Security Considerations

- **Never commit credentials** to version control
- **Use environment variables** for sensitive data
- **Rotate proxies regularly** to avoid detection
- **Monitor rate limits** to prevent bans
- **Use secure credential storage** for production

## 📈 Performance

The pure Go implementation provides:
- **Faster execution** compared to Python bridge
- **Lower memory usage** with efficient goroutines
- **Better concurrency** with native Go channels
- **Improved stability** with single-language stack

## 🤝 Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing`)
5. Open Pull Request

## 📄 License

MIT License - See LICENSE file for details

## ⚠️ Legal Disclaimer

This bot is for educational purposes only. Users are responsible for:
- Complying with Walmart's Terms of Service
- Following local laws and regulations
- Using the bot ethically and responsibly
- Respecting rate limits and server resources

## 🙏 Acknowledgments

- [Bogdan Finn's tls-client](https://github.com/bogdanfinn/tls-client) - Go TLS fingerprinting
- [Agentwise Framework](https://github.com/agentwise/agentwise) - Multi-agent orchestration
- Community contributors

## 📞 Support

- Issues: [GitHub Issues](https://github.com/agentwise/walmart-bot/issues)
- Discord: [Join our server](https://discord.gg/example)
- Email: support@example.com