#!/bin/bash

# Walmart Bot Dashboard Startup Script
# This script initializes and starts the Walmart bot monitoring dashboard

set -e  # Exit on any error

echo "🛒 Walmart Bot Dashboard Startup Script"
echo "======================================="

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "❌ Go is not installed. Please install Go 1.21 or higher."
    echo "   Download from: https://golang.org/dl/"
    exit 1
fi

# Check Go version
GO_VERSION=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | cut -c3-)
REQUIRED_VERSION="1.21"

if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$GO_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
    echo "❌ Go version $GO_VERSION is too old. Please install Go $REQUIRED_VERSION or higher."
    exit 1
fi

echo "✅ Go version $GO_VERSION detected"

# Check if required files exist
REQUIRED_FILES=("walmart-bot-dashboard.html" "walmart-bot-backend.go" "go.mod")
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Required file $file not found"
        exit 1
    fi
done

echo "✅ All required files present"

# Initialize Go module and install dependencies
echo "📦 Installing dependencies..."
if ! go mod tidy; then
    echo "❌ Failed to install dependencies"
    exit 1
fi

echo "✅ Dependencies installed"

# Check if port 8080 is available
if lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "⚠️  Port 8080 is already in use"
    echo "   Please stop the service using port 8080 or modify the port in walmart-bot-backend.go"
    echo "   To find what's using port 8080: lsof -i :8080"
    read -p "   Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create logs directory if it doesn't exist
mkdir -p logs

# Start the dashboard server
echo "🚀 Starting Walmart Bot Dashboard Server..."
echo "   Server URL: http://localhost:8080"
echo "   WebSocket:  ws://localhost:8080/ws"
echo ""
echo "   Press Ctrl+C to stop the server"
echo ""

# Run the server with logging
go run walmart-bot-backend.go 2>&1 | tee logs/walmart-bot-$(date +%Y%m%d-%H%M%S).log

echo "👋 Walmart Bot Dashboard stopped"