# Walmart Bot Prerequisites & Installation Guide

## System Requirements

### Operating System
- **macOS**: 10.15+ (Catalina or later)
- **Linux**: Ubuntu 20.04+, Debian 10+, CentOS 8+
- **Windows**: Windows 10+ with WSL2 (Windows Subsystem for Linux)

### Required Software

## 1. Go Language (Required for Bot Core)

### Installation
```bash
# macOS
brew install go

# Linux (Ubuntu/Debian)
sudo apt update
sudo apt install golang-go

# Linux (CentOS/RHEL)
sudo yum install golang

# Windows
# Download from https://go.dev/dl/
```

### Verify Installation
```bash
go version
# Should output: go version go1.21.x
```

### Set Go Environment Variables
```bash
# Add to ~/.bashrc or ~/.zshrc
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
```

## 2. Python 3.9+ (Required for TLS Client)

### Installation
```bash
# macOS
brew install python@3.9

# Linux (Ubuntu/Debian)
sudo apt update
sudo apt install python3.9 python3-pip

# Windows (via WSL2)
sudo apt install python3.9 python3-pip
```

### Verify Installation
```bash
python3 --version
# Should output: Python 3.9.x or higher
```

## 3. Python Dependencies

### Core Dependencies
```bash
# Install all required Python packages
pip3 install --user \
    tls-client==1.0.1 \
    requests==2.31.0 \
    google-auth==2.25.2 \
    google-api-python-client==2.108.0 \
    python-dotenv==1.0.0 \
    typing-extensions==4.15.0
```

### Alternative: Using requirements.txt
```bash
pip3 install -r requirements.txt --user
```

### Troubleshooting Python Packages
```bash
# If you encounter SSL errors
pip3 install --upgrade certifi

# If tls-client fails to install
pip3 install --upgrade pip setuptools wheel
pip3 install tls-client --no-cache-dir

# For M1/M2 Macs
arch -x86_64 pip3 install tls-client
```

## 4. Go Dependencies

### Initialize Go Module
```bash
cd workspace/walmart-bot
go mod init github.com/agentwise/walmart-bot
go mod tidy
```

### Install Required Go Packages
```bash
go get github.com/gorilla/mux@v1.8.1
go get github.com/gorilla/websocket@v1.5.1
go get github.com/joho/godotenv@v1.5.1
go get github.com/sirupsen/logrus@v1.9.3
go get golang.org/x/oauth2@v0.15.0
go get google.golang.org/api@v0.154.0
```

## 5. Gmail API Setup (Optional - for Auto-OTP)

### Steps:
1. **Enable Gmail API**
   ```bash
   # Visit Google Cloud Console
   https://console.cloud.google.com/
   
   # Create new project or select existing
   # Enable Gmail API
   # Create OAuth 2.0 credentials
   ```

2. **Download Credentials**
   - Download `credentials.json`
   - Place in `config/gmail_credentials.json`

3. **Authenticate**
   ```python
   # Run authentication script
   python3 scripts/gmail_auth.py
   ```

## 6. Discord Webhook (Optional - for Notifications)

### Setup:
1. Open Discord Server Settings
2. Navigate to Integrations > Webhooks
3. Create New Webhook
4. Copy Webhook URL
5. Add to `config/config.json`:
   ```json
   {
     "logging": {
       "discordWebhook": "YOUR_WEBHOOK_URL_HERE"
     }
   }
   ```

## 7. Proxy Configuration (Optional)

### Format for proxies.txt:
```
# HTTP Proxies
http://proxy1.example.com:8080
http://user:pass@proxy2.example.com:8080

# HTTPS Proxies
https://proxy3.example.com:8080

# SOCKS5 Proxies
socks5://proxy4.example.com:1080
socks5://user:pass@proxy5.example.com:1080
```

### Create proxy file:
```bash
touch config/proxies.txt
# Add your proxies to this file
```

## 8. System Libraries

### macOS
```bash
# Install Xcode Command Line Tools
xcode-select --install

# Install Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Linux (Ubuntu/Debian)
```bash
sudo apt update
sudo apt install -y \
    build-essential \
    curl \
    git \
    libssl-dev \
    pkg-config
```

### Linux (CentOS/RHEL)
```bash
sudo yum groupinstall -y "Development Tools"
sudo yum install -y \
    openssl-devel \
    git \
    curl
```

## Complete Installation Script

Save this as `install.sh`:
```bash
#!/bin/bash

echo "======================================"
echo "Walmart Bot Prerequisites Installer"
echo "======================================"

# Detect OS
OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
fi

echo "Detected OS: $OS"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install Go
if ! command_exists go; then
    echo "Installing Go..."
    if [[ "$OS" == "macos" ]]; then
        brew install go
    elif [[ "$OS" == "linux" ]]; then
        sudo apt update && sudo apt install -y golang-go
    fi
else
    echo "✓ Go is installed: $(go version)"
