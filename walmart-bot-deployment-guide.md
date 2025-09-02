# Walmart Bot Database Deployment Guide

## Overview

This guide provides step-by-step instructions for deploying the complete Walmart bot database infrastructure, including PostgreSQL with TimescaleDB and Redis caching layer.

## System Requirements

### Minimum Requirements
- **CPU**: 8 cores (16+ recommended for production)
- **RAM**: 32GB (64GB+ recommended for high-frequency monitoring)
- **Storage**: 500GB SSD (NVMe preferred for optimal I/O)
- **Network**: 1Gbps connection with low latency

### Recommended Production Setup
- **CPU**: 16-32 cores with high clock speed
- **RAM**: 64-128GB for large-scale operations
- **Storage**: 1TB+ NVMe SSD with RAID 1 configuration
- **Network**: 10Gbps connection for high-throughput operations

## Phase 1: System Preparation

### 1.1 Operating System Setup

```bash
# Ubuntu 22.04 LTS (recommended)
sudo apt update && sudo apt upgrade -y

# Install essential packages
sudo apt install -y \
    wget curl git build-essential \
    python3 python3-pip python3-venv \
    nginx certbot ufw htop iotop \
    postgresql-client redis-tools

# Configure firewall
sudo ufw enable
sudo ufw allow 22      # SSH
sudo ufw allow 80      # HTTP
sudo ufw allow 443     # HTTPS
sudo ufw allow 5432    # PostgreSQL
sudo ufw allow 6379    # Redis (restrict to internal network)
```

### 1.2 Performance Tuning

```bash
# Optimize kernel parameters
sudo tee -a /etc/sysctl.conf << EOF
# Memory management
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.overcommit_memory = 1

# Network optimization
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 5000

# File descriptor limits
fs.file-max = 2097152
EOF

# Apply changes
sudo sysctl -p

# Configure user limits
sudo tee -a /etc/security/limits.conf << EOF
* soft nofile 65535
* hard nofile 65535
* soft nproc 32768
* hard nproc 32768
EOF
```

## Phase 2: PostgreSQL and TimescaleDB Setup

### 2.1 Installation

```bash
# Add PostgreSQL repository
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

# Add TimescaleDB repository
echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" | sudo tee /etc/apt/sources.list.d/timescaledb.list
wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | sudo apt-key add -

# Update and install
sudo apt update
sudo apt install -y postgresql-15 postgresql-15-postgis-3 postgresql-contrib-15
sudo apt install -y timescaledb-2-postgresql-15

# Initialize TimescaleDB
sudo timescaledb-tune --quiet --yes
```

### 2.2 Database Configuration

```bash
# Edit PostgreSQL configuration
sudo nano /etc/postgresql/15/main/postgresql.conf
```

Apply the following optimizations:

```ini
# Connection settings
listen_addresses = '*'
port = 5432
max_connections = 200
superuser_reserved_connections = 3

# Memory settings (adjust based on available RAM)
shared_buffers = 8GB              # 25% of RAM
effective_cache_size = 24GB       # 75% of RAM
work_mem = 256MB
maintenance_work_mem = 2GB
wal_buffers = 64MB

# Performance settings
random_page_cost = 1.1           # For SSD storage
effective_io_concurrency = 200   # For SSD storage
max_worker_processes = 16
max_parallel_workers_per_gather = 8
max_parallel_workers = 16
max_parallel_maintenance_workers = 8

# WAL and checkpoints
wal_level = replica
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
wal_compression = on

# Extensions
shared_preload_libraries = 'timescaledb,pg_stat_statements'

# Logging
log_min_duration_statement = 1000
log_statement = 'ddl'
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB

# TimescaleDB specific
timescaledb.max_background_workers = 16
```

### 2.3 Security Configuration

```bash
# Configure client authentication
sudo nano /etc/postgresql/15/main/pg_hba.conf
```

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   walmart_bot     walmart_app                             md5
host    walmart_bot     walmart_app     10.0.0.0/8             md5
host    walmart_bot     walmart_app     127.0.0.1/32           md5

# Replication connections (if needed)
host    replication     postgres        10.0.0.0/8             md5
```

### 2.4 Database Creation and User Setup

```bash
# Start and enable PostgreSQL
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Create database and user
sudo -u postgres createdb walmart_bot
sudo -u postgres psql << EOF
-- Create application user
CREATE USER walmart_app WITH PASSWORD 'your-secure-password-here';

