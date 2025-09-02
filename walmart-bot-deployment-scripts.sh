#!/bin/bash
# =====================================================
# WALMART BOT DEPLOYMENT SCRIPTS
# Comprehensive deployment and operational procedures
# =====================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="walmart-bot"
APP_DIR="/opt/$APP_NAME"
BACKUP_DIR="$APP_DIR/backups"
LOG_FILE="/var/log/$APP_NAME-deploy.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" | tee -a "$LOG_FILE"
}

# =====================================================
# UTILITY FUNCTIONS
# =====================================================

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root for security reasons"
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    local missing_deps=()
    
    # Check required commands
    for cmd in docker docker-compose curl jq systemctl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        error "Missing required dependencies: ${missing_deps[*]}"
        error "Please install missing dependencies and try again"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info &>/dev/null; then
        error "Docker daemon is not running"
        exit 1
    fi
    
    # Check available disk space (minimum 10GB)
    local available_space=$(df "$APP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | head -1)
    if [[ ${available_space:-0} -lt 10485760 ]]; then  # 10GB in KB
        warn "Low disk space available. Consider cleaning up old data."
    fi
    
    # Check available memory (minimum 2GB)
    local available_memory=$(free -m | awk 'NR==2{print $7}')
    if [[ ${available_memory:-0} -lt 2048 ]]; then
        warn "Low memory available: ${available_memory}MB. Performance may be impacted."
    fi
    
    log "System requirements check completed"
}

# Create necessary directories
create_directories() {
    log "Creating directory structure..."
    
    sudo mkdir -p "$APP_DIR"/{configs,logs,data,ssl,proxies,backups,scripts}
    sudo mkdir -p "$APP_DIR"/configs/{grafana/{dashboards,datasources},prometheus,nginx}
    
    # Set ownership
    sudo chown -R "$(whoami):$(whoami)" "$APP_DIR"
    
    log "Directory structure created"
}

# Generate environment file
generate_env_file() {
    log "Generating environment configuration..."
    
    # Generate secure passwords
    local db_password=$(openssl rand -base64 32)
    local redis_password=$(openssl rand -base64 32)
    local jwt_secret=$(openssl rand -base64 64)
    local api_key=$(openssl rand -hex 32)
    local grafana_password=$(openssl rand -base64 16)
    
    cat > "$APP_DIR/.env" <<EOF
# Environment Configuration
ENV=production
LOG_LEVEL=info
TZ=UTC

# Database Configuration
DATABASE_URL=postgresql://walmart_bot:${db_password}@postgres:5432/walmart_bot
DB_PASSWORD=${db_password}

# Redis Configuration
REDIS_URL=redis://:${redis_password}@redis:6379
REDIS_PASSWORD=${redis_password}

# Application Configuration
API_KEY=${api_key}
JWT_SECRET=${jwt_secret}
MAX_CONCURRENT_REQUESTS=50
PROXY_ROTATION_INTERVAL=180
REQUEST_TIMEOUT=30
RETRY_ATTEMPTS=3

# Monitoring Configuration
PROMETHEUS_PORT=9090
GRAFANA_ADMIN_PASSWORD=${grafana_password}
METRICS_ENABLED=true

# Security Configuration
SSL_ENABLED=false
RATE_LIMIT_ENABLED=true
FAIL2BAN_ENABLED=true

# External Services (configure as needed)
SLACK_WEBHOOK_URL=
EMAIL_ALERTS_TO=admin@example.com
PAGERDUTY_INTEGRATION_KEY=

# Proxy Configuration
PROXY_LIST_URL=
PROXY_AUTH_USERNAME=
PROXY_AUTH_PASSWORD=

# Chrome/Selenium Configuration
CHROME_HEADLESS=true
CHROME_NO_SANDBOX=true
SELENIUM_GRID_URL=

# Logging Configuration
LOG_MAX_SIZE=100m
LOG_MAX_FILES=10
LOG_COMPRESS=true

# Performance Tuning
GOMAXPROCS=0
PYTHON_WORKERS=4
CONNECTION_POOL_SIZE=20
EOF
    
    chmod 600 "$APP_DIR/.env"
    log "Environment file generated at $APP_DIR/.env"
    info "Please review and update the configuration as needed"
}

