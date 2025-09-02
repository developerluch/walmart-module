# Synvelo Database Implementation Guide

## Overview
This guide provides step-by-step instructions for implementing the Synvelo dual-site SaaS database architecture using PostgreSQL 15+ with TimescaleDB.

## Prerequisites

### System Requirements
- **PostgreSQL**: Version 15 or higher
- **TimescaleDB**: Version 2.10 or higher  
- **PostGIS**: Version 3.3 or higher
- **Memory**: Minimum 16GB RAM (32GB+ recommended for production)
- **Storage**: SSD with minimum 500 IOPS (10,000+ IOPS recommended)
- **CPU**: 8+ cores for production workloads

### Software Dependencies
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install postgresql-15 postgresql-15-postgis-3 postgresql-contrib
sudo apt-get install timescaledb-2-postgresql-15

# RedHat/CentOS
sudo dnf install postgresql15-server postgresql15-contrib postgis33_15
sudo dnf install timescaledb-postgresql-15
```

## Phase 1: Initial Setup

### 1.1 Database Creation
```bash
# Create database
sudo -u postgres createdb synvelo_production

# Create dedicated user
sudo -u postgres psql -c "CREATE USER synvelo_app WITH PASSWORD 'secure_password_here';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE synvelo_production TO synvelo_app;"
```

### 1.2 Extension Installation
```sql
-- Connect as superuser
\c synvelo_production postgres

-- Install required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "timescaledb";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Grant permissions to application user
GRANT USAGE ON SCHEMA public TO synvelo_app;
GRANT CREATE ON SCHEMA public TO synvelo_app;
```

### 1.3 PostgreSQL Configuration
Edit `/etc/postgresql/15/main/postgresql.conf`:

```ini
# Memory settings
shared_buffers = 4GB                    # 25% of RAM
effective_cache_size = 12GB             # 75% of RAM  
work_mem = 256MB
maintenance_work_mem = 2GB

# Connection settings
max_connections = 200
shared_preload_libraries = 'timescaledb,pg_stat_statements'

# WAL settings for replication
wal_level = replica
max_wal_senders = 5
max_replication_slots = 5
wal_keep_size = 1GB

# Background writer
bgwriter_delay = 200ms
bgwriter_lru_maxpages = 100
bgwriter_lru_multiplier = 2.0

# Checkpoint settings
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
max_wal_size = 4GB
min_wal_size = 1GB

# Logging
log_min_duration_statement = 1000
log_statement = 'ddl'
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

# TimescaleDB specific
timescaledb.max_background_workers = 8
```

### 1.4 pg_hba.conf Security
Edit `/etc/postgresql/15/main/pg_hba.conf`:

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   synvelo_production synvelo_app                          md5
host    synvelo_production synvelo_app    10.0.0.0/8            md5
host    synvelo_production synvelo_replica 10.0.0.0/8         md5

# Replication connections
host    replication     postgres        10.0.0.0/8             md5
```

## Phase 2: Schema Deployment

### 2.1 Apply Base Schema
```bash
# Apply main schema
psql -U synvelo_app -d synvelo_production -f synvelo-schema.sql

# Verify installation
psql -U synvelo_app -d synvelo_production -c "SELECT * FROM validate_migration_state();"
```

### 2.2 Apply Migration Framework
```bash
# Apply migration framework and initial migrations
psql -U synvelo_app -d synvelo_production -f synvelo-migrations.sql

# Check migration status
psql -U synvelo_app -d synvelo_production -c "SELECT * FROM migration_status();"
```

### 2.3 Set Up Maintenance Procedures
```bash
# Apply maintenance procedures
psql -U synvelo_app -d synvelo_production -f synvelo-maintenance.sql

# Create sample data (optional for testing)
psql -U synvelo_app -d synvelo_production -c "SELECT create_sample_data();"
```

## Phase 3: Production Optimization

### 3.1 Connection Pooling with PgBouncer
Install and configure PgBouncer:

```ini
# /etc/pgbouncer/pgbouncer.ini
[databases]
synvelo_production = host=localhost port=5432 dbname=synvelo_production user=synvelo_app

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
reserve_pool_size = 5
server_idle_timeout = 600
```