-- Grant permissions
GRANT ALL PRIVILEGES ON DATABASE walmart_bot TO walmart_app;
GRANT USAGE ON SCHEMA public TO walmart_app;
GRANT CREATE ON SCHEMA public TO walmart_app;

-- Set encryption key for application
ALTER DATABASE walmart_bot SET app.encryption_key = 'your-32-char-encryption-key-here';
EOF
```

### 2.5 Schema Deployment

```bash
# Apply the database schema
psql -U walmart_app -d walmart_bot -f walmart-bot-schema.sql

# Verify installation
psql -U walmart_app -d walmart_bot -c "
SELECT 
    COUNT(*) as table_count,
    (SELECT COUNT(*) FROM timescaledb_information.hypertables) as hypertables,
    (SELECT COUNT(*) FROM pg_extension WHERE extname IN ('timescaledb', 'uuid-ossp', 'pgcrypto')) as extensions
FROM information_schema.tables 
WHERE table_schema = 'public';
"
```

## Phase 3: Redis Setup

### 3.1 Installation

```bash
# Install Redis
sudo apt install -y redis-server

# Backup default configuration
sudo cp /etc/redis/redis.conf /etc/redis/redis.conf.backup

# Apply custom configuration
sudo cp walmart-bot-redis-config.conf /etc/redis/redis.conf

# Create Redis data directory
sudo mkdir -p /var/lib/redis
sudo chown redis:redis /var/lib/redis
sudo chmod 750 /var/lib/redis
```

### 3.2 Security Configuration

```bash
# Generate strong Redis password
REDIS_PASSWORD=$(openssl rand -base64 32)
echo "Redis password: $REDIS_PASSWORD"

# Update Redis configuration with password
sudo sed -i "s/# requirepass your-strong-password-here/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf

# Restrict Redis to internal network only
sudo sed -i 's/bind 127.0.0.1 ::1/bind 127.0.0.1 10.0.0.0\/8/' /etc/redis/redis.conf
```

### 3.3 Start and Enable Services

```bash
# Start Redis
sudo systemctl start redis-server
sudo systemctl enable redis-server

# Verify Redis is working
redis-cli -a "$REDIS_PASSWORD" ping
```

## Phase 4: Application Layer Setup

### 4.1 Python Environment

```bash
# Create application user
sudo useradd -m -s /bin/bash walmart-bot
sudo mkdir -p /opt/walmart-bot
sudo chown walmart-bot:walmart-bot /opt/walmart-bot

# Switch to application user
sudo -u walmart-bot -i

# Create virtual environment
cd /opt/walmart-bot
python3 -m venv venv
source venv/bin/activate

# Install required packages
pip install --upgrade pip
pip install \
    asyncpg \
    redis \
    sqlalchemy[asyncio] \
    alembic \
    psycopg2-binary \
    cryptography \
    aiohttp \
    fastapi \
    uvicorn \
    python-dotenv
```

### 4.2 Environment Configuration

```bash
# Create environment file
cat > /opt/walmart-bot/.env << EOF
# Database Configuration
DATABASE_URL=postgresql+asyncpg://walmart_app:your-secure-password-here@localhost:5432/walmart_bot
DATABASE_POOL_SIZE=20
DATABASE_MAX_OVERFLOW=30

# Redis Configuration  
REDIS_URL=redis://:$REDIS_PASSWORD@localhost:6379/0
REDIS_MAX_CONNECTIONS=50

# Security
ENCRYPTION_KEY=your-32-char-encryption-key-here
SECRET_KEY=your-secret-key-for-sessions

# Application Settings
LOG_LEVEL=INFO
ENVIRONMENT=production
BOT_MONITORING_INTERVAL=300

# Rate Limiting
DEFAULT_RATE_LIMIT=200
RATE_LIMIT_WINDOW=3600

# Performance
MAX_CONCURRENT_REQUESTS=50
REQUEST_TIMEOUT=30
SESSION_TIMEOUT=86400
EOF

# Secure the environment file
chmod 600 /opt/walmart-bot/.env
```

### 4.3 Application Deployment

```bash
# Copy application files
cp walmart-bot-data-access-patterns.py /opt/walmart-bot/
cp walmart-bot-schema.sql /opt/walmart-bot/

# Create startup script
cat > /opt/walmart-bot/start.py << 'EOF'
#!/usr/bin/env python3
import asyncio
import logging
import os
from dotenv import load_dotenv
from walmart_bot_data_access_patterns import WalmartBotDataLayer

# Load environment variables
load_dotenv()