# =====================================================
# INSTALLATION FUNCTIONS
# =====================================================

# Install Docker and Docker Compose
install_docker() {
    if command -v docker &> /dev/null; then
        log "Docker is already installed"
        return 0
    fi
    
    log "Installing Docker..."
    
    # Install Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker "$(whoami)"
    rm get-docker.sh
    
    # Install Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        local compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
        sudo curl -L "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    
    log "Docker installation completed"
    warn "Please log out and log back in for Docker group membership to take effect"
}

# Install system dependencies
install_system_dependencies() {
    log "Installing system dependencies..."
    
    # Update package list
    sudo apt-get update
    
    # Install required packages
    sudo apt-get install -y \
        curl \
        wget \
        jq \
        htop \
        iotop \
        netstat-nat \
        tcpdump \
        logrotate \
        cron \
        fail2ban \
        ufw \
        certbot \
        python3-certbot-nginx \
        mailutils \
        bc
    
    log "System dependencies installed"
}

# Setup monitoring exporters
setup_monitoring_exporters() {
    log "Setting up monitoring exporters..."
    
    # Node Exporter
    local node_exporter_version="1.6.1"
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.linux-amd64.tar.gz"
    tar xzf "node_exporter-${node_exporter_version}.linux-amd64.tar.gz"
    sudo mv "node_exporter-${node_exporter_version}.linux-amd64/node_exporter" /usr/local/bin/
    rm -rf "node_exporter-${node_exporter_version}.linux-amd64"*
    
    # Create node exporter service
    sudo tee /etc/systemd/system/node-exporter.service > /dev/null <<'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=nobody
Group=nogroup
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable node-exporter
    sudo systemctl start node-exporter
    
    log "Monitoring exporters setup completed"
}

# Setup log rotation
setup_log_rotation() {
    log "Setting up log rotation..."
    
    sudo tee /etc/logrotate.d/$APP_NAME > /dev/null <<EOF
$APP_DIR/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
    create 0644 $(whoami) $(whoami)
    su $(whoami) $(whoami)
    postrotate
        docker-compose -f $APP_DIR/docker-compose.yml restart $APP_NAME 2>/dev/null || true
    endscript
}

/var/log/$APP_NAME*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
    create 0644 $(whoami) $(whoami)
}
EOF
    
    log "Log rotation configured"
}

# Setup systemd service
setup_systemd_service() {
    log "Setting up systemd service..."
    
    sudo tee /etc/systemd/system/$APP_NAME.service > /dev/null <<EOF
[Unit]
Description=Walmart Bot Service
After=docker.service network.target
Requires=docker.service
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
User=$(whoami)
Group=$(whoami)

# Environment
EnvironmentFile=$APP_DIR/.env

# Service management
ExecStartPre=/usr/bin/docker-compose down --remove-orphans
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
ExecReload=/usr/bin/docker-compose restart $APP_NAME

# Timeouts
TimeoutStartSec=300
TimeoutStopSec=30

# Restart configuration
Restart=on-failure
RestartSec=30

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$APP_DIR/logs $APP_DIR/data $APP_DIR/backups

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096
MemoryLimit=8G
CPUQuota=400%

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable $APP_NAME.service
    
    log "Systemd service configured"
}

# Setup firewall
setup_firewall() {
    log "Configuring firewall..."
    
    # Reset UFW to defaults
    sudo ufw --force reset
    
    # Set default policies
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # Allow SSH (adjust port if needed)
    sudo ufw allow 22/tcp comment 'SSH'
    
    # Allow HTTP and HTTPS
    sudo ufw allow 80/tcp comment 'HTTP'
    sudo ufw allow 443/tcp comment 'HTTPS'
    
    # Allow application ports (adjust as needed)
    sudo ufw allow 8080/tcp comment 'App HTTP'
    sudo ufw allow 8081/tcp comment 'Python Service'
    
    # Allow monitoring (restrict to local network)
    sudo ufw allow from 10.0.0.0/8 to any port 3000 comment 'Grafana'
    sudo ufw allow from 10.0.0.0/8 to any port 9090 comment 'Prometheus'
    sudo ufw allow from 127.0.0.1 to any port 9100 comment 'Node Exporter'
    
    # Enable firewall
    sudo ufw --force enable
    
    log "Firewall configured"
}

