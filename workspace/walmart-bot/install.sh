#!/bin/bash

echo "======================================"
echo "Walmart Bot (Pure Go) Installer"
echo "======================================"

# Detect OS
OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    OS="windows"
fi

echo "Detected OS: $OS"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check and install Go
echo "Checking Go installation..."
if ! command_exists go; then
    echo "❌ Go is not installed"
    echo ""
    echo "Please install Go 1.21 or later:"
    echo ""
    if [[ "$OS" == "macos" ]]; then
        echo "  Using Homebrew:"
        echo "    brew install go"
        echo ""
        echo "  Or download from:"
        echo "    https://go.dev/dl/"
    elif [[ "$OS" == "linux" ]]; then
        echo "  Using apt (Ubuntu/Debian):"
        echo "    sudo apt update && sudo apt install golang-go"
        echo ""
        echo "  Using yum (RHEL/CentOS):"
        echo "    sudo yum install golang"
        echo ""
        echo "  Or download from:"
        echo "    https://go.dev/dl/"
    else
        echo "  Download from:"
        echo "    https://go.dev/dl/"
    fi
    echo ""
    echo "After installing Go, run this script again."
    exit 1
else
    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    echo "✅ Go is installed: version $GO_VERSION"
    
    # Check Go version is 1.21+
    REQUIRED_GO="1.21"
    if [ "$(printf '%s\n' "$REQUIRED_GO" "$GO_VERSION" | sort -V | head -n1)" != "$REQUIRED_GO" ]; then 
        echo "⚠️  Warning: Go version $GO_VERSION is older than recommended $REQUIRED_GO"
        echo "   Please consider upgrading to Go 1.21 or later"
    fi
fi

echo ""
echo "Installing Go dependencies..."
echo "======================================"

# Download Go modules
go mod download
if [ $? -ne 0 ]; then
    echo "❌ Failed to download Go modules"
    exit 1
fi

# Tidy up modules
go mod tidy
if [ $? -ne 0 ]; then
    echo "❌ Failed to tidy Go modules"
    exit 1
fi

echo "✅ Go dependencies installed"

echo ""
echo "Creating project structure..."
echo "======================================"

# Create necessary directories
mkdir -p config logs web/dashboard

# Create default config if not exists
if [ ! -f config/config.json ]; then
    echo "Creating default configuration..."
    cat > config/config.json << 'EOF'
{
  "account": {
    "email": "user@example.com",
    "password": "your_password_here",
    "otpMethod": "email",
    "gmailCredentials": ""
  },
  "checkout": {
    "autoCheckout": true,
    "maxRetries": 3,
    "delayMs": 3333,
    "savedPayment": true
  },
  "proxies": {
    "listFile": "config/proxies.txt",
    "rotateOnFailure": true,
    "healthCheckInterval": 60
  },
  "logging": {
    "level": "info",
    "captureRequests": true,
    "discordWebhook": "",
    "logFile": "logs/walmart-bot.log"
  },
  "monitoring": {
    "dashboardPort": 8080,
    "metricsEnabled": true
  },
  "items": []
}
EOF
    echo "✅ Created default configuration"
else
    echo "✅ Configuration file already exists"
fi

# Create empty proxy file if not exists
if [ ! -f config/proxies.txt ]; then
    cat > config/proxies.txt << 'EOF'
# Add your proxies here, one per line
# Format examples:
# http://proxy.example.com:8080
# http://user:pass@proxy.example.com:8080
# socks5://proxy.example.com:1080
EOF
    echo "✅ Created proxy file template"
fi

echo ""
echo "Building the bot..."
echo "======================================"

# Build the bot
go build -o walmart-bot cmd/main.go
if [ $? -ne 0 ]; then
    echo "❌ Failed to build the bot"
    echo "   Please check for compilation errors above"
    exit 1
fi

echo "✅ Bot built successfully"

echo ""
echo "======================================"
echo "✅ Installation Complete!"
echo "======================================"
echo ""
echo "The Walmart Bot has been successfully installed!"
echo ""
echo "Next steps:"
echo "1. Edit config/config.json with your Walmart account details"
echo "2. Add item URLs to monitor in config/config.json"
echo "3. (Optional) Add proxies to config/proxies.txt"
echo "4. (Optional) Set up Gmail API for auto-OTP"
echo "5. (Optional) Configure Discord webhook for notifications"
echo ""
echo "To run the bot:"
echo "  ./walmart-bot"
echo ""
echo "For help:"
echo "  ./walmart-bot -help"
echo ""
echo "To verify installation:"
echo "  ./verify.sh"