async def main():
    """Initialize and start the Walmart bot data layer"""
    
    # Configuration from environment
    db_url = os.getenv('DATABASE_URL')
    redis_url = os.getenv('REDIS_URL') 
    encryption_key = os.getenv('ENCRYPTION_KEY')
    
    # Initialize data layer
    data_layer = WalmartBotDataLayer(db_url, redis_url, encryption_key)
    
    try:
        await data_layer.initialize()
        logging.info("Walmart bot data layer initialized successfully")
        
        # Keep the service running
        while True:
            await asyncio.sleep(60)
            
    except KeyboardInterrupt:
        logging.info("Shutting down...")
    finally:
        await data_layer.close()

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
EOF

chmod +x /opt/walmart-bot/start.py
```

## Phase 5: Monitoring and Maintenance

### 5.1 System Monitoring

```bash
# Create monitoring script
sudo tee /opt/walmart-bot/monitor.sh << 'EOF'
#!/bin/bash

# Check PostgreSQL status
echo "=== PostgreSQL Status ==="
sudo systemctl status postgresql --no-pager -l

# Check Redis status  
echo "=== Redis Status ==="
sudo systemctl status redis-server --no-pager -l

# Database connection test
echo "=== Database Connection Test ==="
psql -U walmart_app -d walmart_bot -c "SELECT version();"

# Redis connection test
echo "=== Redis Connection Test ==="
redis-cli -a "$REDIS_PASSWORD" ping

# Disk usage
echo "=== Disk Usage ==="
df -h /var/lib/postgresql /var/lib/redis

# Memory usage
echo "=== Memory Usage ==="
free -h

# Active connections
echo "=== Active Database Connections ==="
psql -U walmart_app -d walmart_bot -c "SELECT count(*) FROM pg_stat_activity;"

echo "=== Monitoring Complete ==="
EOF

chmod +x /opt/walmart-bot/monitor.sh
```

### 5.2 Backup Configuration

```bash
# Create backup script
sudo tee /opt/walmart-bot/backup.sh << 'EOF'
#!/bin/bash

BACKUP_DIR="/opt/backups/walmart-bot"
DATE=$(date +%Y%m%d_%H%M%S)

# Create backup directory
mkdir -p $BACKUP_DIR

# Database backup
echo "Backing up PostgreSQL database..."
pg_dump -U walmart_app -h localhost walmart_bot | gzip > "$BACKUP_DIR/walmart_bot_$DATE.sql.gz"

# Redis backup
echo "Backing up Redis data..."
redis-cli -a "$REDIS_PASSWORD" --rdb "$BACKUP_DIR/redis_dump_$DATE.rdb"

# Application configuration backup
echo "Backing up application configuration..."
tar -czf "$BACKUP_DIR/config_$DATE.tar.gz" /opt/walmart-bot/.env /etc/redis/redis.conf /etc/postgresql/15/main/

# Remove backups older than 7 days
find $BACKUP_DIR -name "*.gz" -mtime +7 -delete
find $BACKUP_DIR -name "*.rdb" -mtime +7 -delete

echo "Backup completed: $BACKUP_DIR"
EOF

chmod +x /opt/walmart-bot/backup.sh

# Schedule backups
sudo crontab -e
# Add the following line:
# 0 2 * * * /opt/walmart-bot/backup.sh
```

### 5.3 Performance Monitoring

```bash
# Create performance monitoring script
sudo tee /opt/walmart-bot/perf-monitor.py << 'EOF'
#!/usr/bin/env python3
import psutil
import asyncio
import asyncpg
import redis
import json
import time
from datetime import datetime

async def collect_metrics():
    """Collect system and database metrics"""
    metrics = {
        'timestamp': datetime.utcnow().isoformat(),
        'system': {
            'cpu_percent': psutil.cpu_percent(interval=1),
            'memory_percent': psutil.virtual_memory().percent,
            'disk_usage': psutil.disk_usage('/').percent,
            'load_average': psutil.getloadavg()
        }
    }
    
    # Database metrics
    try:
        conn = await asyncpg.connect(
            host='localhost',
            database='walmart_bot', 
            user='walmart_app',
            password='your-password'
        )
        
        # Active connections
        result = await conn.fetchval("SELECT count(*) FROM pg_stat_activity")
        metrics['database'] = {'active_connections': result}
        
        await conn.close()
    except Exception as e:
        metrics['database'] = {'error': str(e)}
    
    # Redis metrics
    try:
        r = redis.Redis(host='localhost', port=6379, password='redis-password')
        info = r.info()
        metrics['redis'] = {
            'used_memory': info['used_memory'],
            'connected_clients': info['connected_clients'],
            'total_commands_processed': info['total_commands_processed']
        }
    except Exception as e:
        metrics['redis'] = {'error': str(e)}
    
    return metrics