### 3.2 Read Replica Setup
```bash
# On replica server
pg_basebackup -h primary_server -D /var/lib/postgresql/15/main -U postgres -v -P -W

# Configure recovery.conf on replica
echo "standby_mode = 'on'" >> /var/lib/postgresql/15/main/postgresql.auto.conf
echo "primary_conninfo = 'host=primary_server port=5432 user=postgres'" >> /var/lib/postgresql/15/main/postgresql.auto.conf
```

### 3.3 Backup Configuration
```bash
# Install pgbackrest
sudo apt-get install pgbackrest

# Configure pgbackrest
cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
repo1-type=s3
repo1-s3-bucket=synvelo-db-backups
repo1-s3-endpoint=s3.amazonaws.com
repo1-s3-region=us-east-1
repo1-retention-full=7

[synvelo]
pg1-path=/var/lib/postgresql/15/main
pg1-port=5432
EOF

# Initialize repository
sudo -u postgres pgbackrest --stanza=synvelo stanza-create

# Create initial backup
sudo -u postgres pgbackrest --stanza=synvelo backup --type=full
```

## Phase 4: Monitoring Setup

### 4.1 PostgreSQL Monitoring
```sql
-- Create monitoring user
CREATE USER monitoring WITH PASSWORD 'monitoring_password';
GRANT pg_monitor TO monitoring;

-- Install pg_stat_statements views
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Create custom monitoring views
CREATE VIEW system_stats AS
SELECT 
    'connections' as metric,
    count(*) as value
FROM pg_stat_activity
UNION ALL
SELECT 
    'active_queries',
    count(*)
FROM pg_stat_activity 
WHERE state = 'active'
UNION ALL
SELECT
    'cache_hit_ratio',
    ROUND(100.0 * sum(heap_blks_hit) / GREATEST(sum(heap_blks_hit + heap_blks_read), 1), 2)
FROM pg_statio_user_tables;
```

### 4.2 Application Metrics
```sql
-- Create application metrics collection
CREATE TABLE metrics_collection (
    collected_at TIMESTAMPTZ PRIMARY KEY DEFAULT NOW(),
    metrics JSONB NOT NULL
);

-- Function to collect metrics
CREATE OR REPLACE FUNCTION collect_application_metrics()
RETURNS JSONB AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'orders_today', (SELECT count(*) FROM orders WHERE created_at >= CURRENT_DATE),
        'active_shipments', (SELECT count(*) FROM active_shipments),
        'inventory_items', (SELECT sum(quantity_available) FROM inventory),
        'organizations', (SELECT count(*) FROM organizations WHERE status = 'active'),
        'users', (SELECT count(*) FROM users WHERE status = 'active')
    ) INTO result;
    
    INSERT INTO metrics_collection (metrics) VALUES (result);
    RETURN result;
END;
$$ LANGUAGE plpgsql;
```

## Phase 5: Security Hardening

### 5.1 SSL/TLS Configuration
```bash
# Generate SSL certificates (or use Let's Encrypt)
sudo openssl req -new -x509 -days 365 -nodes -text -out server.crt \
  -keyout server.key -subj "/CN=synvelo-db.company.com"

# Set permissions
sudo chown postgres:postgres server.crt server.key
sudo chmod 600 server.key

# Enable SSL in postgresql.conf
ssl = on
ssl_cert_file = '/etc/ssl/certs/server.crt'
ssl_key_file = '/etc/ssl/private/server.key'
ssl_prefer_server_ciphers = on
```

### 5.2 Audit Logging
```sql
-- Install pgaudit extension
CREATE EXTENSION IF NOT EXISTS pgaudit;

-- Configure audit settings
ALTER SYSTEM SET pgaudit.log = 'write,ddl,role';
ALTER SYSTEM SET pgaudit.log_catalog = off;
ALTER SYSTEM SET pgaudit.log_parameter = on;
SELECT pg_reload_conf();
```