# Setup fail2ban
setup_fail2ban() {
    log "Configuring fail2ban..."
    
    sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = auto
usedns = warn
logencoding = auto
enabled = false
mode = normal
filter = %(__name__)s[mode=%(mode)s]

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /opt/walmart-bot/logs/nginx/error.log
maxretry = 6

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
port = http,https
logpath = /opt/walmart-bot/logs/nginx/error.log
maxretry = 10
findtime = 600
bantime = 3600

[walmart-bot-api]
enabled = true
filter = walmart-bot-api
port = 8080,8081
logpath = /opt/walmart-bot/logs/app.log
maxretry = 10
findtime = 300
bantime = 1800
EOF
    
    # Create custom filter for walmart-bot
    sudo tee /etc/fail2ban/filter.d/walmart-bot-api.conf > /dev/null <<'EOF'
[Definition]
failregex = ^.*\[ERROR\].*client_ip="<HOST>".*rate_limit_exceeded.*$
            ^.*\[ERROR\].*client_ip="<HOST>".*authentication_failed.*$
            ^.*\[ERROR\].*client_ip="<HOST>".*invalid_request.*$
ignoreregex =
EOF
    
    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    
    log "Fail2ban configured"
}

# =====================================================
# CONFIGURATION FUNCTIONS
# =====================================================

# Generate Docker Compose file
generate_docker_compose() {
    log "Generating Docker Compose configuration..."
    
    cat > "$APP_DIR/docker-compose.yml" <<'EOF'
version: '3.8'

services:
  walmart-bot:
    image: walmart-bot:latest
    container_name: walmart-bot
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "8081:8081"
    environment:
      - ENV=${ENV:-production}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=${REDIS_URL}
      - MAX_CONCURRENT_REQUESTS=${MAX_CONCURRENT_REQUESTS:-50}
      - PROXY_ROTATION_INTERVAL=${PROXY_ROTATION_INTERVAL:-180}
      - API_KEY=${API_KEY}
      - JWT_SECRET=${JWT_SECRET}
    volumes:
      - ./configs:/app/configs:ro
      - ./proxies:/app/proxies:ro
      - ./logs:/app/logs
      - ./data:/app/data
    depends_on:
      - postgres
      - redis
    networks:
      - walmart-bot-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    deploy:
      resources:
        limits:
          cpus: '4.0'
          memory: 4G
        reservations:
          cpus: '2.0'
          memory: 2G
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
        compress: "true"

  postgres:
    image: postgres:15-alpine
    container_name: walmart-bot-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=walmart_bot
      - POSTGRES_USER=walmart_bot
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./configs/postgres.conf:/etc/postgresql/postgresql.conf:ro
      - ./backups:/backups
    networks:
      - walmart-bot-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U walmart_bot -d walmart_bot"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G

  redis:
    image: redis:7-alpine
    container_name: walmart-bot-redis
    restart: unless-stopped
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis_data:/data
      - ./configs/redis.conf:/usr/local/etc/redis/redis.conf:ro
    command: redis-server /usr/local/etc/redis/redis.conf
    networks:
      - walmart-bot-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M

  nginx:
    image: nginx:alpine
    container_name: walmart-bot-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./configs/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./logs/nginx:/var/log/nginx
    depends_on:
      - walmart-bot
    networks:
      - walmart-bot-network
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  prometheus:
    image: prom/prometheus:latest
    container_name: walmart-bot-prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:9090:9090"
    volumes:
      - ./configs/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./configs/prometheus/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
      - '--storage.tsdb.retention.time=30d'
    networks:
      - walmart-bot-network
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G

  grafana:
    image: grafana/grafana:latest
    container_name: walmart-bot-grafana
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_INSTALL_PLUGINS=grafana-clock-panel,grafana-simple-json-datasource
    volumes:
      - grafana_data:/var/lib/grafana
      - ./configs/grafana/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./configs/grafana/datasources:/etc/grafana/provisioning/datasources:ro
    networks:
      - walmart-bot-network
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M

  node-exporter:
    image: prom/node-exporter:latest
    container_name: walmart-bot-node-exporter
    restart: unless-stopped
    ports:
      - "127.0.0.1:9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    networks:
      - walmart-bot-network

  redis-exporter:
    image: oliver006/redis_exporter:latest
    container_name: walmart-bot-redis-exporter
    restart: unless-stopped
    ports:
      - "127.0.0.1:9121:9121"
    environment:
      - REDIS_ADDR=redis://redis:6379
      - REDIS_PASSWORD=${REDIS_PASSWORD}
    depends_on:
      - redis
    networks:
      - walmart-bot-network

volumes:
  postgres_data:
    driver: local
  redis_data:
    driver: local
  prometheus_data:
    driver: local
  grafana_data:
    driver: local

networks:
  walmart-bot-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF
    
    log "Docker Compose configuration generated"
}