fi

# Install Python 3.9+
if ! command_exists python3; then
    echo "Installing Python..."
    if [[ "$OS" == "macos" ]]; then
        brew install python@3.9
    elif [[ "$OS" == "linux" ]]; then
        sudo apt update && sudo apt install -y python3.9 python3-pip
    fi
else
    echo "✓ Python is installed: $(python3 --version)"
fi

# Install Python packages
echo "Installing Python dependencies..."
pip3 install --user \
    tls-client \
    requests \
    google-auth \
    google-api-python-client \
    python-dotenv \
    typing-extensions

# Initialize Go module
echo "Initializing Go module..."
go mod init github.com/agentwise/walmart-bot 2>/dev/null
go mod tidy

# Create necessary directories
echo "Creating project structure..."
mkdir -p config logs

# Create default config if not exists
if [ ! -f config/config.json ]; then
    echo "Creating default config..."
    cat > config/config.json << 'EOF'
{
  "account": {
    "email": "user@example.com",
    "password": "your_password_here",
    "otpMethod": "email"
  },
  "checkout": {
    "autoCheckout": true,
    "delayMs": 3333
  },
  "proxies": {
    "listFile": "config/proxies.txt",
    "rotateOnFailure": true
  },
  "logging": {
    "level": "info",
    "discordWebhook": ""
  },
  "monitoring": {
    "dashboardPort": 8080
  },
  "items": []
}
EOF
fi

echo ""
echo "======================================"
echo "Installation Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "1. Edit config/config.json with your account details"
echo "2. Add items to monitor in config/config.json"
echo "3. (Optional) Add proxies to config/proxies.txt"
echo "4. (Optional) Set up Gmail API for auto-OTP"
echo "5. Build the bot: go build -o walmart-bot cmd/main.go"
echo "6. Run the bot: ./walmart-bot"
```

## Verification Script

Save this as `verify.sh`:
```bash
#!/bin/bash

echo "======================================"
echo "Walmart Bot Prerequisites Verification"
echo "======================================"

ERRORS=0

# Check Go
if command -v go >/dev/null 2>&1; then
    echo "✅ Go: $(go version)"
else
    echo "❌ Go: Not installed"
    ERRORS=$((ERRORS + 1))
fi

# Check Python
if command -v python3 >/dev/null 2>&1; then
    VERSION=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    if (( $(echo "$VERSION >= 3.9" | bc -l) )); then
        echo "✅ Python: $VERSION"
    else
        echo "❌ Python: $VERSION (need 3.9+)"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "❌ Python: Not installed"
    ERRORS=$((ERRORS + 1))
fi

# Check Python packages
echo ""
echo "Python Packages:"
for package in tls-client requests google-auth typing-extensions; do
    if python3 -c "import ${package//-/_}" 2>/dev/null; then
        echo "  ✅ $package"
    else
        echo "  ❌ $package (run: pip3 install $package)"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check directories
echo ""
echo "Project Structure:"
for dir in cmd internal config scripts; do
    if [ -d "$dir" ]; then
        echo "  ✅ $dir/"
    else
        echo "  ❌ $dir/ (missing)"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check config
echo ""
if [ -f "config/config.json" ]; then
    echo "✅ Configuration file exists"
else
    echo "❌ Configuration file missing"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "======================================"
if [ $ERRORS -eq 0 ]; then
    echo "✅ All prerequisites satisfied!"
    echo "The bot is ready to build and run."
else
    echo "❌ Found $ERRORS issues"
    echo "Please run ./install.sh to fix"
fi
echo "======================================"
```

## Quick Start Commands

```bash
# 1. Make scripts executable
chmod +x install.sh verify.sh

# 2. Run installation
./install.sh

# 3. Verify installation
./verify.sh

# 4. Configure bot
nano config/config.json

# 5. Build bot (requires Go)
go build -o walmart-bot cmd/main.go

# 6. Run bot
./walmart-bot
```

## Troubleshooting

### Common Issues

1. **"go: command not found"**
   - Install Go using the instructions above
   - Ensure Go is in your PATH

2. **"No module named 'tls_client'"**
   ```bash
   pip3 install tls-client --user
   ```

3. **"Cannot find package"** (Go error)
   ```bash
   go mod tidy
   go mod download
   ```

4. **SSL/TLS Errors**
   ```bash
   pip3 install --upgrade certifi
   export SSL_CERT_FILE=$(python3 -m certifi)
   ```

5. **Permission Denied**
   ```bash
   chmod +x walmart-bot
   sudo ./walmart-bot  # Not recommended
   ```

## Testing Installation

Run the test suite:
```bash
python3 test_bot.py
```

Expected output:
```
✅ All tests passed!
The bot is ready to run.
```

## Support

For issues or questions:
- Check README.md for usage instructions
- Review error logs in `logs/` directory
- Ensure all prerequisites are installed with `./verify.sh`