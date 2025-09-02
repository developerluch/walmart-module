# Walmart Bot Operational Procedures

## Overview

This document provides comprehensive operational procedures for the Walmart Bot infrastructure, including deployment, monitoring, troubleshooting, and maintenance procedures.

## Table of Contents

1. [Daily Operations](#daily-operations)
2. [Deployment Procedures](#deployment-procedures)
3. [Monitoring and Alerting](#monitoring-and-alerting)
4. [Troubleshooting Guide](#troubleshooting-guide)
5. [Security Procedures](#security-procedures)
6. [Backup and Recovery](#backup-and-recovery)
7. [Performance Optimization](#performance-optimization)
8. [Proxy Management](#proxy-management)
9. [Emergency Procedures](#emergency-procedures)
10. [Maintenance Tasks](#maintenance-tasks)

## Daily Operations

### Morning Checklist

1. **System Health Check**
   ```bash
   cd /opt/walmart-bot
   ./scripts/health-check.sh
   ```

2. **Review Overnight Metrics**
   - Access Grafana dashboard: `http://server:3000`
   - Check for any alerts in Prometheus: `http://server:9090/alerts`
   - Review error logs: `journalctl -u walmart-bot --since yesterday`

3. **Proxy Status Verification**
   ```bash
   curl http://localhost:8080/api/v1/proxy/status
   ```

4. **Resource Utilization Check**
   ```bash
   ./scripts/maintenance.sh status
   ```

### Evening Checklist

1. **Performance Review**
   - Check scraping success rates
   - Review response times
   - Verify proxy rotation metrics

2. **Log Rotation Verification**
   ```bash
   ls -la /opt/walmart-bot/logs/
   ```

3. **Backup Verification**
   ```bash
   ls -la /opt/walmart-bot/backups/ | head -5
   ```

## Deployment Procedures

### Standard Deployment

1. **Pre-deployment Checks**
   ```bash
   # Check current system status
   ./scripts/health-check.sh
   
   # Verify resources
   df -h /opt/walmart-bot
   free -h
   ```

2. **Create Backup**
   ```bash
   ./scripts/backup.sh
   ```

3. **Deploy New Version**
   ```bash
   ./scripts/deploy.sh v1.2.3
   ```

4. **Post-deployment Verification**
   ```bash
   # Wait for services to stabilize
   sleep 120
   
   # Run health checks
   ./scripts/health-check.sh
   
   # Check logs for errors
   docker-compose logs walmart-bot --tail=50
   ```

### Emergency Rollback

If deployment fails or issues are detected:

```bash
# Stop current services
systemctl stop walmart-bot

# Restore from latest backup
LATEST_BACKUP=$(ls -1 /opt/walmart-bot/backups/ | grep backup_ | sort -r | head -1)
./scripts/restore.sh "$LATEST_BACKUP"

# Verify rollback
./scripts/health-check.sh
```

### Blue-Green Deployment

For zero-downtime deployments:

1. **Prepare Green Environment**
   ```bash
   # Create green docker-compose configuration
   cp docker-compose.yml docker-compose-green.yml
   sed -i 's/walmart-bot/walmart-bot-green/g' docker-compose-green.yml
   sed -i 's/8080:8080/8082:8080/g' docker-compose-green.yml
   ```

2. **Deploy to Green**
   ```bash
   docker-compose -f docker-compose-green.yml up -d walmart-bot-green
   ```

3. **Health Check Green Environment**
   ```bash
   curl -f http://localhost:8082/health
   ```

4. **Switch Traffic**
   ```bash
   # Update nginx configuration to point to green
   # Then reload nginx
   nginx -s reload
   ```

5. **Cleanup Blue Environment**
   ```bash
   docker-compose down
   ```

## Monitoring and Alerting

### Key Metrics to Monitor

1. **Application Metrics**
   - Request rate and response times
   - Error rates by endpoint
   - Proxy success/failure rates
   - Scraping task completion rates

2. **System Metrics**
   - CPU utilization
   - Memory usage
   - Disk space
   - Network I/O

3. **Database Metrics**
   - Connection pool usage
   - Query performance
   - Lock waits
   - Database size

### Alert Thresholds

| Metric | Warning | Critical |
|--------|---------|----------|
| Response Time (95th percentile) | > 2s | > 5s |
| Error Rate | > 1% | > 5% |
| CPU Usage | > 70% | > 90% |
| Memory Usage | > 80% | > 95% |
| Disk Usage | > 85% | > 95% |
| Proxy Failure Rate | > 20% | > 50% |

### Grafana Dashboard Panels

1. **System Overview**
   - Service status indicators
   - Request rate timeline
   - Error rate timeline
   - Resource utilization gauges

2. **Application Performance**
   - Response time percentiles
   - Request volume by endpoint
   - Database connection pool usage
   - Cache hit rates

3. **Proxy Management**
   - Active proxy count
   - Proxy failure rates
   - Rotation frequency
   - Geographic distribution

4. **Business Metrics**
   - Successful scraping jobs
   - Data processing rates
   - Queue depths
   - Cost per successful request

## Troubleshooting Guide

### Common Issues and Solutions

#### High Response Times

1. **Check system resources**
   ```bash
   htop
   iotop
   ```

2. **Identify bottlenecks**
   ```bash
   docker stats
   ```

3. **Check database performance**
   ```bash
   docker-compose exec postgres psql -U walmart_bot -c "
   SELECT query, mean_exec_time, calls 
   FROM pg_stat_statements 
   ORDER BY mean_exec_time DESC 
   LIMIT 10;"
   ```

4. **Review slow queries**
   ```bash
   grep "slow query" /opt/walmart-bot/logs/app.log
   ```

#### Proxy Issues

1. **Check proxy list status**
   ```bash
   curl http://localhost:8080/api/v1/proxy/list
   ```

2. **Validate proxy connectivity**
   ```bash
   # Test individual proxies
   curl --proxy proxy_ip:port http://httpbin.org/ip
   ```

3. **Update proxy list**
   ```bash
   # Update proxy files in /opt/walmart-bot/proxies/
   systemctl restart walmart-bot
   ```

#### Database Connection Issues

1. **Check connection pool**
   ```bash
   docker-compose exec postgres psql -U walmart_bot -c "
   SELECT state, count(*) 
   FROM pg_stat_activity 
   WHERE datname = 'walmart_bot' 
   GROUP BY state;"
   ```

2. **Check for long-running queries**
   ```bash
   docker-compose exec postgres psql -U walmart_bot -c "
   SELECT pid, now() - pg_stat_activity.query_start AS duration, query 
   FROM pg_stat_activity 
   WHERE state = 'active' 
   ORDER BY duration DESC;"
   ```

#### Memory Issues

1. **Identify memory usage**
   ```bash
   docker stats --no-stream
   ps aux --sort=-%mem | head
   ```

2. **Check for memory leaks**
   ```bash
   # Monitor memory usage over time
   while true; do 
     free -h
     docker stats --no-stream | grep walmart-bot
     sleep 60
   done
   ```

3. **Analyze Go memory usage**
   ```bash
   # Access pprof endpoint
   go tool pprof http://localhost:8080/debug/pprof/heap
   ```

#### Service Won't Start

1. **Check systemd status**
   ```bash
   systemctl status walmart-bot
   journalctl -u walmart-bot --lines=50
   ```

2. **Check Docker daemon**
   ```bash
   systemctl status docker
   docker info
   ```

3. **Verify configuration**
   ```bash
   docker-compose config
   ```

4. **Check dependencies**
   ```bash
   docker-compose ps
   ```

## Security Procedures

### Access Management

1. **SSH Access**
   - Use key-based authentication only
   - Regularly rotate SSH keys
   - Monitor SSH access logs

2. **Service Accounts**
   - Run services with minimal privileges
   - Regularly audit service account permissions
   - Use dedicated accounts for each service

### Security Monitoring

1. **Log Analysis**
   ```bash
   # Check for suspicious activity
   grep "authentication failure" /var/log/auth.log
   grep "POSSIBLE BREAK-IN ATTEMPT" /var/log/auth.log
   ```

2. **Fail2ban Status**
   ```bash
   fail2ban-client status
   fail2ban-client status sshd
   ```

3. **Security Updates**
   ```bash
   # Check for security updates
   apt list --upgradable | grep security
   
   # Apply security updates
   apt update && apt upgrade -y
   ```

### Regular Security Tasks

1. **Weekly**
   - Review access logs
   - Check for failed login attempts
   - Verify SSL certificate status

2. **Monthly**
   - Update system packages
   - Review user accounts
   - Audit file permissions

3. **Quarterly**
   - Rotate API keys
   - Review and update firewall rules
   - Conduct security assessment

## Backup and Recovery

### Backup Strategy

1. **Automated Daily Backups**
   - Database: Full backup at 2 AM UTC
   - Redis: Snapshot at 3 AM UTC
   - Configuration: Daily at 4 AM UTC
   - Application data: Daily at 5 AM UTC

2. **Weekly Full System Backup**
   ```bash
   # Full system backup script
   #!/bin/bash
   tar czf /backup/walmart-bot-full-$(date +%Y%m%d).tar.gz \
     --exclude=/opt/walmart-bot/logs \
     /opt/walmart-bot
   ```

3. **Off-site Backup**
   ```bash
   # Sync to remote storage
   rsync -avz /opt/walmart-bot/backups/ user@backup-server:/backups/walmart-bot/
   ```

### Recovery Procedures

1. **Database Recovery**
   ```bash
   # Stop services
   systemctl stop walmart-bot
   
   # Restore database
   ./scripts/restore.sh backup_YYYYMMDD_HHMMSS
   
   # Verify integrity
   docker-compose exec postgres psql -U walmart_bot -c "\dt"
   
   # Start services
   systemctl start walmart-bot
   ```

2. **Configuration Recovery**
   ```bash
   # Restore configuration from backup
   tar xzf backup_YYYYMMDD_HHMMSS/configs.tar.gz -C /opt/walmart-bot/
   
   # Reload services
   systemctl reload walmart-bot
   ```

3. **Disaster Recovery**
   ```bash
   # Full system restore from scratch
   ./walmart-bot-deployment-scripts.sh install
   ./scripts/restore.sh latest_backup
   ```

### Backup Verification

1. **Daily Backup Checks**
   ```bash
   # Verify backup integrity
   for backup in /opt/walmart-bot/backups/backup_*/database.sql.gz; do
     if gzip -t "$backup"; then
       echo "✓ $backup is valid"
     else
       echo "✗ $backup is corrupted"
     fi
   done
   ```

2. **Monthly Recovery Tests**
   ```bash
   # Test recovery on staging environment
   ./scripts/restore.sh backup_test staging-environment
   ```

## Performance Optimization

### Go Application Optimization

1. **Memory Management**
   ```go
   // Set appropriate GOMAXPROCS
   runtime.GOMAXPROCS(runtime.NumCPU())
   
   // Tune garbage collector
   debug.SetGCPercent(100)
   ```

2. **Connection Pooling**
   ```go
   // Database connection pool settings
   db.SetMaxOpenConns(25)
   db.SetMaxIdleConns(10)
   db.SetConnMaxLifetime(300 * time.Second)
   ```

3. **Profiling**
   ```bash
   # CPU profiling
   go tool pprof http://localhost:8080/debug/pprof/profile?seconds=30
   
   # Memory profiling
   go tool pprof http://localhost:8080/debug/pprof/heap
   
   # Goroutine profiling
   go tool pprof http://localhost:8080/debug/pprof/goroutine
   ```

### Python Service Optimization

1. **Worker Configuration**
   ```python
   # Gunicorn settings
   workers = multiprocessing.cpu_count() * 2 + 1
   worker_class = "uvicorn.workers.UvicornWorker"
   max_requests = 1000
   max_requests_jitter = 50
   ```

2. **Memory Optimization**
   ```python
   # Use connection pooling
   import aioredis
   
   pool = aioredis.ConnectionPool.from_url(
       redis_url,
       max_connections=20,
       retry_on_timeout=True
   )
   ```

### Database Optimization

1. **Query Optimization**
   ```sql
   -- Enable query statistics
   CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
   
   -- Find slow queries
   SELECT query, mean_exec_time, calls 
   FROM pg_stat_statements 
   ORDER BY mean_exec_time DESC 
   LIMIT 10;
   ```

2. **Index Management**
   ```sql
   -- Find missing indexes
   SELECT schemaname, tablename, attname, n_distinct, correlation
   FROM pg_stats
   WHERE n_distinct > 100
   AND correlation < 0.1;
   ```

3. **Connection Pool Tuning**
   ```postgresql
   # postgresql.conf
   max_connections = 200
   shared_buffers = 256MB
   effective_cache_size = 1GB
   work_mem = 4MB
   maintenance_work_mem = 64MB
   ```

## Proxy Management

### Proxy List Management

1. **Proxy Sources**
   - Maintain multiple proxy providers
   - Regular rotation of proxy lists
   - Geographic distribution of proxies

2. **Proxy Validation**
   ```bash
   # Validate proxy functionality
   validate_proxy() {
       local proxy="$1"
       timeout 10 curl --proxy "$proxy" -s http://httpbin.org/ip > /dev/null
       return $?
   }
   ```

3. **Proxy Rotation Strategy**
   ```yaml
   # Rotation configuration
   rotation:
     interval: 180s          # Rotate every 3 minutes
     health_check: 60s       # Check health every minute
     failure_threshold: 3    # Mark as failed after 3 failures
     recovery_time: 300s     # Retry failed proxies after 5 minutes
   ```

### Proxy Monitoring

1. **Success Rate Tracking**
   ```bash
   # Monitor proxy success rates
   curl http://localhost:8080/metrics | grep proxy_success_rate
   ```

2. **Geographic Distribution**
   ```bash
   # Check proxy geographic distribution
   curl http://localhost:8080/api/v1/proxy/geo-distribution
   ```

3. **Performance Metrics**
   - Response time per proxy
   - Success rate by region
   - Cost per successful request

## Emergency Procedures

### Service Outage Response

1. **Immediate Response (0-5 minutes)**
   ```bash
   # Check service status
   systemctl status walmart-bot
   docker-compose ps
   
   # Check system resources
   free -h
   df -h
   uptime
   ```

2. **Investigation (5-15 minutes)**
   ```bash
   # Check logs for errors
   journalctl -u walmart-bot --lines=100
   docker-compose logs --tail=100
   
   # Check external dependencies
   curl -I http://walmart.com
   ```

3. **Recovery Actions (15-30 minutes)**
   ```bash
   # Restart services
   systemctl restart walmart-bot
   
   # Or rollback if needed
   ./scripts/restore.sh latest_backup
   ```

### High Load Response

1. **Scale Horizontally**
   ```bash
   # Increase container replicas
   docker-compose up -d --scale walmart-bot=3
   ```

2. **Optimize Resources**
   ```bash
   # Adjust memory limits
   docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d
   ```

3. **Enable Rate Limiting**
   ```bash
   # Update nginx configuration for stricter rate limiting
   nginx -s reload
   ```

### Data Corruption Response

1. **Stop Data Processing**
   ```bash
   # Pause scraping operations
   curl -X POST http://localhost:8080/api/v1/admin/pause
   ```

2. **Assess Damage**
   ```bash
   # Check data integrity
   docker-compose exec postgres psql -U walmart_bot -c "
   SELECT COUNT(*) FROM products WHERE created_at > NOW() - INTERVAL '1 hour';"
   ```

3. **Restore from Backup**
   ```bash
   # Find last known good backup
   ./scripts/restore.sh backup_before_corruption
   ```

## Maintenance Tasks

### Daily Automated Tasks

1. **Log Rotation**
   - Configured via logrotate
   - Keeps 30 days of logs
   - Compresses older logs

2. **Health Checks**
   - Runs every 15 minutes via cron
   - Alerts on failures
   - Records metrics

3. **Backup Creation**
   - Database backup at 2 AM UTC
   - Configuration backup at 4 AM UTC
   - Retention: 30 days

### Weekly Tasks

1. **System Updates**
   ```bash
   # Security updates only
   apt update
   apt list --upgradable | grep security
   apt upgrade -y
   ```

2. **Performance Review**
   - Analyze metrics from past week
   - Identify optimization opportunities
   - Review proxy performance

3. **Capacity Planning**
   - Review resource usage trends
   - Plan for scaling needs
   - Update resource reservations

### Monthly Tasks

1. **Full System Backup**
   ```bash
   # Create full system backup
   tar czf /backup/walmart-bot-full-$(date +%Y%m%d).tar.gz /opt/walmart-bot
   ```

2. **Certificate Renewal**
   ```bash
   # Check SSL certificate expiry
   certbot renew --dry-run
   ```

3. **Dependency Updates**
   ```bash
   # Update Go modules
   go get -u all
   go mod tidy
   
   # Update Python packages
   pip list --outdated
   ```

### Quarterly Tasks

1. **Security Audit**
   - Review access logs
   - Update secrets and keys
   - Security vulnerability scan

2. **Disaster Recovery Testing**
   - Test backup restoration
   - Verify recovery procedures
   - Update documentation

3. **Performance Benchmarking**
   - Run load tests
   - Compare with previous quarters
   - Plan optimization efforts

## Monitoring Dashboard Configuration

### Grafana Dashboard Setup

1. **Import Dashboard**
   ```bash
   # Import pre-configured dashboard
   curl -X POST http://admin:password@localhost:3000/api/dashboards/db \
     -H "Content-Type: application/json" \
     -d @grafana-dashboard.json
   ```

2. **Key Panels**
   - System overview
   - Application performance
   - Proxy status
   - Business metrics

### Alerting Rules

1. **Critical Alerts**
   - Service down
   - High error rate
   - Database connectivity issues

2. **Warning Alerts**
   - High resource usage
   - Slow response times
   - Proxy failures

### Alert Channels

1. **Slack Integration**
   ```yaml
   - name: slack-alerts
     type: slack
     settings:
       webhook_url: https://hooks.slack.com/services/...
       channel: #alerts
   ```

2. **Email Notifications**
   ```yaml
   - name: email-alerts
     type: email
     settings:
       addresses: admin@example.com
   ```

## Documentation Updates

This document should be updated:
- After each major deployment
- When procedures change
- When new monitoring is added
- During post-incident reviews

For questions or updates to this document, contact the DevOps team.