# Generate configuration files
generate_config_files() {
    log "Generating configuration files..."
    
    # Nginx configuration
    cat > "$APP_DIR/configs/nginx.conf" <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" '
                    'uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log /var/log/nginx/access.log main;

    # Basic Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 10m;
    server_tokens off;

    # Gzip Settings
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json;

    # Rate Limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=100r/m;
    limit_req_zone $binary_remote_addr zone=scrape:10m rate=10r/m;

    # Security Headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # Upstream servers
    upstream walmart_bot_go {
        least_conn;
        server walmart-bot:8080 max_fails=3 fail_timeout=30s;
        keepalive 32;
    }

    upstream walmart_bot_python {
        least_conn;
        server walmart-bot:8081 max_fails=3 fail_timeout=30s;
        keepalive 32;
    }

    # Main server block
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;

        # Health check
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        # API routes (Go service)
        location /api/ {
            limit_req zone=api burst=50 nodelay;

            proxy_pass http://walmart_bot_go;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_cache_bypass $http_upgrade;

            proxy_connect_timeout 30s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;
        }

        # Scraping routes (Python service)
        location /scrape/ {
            limit_req zone=scrape burst=10 nodelay;

            proxy_pass http://walmart_bot_python;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 120s;
        }

        # Metrics endpoint (restrict access)
        location /metrics {
            allow 127.0.0.1;
            allow 10.0.0.0/8;
            allow 172.16.0.0/12;
            allow 192.168.0.0/16;
            deny all;

            proxy_pass http://walmart_bot_go;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # Block access to sensitive files
        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }

        location ~* \.(ini|conf|config)$ {
            deny all;
            access_log off;
            log_not_found off;
        }
    }
}
EOF

    # Redis configuration
    cat > "$APP_DIR/configs/redis.conf" <<'EOF'
# Network
bind 0.0.0.0
port 6379
timeout 300
tcp-keepalive 300

# General
daemonize no
pidfile /var/run/redis.pid
loglevel notice
logfile ""
databases 16

# Snapshotting
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /data

# Memory management
maxmemory 512mb
maxmemory-policy allkeys-lru
maxmemory-samples 5

# AOF
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# Security
requirepass ${REDIS_PASSWORD}

# Clients
maxclients 1000

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128

