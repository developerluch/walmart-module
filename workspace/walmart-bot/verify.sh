#!/bin/bash

echo "======================================"
echo "Walmart Bot (Pure Go) Verification"
echo "======================================"

ERRORS=0
WARNINGS=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check Go
echo ""
echo "Core Requirements:"
echo "------------------"
if command -v go >/dev/null 2>&1; then
    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    echo -e "${GREEN}✅${NC} Go: $(go version)"
    
    # Check Go version is 1.21+
    REQUIRED_GO="1.21"
    if [ "$(printf '%s\n' "$REQUIRED_GO" "$GO_VERSION" | sort -V | head -n1)" = "$REQUIRED_GO" ]; then 
        echo "   Version $GO_VERSION meets requirements"
    else
        echo -e "   ${YELLOW}⚠️${NC}  Version $GO_VERSION is older than recommended $REQUIRED_GO"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}❌${NC} Go: Not installed (required)"
    echo "   Install with: brew install go (macOS) or apt install golang-go (Linux)"
    ERRORS=$((ERRORS + 1))
fi

# Check Go modules
echo ""
echo "Go Dependencies:"
echo "----------------"
REQUIRED_MODULES=(
    "github.com/bogdanfinn/tls-client"
    "github.com/bogdanfinn/fhttp"
    "github.com/gorilla/mux"
    "github.com/sirupsen/logrus"
)

for module in "${REQUIRED_MODULES[@]}"; do
    if grep -q "$module" go.mod 2>/dev/null; then
        VERSION=$(grep "$module" go.mod | awk '{print $2}')
        echo -e "${GREEN}✅${NC} $module: $VERSION"
    else
        echo -e "${RED}❌${NC} $module: Not found in go.mod"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check project structure
echo ""
echo "Project Structure:"
echo "------------------"
REQUIRED_DIRS=(
    "cmd"
    "internal"
    "internal/auth"
    "internal/tlsclient"
    "internal/checkout"
    "internal/proxy"
    "internal/graphql"
    "internal/logging"
    "internal/inventory"
    "pkg/gmail"
    "config"
    "web"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo -e "${GREEN}✅${NC} $dir/"
    else
        echo -e "${RED}❌${NC} $dir/ (missing)"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check important files
echo ""
echo "Core Files:"
echo "-----------"
CORE_FILES=(
    "cmd/main.go"
    "internal/auth/login.go"
    "internal/tlsclient/client.go"
    "internal/checkout/checkout.go"
    "internal/proxy/manager.go"
    "internal/graphql/operations.go"
    "go.mod"
    "go.sum"
)

for file in "${CORE_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✅${NC} $file"
    else
        echo -e "${RED}❌${NC} $file (missing)"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check configuration
echo ""
echo "Configuration:"
echo "--------------"
if [ -f "config/config.json" ]; then
    echo -e "${GREEN}✅${NC} config/config.json"
    
    # Check if config has been edited
    if grep -q "user@example.com" config/config.json; then
        echo -e "   ${YELLOW}⚠️${NC}  Still using default email - please update"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}❌${NC} config/config.json (missing)"
    ERRORS=$((ERRORS + 1))
fi

if [ -f "config/proxies.txt" ]; then
    echo -e "${GREEN}✅${NC} config/proxies.txt"
else
    echo -e "${YELLOW}⚠️${NC}  config/proxies.txt (optional)"
fi

# Check if bot is built
echo ""
echo "Build Status:"
echo "-------------"
if [ -f "walmart-bot" ]; then
    echo -e "${GREEN}✅${NC} walmart-bot (executable found)"
    
    # Check if it's executable
    if [ -x "walmart-bot" ]; then
        echo "   Executable permissions set"
    else
        echo -e "   ${YELLOW}⚠️${NC}  Not executable - run: chmod +x walmart-bot"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${YELLOW}⚠️${NC}  walmart-bot not built yet"
    echo "   Run: go build -o walmart-bot cmd/main.go"
    WARNINGS=$((WARNINGS + 1))
fi

# Test compilation
echo ""
echo "Compilation Test:"
echo "-----------------"
echo "Testing if the bot compiles..."
if go build -o /dev/null cmd/main.go 2>/dev/null; then
    echo -e "${GREEN}✅${NC} Code compiles successfully"
else
    echo -e "${RED}❌${NC} Compilation failed"
    echo "   Run 'go build cmd/main.go' to see errors"
    ERRORS=$((ERRORS + 1))
fi

# Check for Python dependencies (should not exist)
echo ""
echo "Python Dependencies:"
echo "--------------------"
PYTHON_FILES=("requirements.txt" "*.py" "scripts/*.py")
FOUND_PYTHON=0

for pattern in "${PYTHON_FILES[@]}"; do
    if ls $pattern 2>/dev/null | grep -q .; then
        FOUND_PYTHON=1
    fi
done

if [ $FOUND_PYTHON -eq 0 ]; then
    echo -e "${GREEN}✅${NC} No Python dependencies (pure Go implementation)"
else
    echo -e "${YELLOW}⚠️${NC}  Found Python files (not needed for pure Go version)"
fi

# Summary
echo ""
echo "======================================"
echo "VERIFICATION SUMMARY"
echo "======================================"

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✅ All checks passed!${NC}"
    echo "The bot is ready to run."
    echo ""
    if [ ! -f "walmart-bot" ]; then
        echo "Build the bot: go build -o walmart-bot cmd/main.go"
    else
        echo "Run the bot: ./walmart-bot"
    fi
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  Found $WARNINGS warnings${NC}"
    echo "The bot can run but some optional features may need attention."
else
    echo -e "${RED}❌ Found $ERRORS errors and $WARNINGS warnings${NC}"
    echo "Please fix the errors before running the bot."
    echo ""
    echo "Quick fix: Run ./install.sh to install missing components"
fi

echo "======================================"

# Exit with error code if there are errors
exit $ERRORS