### 5.3 Data Encryption
```sql
-- Enable transparent data encryption for sensitive columns
CREATE OR REPLACE FUNCTION encrypt_pii(data TEXT)
RETURNS BYTEA AS $$
BEGIN
    RETURN pgp_sym_encrypt(data, current_setting('app.encryption_key'));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to decrypt PII
CREATE OR REPLACE FUNCTION decrypt_pii(encrypted_data BYTEA)
RETURNS TEXT AS $$
BEGIN
    RETURN pgp_sym_decrypt(encrypted_data, current_setting('app.encryption_key'));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

## Phase 6: Application Integration

### 6.1 Connection String Configuration
```bash
# Production connection string
DATABASE_URL="postgres://synvelo_app:password@pgbouncer:6432/synvelo_production?sslmode=require"

# Read replica connection string
DATABASE_REPLICA_URL="postgres://synvelo_app:password@replica:5432/synvelo_production?sslmode=require"
```

### 6.2 Multi-Tenancy Application Setup
```javascript
// Node.js/Express middleware for tenant isolation
const setTenantContext = async (req, res, next) => {
    const tenantId = req.headers['x-tenant-id'];
    if (!tenantId) {
        return res.status(400).json({ error: 'Tenant ID required' });
    }
    
    // Set PostgreSQL session variable for RLS
    await req.db.query(`SET app.current_tenant = '${tenantId}'`);
    next();
};

// Database connection with tenant context
const getTenantConnection = async (tenantId) => {
    const client = await pool.connect();
    await client.query(`SET app.current_tenant = '${tenantId}'`);
    return client;
};
```

### 6.3 Error Handling and Retry Logic
```javascript
// Connection retry logic
const executeWithRetry = async (query, params, maxRetries = 3) => {
    for (let i = 0; i < maxRetries; i++) {
        try {
            return await pool.query(query, params);
        } catch (error) {
            if (i === maxRetries - 1) throw error;
            
            // Check if it's a temporary error
            if (error.code === '53300' || error.code === '08006') {
                await new Promise(resolve => setTimeout(resolve, 1000 * (i + 1)));
                continue;
            }
            throw error;
        }
    }
};
```

## Phase 7: Performance Tuning

### 7.1 Query Optimization
```sql
-- Analyze query performance
SELECT 
    query,
    calls,
    total_time,
    mean_time,
    rows
FROM pg_stat_statements 
WHERE calls > 100 
ORDER BY mean_time DESC 
LIMIT 10;

-- Check for missing indexes
SELECT 
    schemaname,
    tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    seq_tup_read / GREATEST(seq_scan, 1) as avg_seq_read
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_tup_read DESC;
```

### 7.2 TimescaleDB Optimization
```sql
-- Configure chunk sizing for optimal performance
SELECT set_chunk_time_interval('tracking_events', INTERVAL '7 days');
SELECT set_chunk_time_interval('sla_measurements', INTERVAL '1 day');

-- Enable compression for older chunks
ALTER TABLE tracking_events SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'event_time DESC',
    timescaledb.compress_segmentby = 'shipment_id'
);

-- Set up compression policy
SELECT add_compression_policy('tracking_events', INTERVAL '7 days');
```

## Phase 8: Deployment Checklist

### 8.1 Pre-Deployment Validation
- [ ] All extensions installed and accessible
- [ ] Schema applied successfully with no errors
- [ ] Migration framework operational
- [ ] Sample data creates without errors
- [ ] All indexes created successfully
- [ ] TimescaleDB hypertables configured
- [ ] Row-level security policies active
- [ ] SSL/TLS certificates valid and trusted
- [ ] Backup system configured and tested
- [ ] Monitoring dashboards operational
- [ ] Connection pooling configured
- [ ] Read replicas synchronized

### 8.2 Production Deployment Steps
1. **Maintenance Window Setup**
   ```bash
   # Put application in maintenance mode
   echo "Application entering maintenance mode..."
   ```

2. **Final Schema Migration**
   ```bash
   # Apply any final migrations
   psql -U synvelo_app -d synvelo_production -c "SELECT migration_status();"
   ```

3. **Data Validation**
   ```bash
   # Run data integrity checks
   psql -U synvelo_app -d synvelo_production -c "SELECT * FROM check_data_integrity();"
   ```

4. **Performance Baseline**
   ```bash
   # Establish performance baseline
   psql -U synvelo_app -d synvelo_production -c "SELECT * FROM system_stats;"
   ```

5. **Application Startup**
   ```bash
   # Start application services
   systemctl start synvelo-api
   systemctl start synvelo-worker
   ```

### 8.3 Post-Deployment Verification
- [ ] Application connects successfully
- [ ] Multi-tenancy isolation working
- [ ] CRUD operations functioning
- [ ] Time-series data ingesting properly
- [ ] Backup jobs running successfully
- [ ] Monitoring alerts configured
- [ ] Performance within acceptable ranges
- [ ] Security policies enforced

## Phase 9: Ongoing Maintenance

### 9.1 Daily Tasks
```bash
#!/bin/bash
# daily-maintenance.sh