# Latency monitor
latency-monitor-threshold 100
EOF

    # Prometheus configuration
    cat > "$APP_DIR/configs/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "/etc/prometheus/rules/*.yml"

scrape_configs:
  - job_name: 'walmart-bot'
    static_configs:
      - targets: ['walmart-bot:9090']
    scrape_interval: 10s
    metrics_path: /metrics

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'redis-exporter'
    static_configs:
      - targets: ['redis-exporter:9121']

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'nginx'
    static_configs:
      - targets: ['nginx:80']
    metrics_path: /nginx_status
    scrape_interval: 30s
EOF

    # Create Prometheus rules directory
    mkdir -p "$APP_DIR/configs/prometheus/rules"
    
    # Prometheus alert rules
    cat > "$APP_DIR/configs/prometheus/rules/alerts.yml" <<'EOF'
groups:
  - name: walmart-bot-alerts
    rules:
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Service {{ $labels.job }} is down"
          description: "Service {{ $labels.job }} has been down for more than 1 minute"

      - alert: HighErrorRate
        expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.1
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High error rate detected"
          description: "Error rate is {{ $value }} errors per second"

      - alert: HighResponseTime
        expr: histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High response time detected"
          description: "95th percentile response time is {{ $value }} seconds"

      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage"
          description: "Memory usage is above 90%"

      - alert: HighDiskUsage
        expr: (node_filesystem_size_bytes - node_filesystem_free_bytes) / node_filesystem_size_bytes > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High disk usage"
          description: "Disk usage is above 85% on {{ $labels.mountpoint }}"

      - alert: ProxyRotationFailed
        expr: increase(proxy_rotation_failures_total[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Proxy rotation failures detected"
          description: "{{ $value }} proxy rotation failures in the last 5 minutes"

      - alert: DatabaseConnectionsHigh
        expr: pg_stat_database_numbackends / pg_settings_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Database connection usage high"
          description: "Database connections are at {{ $value | humanizePercentage }} of maximum"

      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_config_maxmemory > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis memory usage high"
          description: "Redis memory usage is at {{ $value | humanizePercentage }}"
EOF

    # Grafana datasource configuration
    mkdir -p "$APP_DIR/configs/grafana/datasources"
    cat > "$APP_DIR/configs/grafana/datasources/prometheus.yml" <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    access: proxy
    isDefault: true
    editable: true
EOF

    log "Configuration files generated"
}

# =====================================================
# OPERATIONAL SCRIPTS
# =====================================================

# Create backup script
create_backup_script() {
    log "Creating backup script..."
    
    cat > "$APP_DIR/scripts/backup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

APP_DIR="/opt/walmart-bot"
BACKUP_DIR="$APP_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_$TIMESTAMP"
RETENTION_DAYS=30

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting backup: $BACKUP_NAME"

# Create backup directory
mkdir -p "$BACKUP_DIR/$BACKUP_NAME"

# Backup database
log "Backing up database..."
docker-compose exec -T postgres pg_dump -U walmart_bot walmart_bot | gzip > "$BACKUP_DIR/$BACKUP_NAME/database.sql.gz"

# Backup Redis
log "Backing up Redis..."
docker-compose exec -T redis redis-cli --rdb - | gzip > "$BACKUP_DIR/$BACKUP_NAME/redis.rdb.gz"

# Backup configurations
log "Backing up configurations..."
tar czf "$BACKUP_DIR/$BACKUP_NAME/configs.tar.gz" -C "$APP_DIR" configs/

# Backup environment
cp "$APP_DIR/.env" "$BACKUP_DIR/$BACKUP_NAME/"

# Backup application data
if [ -d "$APP_DIR/data" ]; then
    log "Backing up application data..."
    tar czf "$BACKUP_DIR/$BACKUP_NAME/data.tar.gz" -C "$APP_DIR" data/
fi

# Create backup manifest
cat > "$BACKUP_DIR/$BACKUP_NAME/manifest.txt" <<MANIFEST
Backup created: $(date)
Database: database.sql.gz
Redis: redis.rdb.gz
Configs: configs.tar.gz
Environment: .env
Data: data.tar.gz (if exists)
MANIFEST

log "Backup completed: $BACKUP_DIR/$BACKUP_NAME"

# Cleanup old backups
log "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true

log "Backup process finished"
EOF
    
    chmod +x "$APP_DIR/scripts/backup.sh"
    log "Backup script created at $APP_DIR/scripts/backup.sh"
}

# Create restore script
create_restore_script() {
    log "Creating restore script..."
    
    cat > "$APP_DIR/scripts/restore.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

APP_DIR="/opt/walmart-bot"
BACKUP_DIR="$APP_DIR/backups"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

usage() {
    echo "Usage: $0 <backup_name>"
    echo "Available backups:"
    ls -1 "$BACKUP_DIR" | grep "backup_" | head -10
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

BACKUP_NAME="$1"
RESTORE_PATH="$BACKUP_DIR/$BACKUP_NAME"

if [ ! -d "$RESTORE_PATH" ]; then
    error "Backup not found: $BACKUP_NAME"
    usage
fi

log "Starting restore from: $BACKUP_NAME"

# Stop services
log "Stopping services..."
docker-compose down

# Restore database
if [ -f "$RESTORE_PATH/database.sql.gz" ]; then
    log "Restoring database..."
    docker-compose up -d postgres
    sleep 10
    
    # Drop and recreate database
    docker-compose exec postgres psql -U walmart_bot -c "DROP DATABASE IF EXISTS walmart_bot;"
    docker-compose exec postgres psql -U walmart_bot -c "CREATE DATABASE walmart_bot;"
    
    # Restore data
    gunzip -c "$RESTORE_PATH/database.sql.gz" | docker-compose exec -T postgres psql -U walmart_bot -d walmart_bot
    
    docker-compose down
fi

# Restore Redis
if [ -f "$RESTORE_PATH/redis.rdb.gz" ]; then
    log "Restoring Redis..."
    # Clear existing Redis data
    rm -f "$APP_DIR/redis_data/dump.rdb"
    gunzip -c "$RESTORE_PATH/redis.rdb.gz" > "$APP_DIR/redis_data/dump.rdb"
fi

# Restore configurations
if [ -f "$RESTORE_PATH/configs.tar.gz" ]; then
    log "Restoring configurations..."
    tar xzf "$RESTORE_PATH/configs.tar.gz" -C "$APP_DIR"
fi

# Restore environment (with user confirmation)
if [ -f "$RESTORE_PATH/.env" ]; then
    echo -n "Restore environment file? This will overwrite current settings (y/N): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        log "Restoring environment..."
        cp "$RESTORE_PATH/.env" "$APP_DIR/"
    fi
fi

# Restore application data
if [ -f "$RESTORE_PATH/data.tar.gz" ]; then
    log "Restoring application data..."
    tar xzf "$RESTORE_PATH/data.tar.gz" -C "$APP_DIR"
fi

# Start services
log "Starting services..."
docker-compose up -d

log "Restore completed from: $BACKUP_NAME"
log "Please verify that all services are running correctly"
EOF
    
    chmod +x "$APP_DIR/scripts/restore.sh"
    log "Restore script created at $APP_DIR/scripts/restore.sh"
}

# Create health check script
create_health_check_script() {
    log "Creating health check script..."
    
    cat > "$APP_DIR/scripts/health-check.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

APP_DIR="/opt/walmart-bot"
ENDPOINTS=(
    "http://localhost:8080/health"
    "http://localhost:8081/health"
    "http://localhost:9090/-/healthy"
    "http://localhost/health"
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

check_service() {
    local service="$1"
    if docker-compose ps "$service" | grep -q "Up"; then
        echo "✓ $service is running"
        return 0
    else
        echo "✗ $service is not running"
        return 1
    fi
}

check_endpoint() {
    local endpoint="$1"
    local name=$(echo "$endpoint" | sed 's|http://localhost:||' | sed 's|/.*||')
    
    if curl -f -s --max-time 10 "$endpoint" >/dev/null; then
        echo "✓ $name endpoint is healthy"
        return 0
    else
        echo "✗ $name endpoint is unhealthy"
        return 1
    fi
}

log "Starting health check..."

# Check Docker services
services=(walmart-bot postgres redis nginx prometheus grafana)
service_status=0

for service in "${services[@]}"; do
    if ! check_service "$service"; then
        service_status=1
    fi
done

# Check HTTP endpoints
endpoint_status=0

for endpoint in "${ENDPOINTS[@]}"; do
    if ! check_endpoint "$endpoint"; then
        endpoint_status=1
    fi
done

# Check system resources
memory_usage=$(free | awk '/^Mem:/{printf "%.0f", $3/$2 * 100.0}')
disk_usage=$(df "$APP_DIR" | tail -1 | awk '{print $5}' | sed 's/%//')
cpu_load=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | xargs)

echo ""
echo "System Resources:"
echo "Memory usage: ${memory_usage}%"
echo "Disk usage: ${disk_usage}%"
echo "CPU load: ${cpu_load}"

# Overall status
if [ $service_status -eq 0 ] && [ $endpoint_status -eq 0 ]; then
    log "All health checks passed ✓"
    exit 0
else
    error "Some health checks failed ✗"
    exit 1
fi
EOF
    
    chmod +x "$APP_DIR/scripts/health-check.sh"
    log "Health check script created at $APP_DIR/scripts/health-check.sh"
}

# Create maintenance script
create_maintenance_script() {
    log "Creating maintenance script..."
    
    cat > "$APP_DIR/scripts/maintenance.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

APP_DIR="/opt/walmart-bot"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

usage() {
    echo "Usage: $0 {logs|cleanup|update|restart|status}"
    echo ""
    echo "Commands:"
    echo "  logs     - Show application logs"
    echo "  cleanup  - Clean up old logs and temporary files"
    echo "  update   - Update and restart services"
    echo "  restart  - Restart all services"
    echo "  status   - Show service status"
    exit 1
}

show_logs() {
    echo "=== Application Logs ==="
    docker-compose logs --tail=50 walmart-bot
    
    echo ""
    echo "=== System Logs ==="
    journalctl -u walmart-bot --lines=20 --no-pager
}

cleanup() {
    log "Starting cleanup..."
    
    # Clean Docker
    log "Cleaning up Docker resources..."
    docker system prune -f
    docker volume prune -f
    
    # Clean logs older than 7 days
    log "Cleaning up old logs..."
    find "$APP_DIR/logs" -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    find "$APP_DIR/logs" -name "*.log.*" -type f -mtime +7 -delete 2>/dev/null || true
    
    # Clean temporary files
    log "Cleaning up temporary files..."
    find "$APP_DIR/data" -name "*.tmp" -type f -delete 2>/dev/null || true
    find "$APP_DIR/data" -name "*.temp" -type f -delete 2>/dev/null || true
    
    # Clean old backups (keep 30 days)
    log "Cleaning up old backups..."
    find "$APP_DIR/backups" -type d -name "backup_*" -mtime +30 -exec rm -rf {} + 2>/dev/null || true
    
    log "Cleanup completed"
}

update_services() {
    log "Updating services..."
    
    # Pull latest images
    docker-compose pull
    
    # Restart services
    docker-compose up -d
    
    # Wait for services to be ready
    sleep 30
    
    # Run health check
    "$APP_DIR/scripts/health-check.sh"
    
    log "Update completed"
}

restart_services() {
    log "Restarting services..."
    
    systemctl restart walmart-bot
    
    # Wait for services to be ready
    sleep 30
    
    # Run health check
    "$APP_DIR/scripts/health-check.sh"
    
    log "Restart completed"
}

show_status() {
    echo "=== Service Status ==="
    systemctl status walmart-bot --no-pager
    
    echo ""
    echo "=== Docker Services ==="
    docker-compose ps
    
    echo ""
    echo "=== Resource Usage ==="
    echo "Memory: $(free -h | awk 'NR==2{printf "%.1f%%", $3/$2*100}')"
    echo "Disk: $(df -h "$APP_DIR" | awk 'NR==2{print $5}')"
    echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
}

case "${1:-}" in
    logs)
        show_logs
        ;;
    cleanup)
        cleanup
        ;;
    update)
        update_services
        ;;
    restart)
        restart_services
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
EOF
    
    chmod +x "$APP_DIR/scripts/maintenance.sh"
    log "Maintenance script created at $APP_DIR/scripts/maintenance.sh"
}

# =====================================================
# MAIN FUNCTIONS
# =====================================================

# Complete installation
install() {
    log "Starting Walmart Bot installation..."
    
    check_requirements
    create_directories
    install_system_dependencies
    install_docker
    generate_env_file
    generate_docker_compose
    generate_config_files
    setup_monitoring_exporters
    setup_log_rotation
    setup_systemd_service
    setup_firewall
    setup_fail2ban
    create_backup_script
    create_restore_script
    create_health_check_script
    create_maintenance_script
    
    # Create cron jobs
    log "Setting up scheduled tasks..."
    (crontab -l 2>/dev/null; echo "0 2 * * * $APP_DIR/scripts/backup.sh") | crontab -
    (crontab -l 2>/dev/null; echo "*/15 * * * * $APP_DIR/scripts/health-check.sh >/dev/null 2>&1") | crontab -
    (crontab -l 2>/dev/null; echo "0 3 * * 0 $APP_DIR/scripts/maintenance.sh cleanup") | crontab -
    
    log "Installation completed successfully!"
    info "Please review the configuration files in $APP_DIR/configs/"
    info "Update the environment file: $APP_DIR/.env"
    info "Add your proxy lists to: $APP_DIR/proxies/"
    info "Start the service with: sudo systemctl start walmart-bot"
}