async def main():
    """Continuous performance monitoring"""
    while True:
        try:
            metrics = await collect_metrics()
            
            # Log to file
            with open('/var/log/walmart-bot-metrics.log', 'a') as f:
                f.write(json.dumps(metrics) + '\n')
            
            # Alert on high resource usage
            if metrics['system']['cpu_percent'] > 80:
                print(f"HIGH CPU ALERT: {metrics['system']['cpu_percent']:.1f}%")
            
            if metrics['system']['memory_percent'] > 90:
                print(f"HIGH MEMORY ALERT: {metrics['system']['memory_percent']:.1f}%")
                
        except Exception as e:
            print(f"Monitoring error: {e}")
        
        await asyncio.sleep(60)  # Collect metrics every minute

if __name__ == "__main__":
    asyncio.run(main())
EOF

chmod +x /opt/walmart-bot/perf-monitor.py
```

## Phase 6: SSL and Security Hardening

### 6.1 SSL Certificate Setup

```bash
# Install Certbot for Let's Encrypt
sudo apt install -y certbot

# Generate SSL certificate (replace your-domain.com)
sudo certbot certonly --standalone -d your-domain.com

# Configure PostgreSQL SSL
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem /var/lib/postgresql/15/main/server.crt
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem /var/lib/postgresql/15/main/server.key
sudo chown postgres:postgres /var/lib/postgresql/15/main/server.*
sudo chmod 600 /var/lib/postgresql/15/main/server.key

# Enable SSL in PostgreSQL
sudo -u postgres psql -c "ALTER SYSTEM SET ssl = on;"
sudo -u postgres psql -c "ALTER SYSTEM SET ssl_cert_file = '/var/lib/postgresql/15/main/server.crt';"
sudo -u postgres psql -c "ALTER SYSTEM SET ssl_key_file = '/var/lib/postgresql/15/main/server.key';"
sudo systemctl restart postgresql
```

### 6.2 Additional Security

```bash
# Install fail2ban for brute force protection
sudo apt install -y fail2ban

# Configure fail2ban
sudo tee /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true

[postgresql]
enabled = true
port = 5432
filter = postgresql
logpath = /var/log/postgresql/postgresql-*.log
maxretry = 3
EOF

# Start fail2ban
sudo systemctl start fail2ban
sudo systemctl enable fail2ban
```

## Phase 7: Testing and Validation

### 7.1 System Tests

```bash
# Test database performance
psql -U walmart_app -d walmart_bot -c "
EXPLAIN ANALYZE 
SELECT * FROM fast_inventory_check(
    ARRAY['550e8400-e29b-41d4-a716-446655440000']::uuid[], 
    '550e8400-e29b-41d4-a716-446655440001'::uuid
);
"

# Test Redis performance
redis-cli -a "$REDIS_PASSWORD" --latency-history -i 1

# Load test (using Apache Bench)
sudo apt install -y apache2-utils
ab -n 1000 -c 10 http://localhost:6379/
```

### 7.2 Deployment Validation

```bash
# Run comprehensive checks
/opt/walmart-bot/monitor.sh

# Check logs for errors
sudo tail -f /var/log/postgresql/postgresql-*.log
sudo tail -f /var/log/redis/redis-server.log
tail -f /var/log/walmart-bot-metrics.log
```

## Production Deployment Checklist

- [ ] System requirements met and optimized
- [ ] PostgreSQL 15 with TimescaleDB installed and configured
- [ ] Redis installed with custom configuration
- [ ] Database schema deployed successfully
- [ ] SSL certificates configured
- [ ] Firewall rules configured
- [ ] Backup system configured and tested
- [ ] Monitoring scripts deployed
- [ ] Performance tested under load
- [ ] Security hardening completed
- [ ] Application environment configured
- [ ] Log rotation configured
- [ ] Alerting system configured

## Maintenance Schedule

### Daily Tasks
- Monitor system resources and performance
- Check backup completion status
- Review error logs for issues
- Validate database and Redis connectivity

### Weekly Tasks  
- Analyze slow query logs
- Review security logs
- Test backup restoration procedures
- Update system packages

### Monthly Tasks
- Comprehensive security audit
- Performance baseline review
- Capacity planning assessment
- SSL certificate renewal (if needed)

This deployment guide provides a production-ready setup for the Walmart bot database infrastructure with optimal performance, security, and reliability.