# Check system health
psql -U monitoring -d synvelo_production -c "SELECT * FROM db_health_metrics;"

# Collect application metrics
psql -U synvelo_app -d synvelo_production -c "SELECT collect_application_metrics();"

# Clean up expired sessions
psql -U synvelo_app -d synvelo_production -c "SELECT cleanup_expired_sessions();"

# Check backup status
pgbackrest --stanza=synvelo info
```

### 9.2 Weekly Tasks
```bash
#!/bin/bash
# weekly-maintenance.sh

# Analyze database statistics
psql -U synvelo_app -d synvelo_production -c "ANALYZE;"

# Refresh materialized views
psql -U synvelo_app -d synvelo_production -c "REFRESH MATERIALIZED VIEW CONCURRENTLY organization_metrics;"

# Check for query performance issues
psql -U monitoring -d synvelo_production -c "SELECT * FROM slow_queries;"

# Verify backup integrity
pgbackrest --stanza=synvelo --type=full backup
```

### 9.3 Monthly Tasks
```bash
#!/bin/bash
# monthly-maintenance.sh

# Run data integrity checks
psql -U synvelo_app -d synvelo_production -c "SELECT * FROM check_data_integrity();"

# Review retention policies
psql -U synvelo_app -d synvelo_production -c "SELECT * FROM data_retention_policies;"

# Performance review
psql -U monitoring -d synvelo_production -c "SELECT * FROM table_bloat;"

# Security audit
psql -U synvelo_app -d synvelo_production -c "SELECT count(*) FROM audit_logs WHERE occurred_at >= NOW() - INTERVAL '30 days';"
```

## Troubleshooting

### Common Issues

**1. Connection Limit Exceeded**
```sql
-- Check current connections
SELECT count(*) FROM pg_stat_activity;

-- Kill idle connections
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE state = 'idle' 
AND query_start < NOW() - INTERVAL '1 hour';
```

**2. Slow Query Performance**
```sql
-- Find slow queries
SELECT query, mean_time, calls 
FROM pg_stat_statements 
WHERE mean_time > 1000 
ORDER BY mean_time DESC;

-- Check for missing indexes
SELECT * FROM pg_stat_user_tables 
WHERE seq_scan > idx_scan 
AND n_tup_ins + n_tup_upd + n_tup_del > 0;
```

**3. TimescaleDB Chunk Issues**
```sql
-- Check chunk status
SELECT * FROM timescaledb_information.chunks;

-- Drop old chunks manually if needed
SELECT drop_chunks('tracking_events', INTERVAL '6 months');
```

**4. Replication Lag**
```sql
-- Check replication status
SELECT * FROM pg_stat_replication;

-- Check lag on replica
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), 
       pg_last_wal_receive_lsn() - pg_last_wal_replay_lsn() AS lag;
```

## Support and Documentation

### Log Files
- PostgreSQL: `/var/log/postgresql/postgresql-15-main.log`
- PgBouncer: `/var/log/pgbouncer/pgbouncer.log`
- Application: Check application-specific logging

### Monitoring Endpoints
- Database metrics: `SELECT * FROM system_stats;`
- Business metrics: `SELECT * FROM business_metrics;`
- Application health: `SELECT * FROM db_health_metrics;`

### Emergency Contacts
- Database Administrator: [Contact Information]
- System Administrator: [Contact Information]  
- Application Team Lead: [Contact Information]
- Emergency Escalation: [24/7 Support Line]

This implementation guide provides a comprehensive roadmap for deploying the Synvelo database architecture in a production environment with proper security, monitoring, and maintenance procedures.