# Deploy application
deploy() {
    local image_tag="${1:-latest}"
    
    log "Starting deployment of walmart-bot:$image_tag..."
    
    # Update docker-compose with new image
    sed -i "s|image: walmart-bot:.*|image: walmart-bot:$image_tag|g" "$APP_DIR/docker-compose.yml"
    
    # Create backup before deployment
    "$APP_DIR/scripts/backup.sh"
    
    # Deploy
    systemctl restart walmart-bot
    
    # Wait and health check
    sleep 60
    if "$APP_DIR/scripts/health-check.sh"; then
        log "Deployment successful!"
    else
        error "Deployment failed - check logs"
        exit 1
    fi
}

# Show help
show_help() {
    cat <<EOF
Walmart Bot Deployment Scripts

Usage: $0 {install|deploy|backup|restore|health|maintenance|help}

Commands:
    install             - Complete installation setup
    deploy [tag]        - Deploy application (default: latest)
    backup              - Create backup
    restore <backup>    - Restore from backup
    health              - Run health checks
    maintenance <cmd>   - Run maintenance command
    help                - Show this help

Examples:
    $0 install                          # Install everything
    $0 deploy v1.2.3                    # Deploy specific version
    $0 backup                           # Create backup
    $0 restore backup_20240101_120000   # Restore backup
    $0 health                           # Check health
    $0 maintenance status               # Show status

For more information, check the documentation.
EOF
}

# =====================================================
# MAIN SCRIPT LOGIC
# =====================================================

# Check if running as root
check_root

# Main command handler
case "${1:-help}" in
    install)
        install
        ;;
    deploy)
        deploy "${2:-latest}"
        ;;
    backup)
        if [ -f "$APP_DIR/scripts/backup.sh" ]; then
            "$APP_DIR/scripts/backup.sh"
        else
            error "Backup script not found. Run install first."
        fi
        ;;
    restore)
        if [ -f "$APP_DIR/scripts/restore.sh" ]; then
            "$APP_DIR/scripts/restore.sh" "${2:-}"
        else
            error "Restore script not found. Run install first."
        fi
        ;;
    health)
        if [ -f "$APP_DIR/scripts/health-check.sh" ]; then
            "$APP_DIR/scripts/health-check.sh"
        else
            error "Health check script not found. Run install first."
        fi
        ;;
    maintenance)
        if [ -f "$APP_DIR/scripts/maintenance.sh" ]; then
            "$APP_DIR/scripts/maintenance.sh" "${2:-status}"
        else
            error "Maintenance script not found. Run install first."
        fi
        ;;
    help)
        show_help
        ;;
    *)
        error "Unknown command: ${1:-}"
        show_help
        exit 1
        ;;
esac