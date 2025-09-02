# Walmart Bot Data Persistence and Caching Strategy

## Executive Summary

This document outlines a comprehensive data persistence and caching strategy for the Walmart bot operation, designed for high-frequency inventory monitoring, secure credential storage, and optimal performance. The architecture leverages a hybrid approach combining PostgreSQL for durable storage with Redis for high-performance caching.

## Database Architecture Decision

### Primary Database: PostgreSQL 15+
**Rationale:**
- **ACID Compliance**: Critical for order consistency and audit trails
- **JSONB Support**: Flexible storage for API responses and configuration
- **Advanced Indexing**: GiST/GIN indexes for complex queries on JSON data
- **Row-Level Security**: Secure multi-tenant isolation for multiple bot instances
- **TimescaleDB Extension**: Optimized time-series storage for monitoring data

### Caching Layer: Redis 7+
**Rationale:**
- **Sub-millisecond Access**: Essential for high-frequency inventory checks
- **Session Management**: Efficient cookie and token storage with TTL
- **Rate Limiting**: Built-in support for API throttling
- **Pub/Sub**: Real-time notifications for inventory changes

## Complete Database Schema Design

### 1. Core Bot Management Schema

```sql
-- Bot instances and configurations
CREATE TABLE bot_instances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    environment VARCHAR(20) DEFAULT 'production', -- 'development', 'staging', 'production'
    status bot_status DEFAULT 'stopped',
    config JSONB NOT NULL DEFAULT '{}',
    proxy_pool_id UUID,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    last_heartbeat TIMESTAMPTZ,
    
    CONSTRAINT valid_environment CHECK (environment IN ('development', 'staging', 'production'))
);

CREATE TYPE bot_status AS ENUM ('stopped', 'starting', 'running', 'paused', 'error', 'maintenance');

-- Encrypted credential storage
CREATE TABLE bot_credentials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    credential_type VARCHAR(50) NOT NULL, -- 'walmart_account', 'proxy', 'notification'
    account_identifier VARCHAR(255), -- username, email, etc
    encrypted_data BYTEA NOT NULL, -- pgp_sym_encrypt() encrypted JSON
    expires_at TIMESTAMPTZ,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    
    UNIQUE(bot_instance_id, credential_type, account_identifier)
);

-- Proxy pool management
CREATE TABLE proxy_pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    provider VARCHAR(50) NOT NULL,
    config JSONB NOT NULL DEFAULT '{}',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE proxy_endpoints (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pool_id UUID NOT NULL REFERENCES proxy_pools(id) ON DELETE CASCADE,
    endpoint_url VARCHAR(500) NOT NULL,
    auth_data JSONB,
    performance_score DECIMAL(3,2) DEFAULT 1.0,
    failure_count INTEGER DEFAULT 0,
    last_success_at TIMESTAMPTZ,
    last_failure_at TIMESTAMPTZ,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 2. Session and Authentication Management

```sql
-- Bot session tracking
CREATE TABLE bot_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    session_type VARCHAR(50) NOT NULL, -- 'walmart_web', 'walmart_api', 'proxy'
    session_data JSONB NOT NULL, -- cookies, tokens, headers
    proxy_endpoint_id UUID REFERENCES proxy_endpoints(id),
    created_at TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    is_valid BOOLEAN DEFAULT TRUE,
    
    -- TimescaleDB partition key
    PRIMARY KEY (created_at, id)
);

-- Convert to hypertable for session management
SELECT create_hypertable('bot_sessions', 'created_at', chunk_time_interval => INTERVAL '1 day');

-- Session performance tracking
CREATE TABLE session_performance (
    id UUID DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL,
    measured_at TIMESTAMPTZ NOT NULL,
    metric_name VARCHAR(50) NOT NULL, -- 'response_time', 'success_rate', 'captcha_rate'
    metric_value DECIMAL(10,4) NOT NULL,
    metadata JSONB DEFAULT '{}',
    
    PRIMARY KEY (measured_at, id)
);

SELECT create_hypertable('session_performance', 'measured_at', chunk_time_interval => INTERVAL '1 hour');
```

### 3. Order History and Transaction Tracking

```sql
-- Order history storage
CREATE TABLE walmart_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    walmart_order_id VARCHAR(100) NOT NULL,
    account_identifier VARCHAR(255) NOT NULL,
    order_data JSONB NOT NULL, -- Full order details from Walmart
    order_status VARCHAR(50),
    order_total DECIMAL(12,2),
    order_date TIMESTAMPTZ,
    tracking_numbers TEXT[],
    delivery_date TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(walmart_order_id, account_identifier)
);

-- Order item details
CREATE TABLE walmart_order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES walmart_orders(id) ON DELETE CASCADE,
    walmart_item_id VARCHAR(100),
    product_name TEXT NOT NULL,
    sku VARCHAR(100),
    upc VARCHAR(20),
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(10,2),
    total_price DECIMAL(10,2),
    item_status VARCHAR(50),
    tracking_data JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Transaction log for audit purposes
CREATE TABLE order_transactions (
    id UUID DEFAULT gen_random_uuid(),
    occurred_at TIMESTAMPTZ NOT NULL,
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    transaction_type VARCHAR(50) NOT NULL, -- 'order_placed', 'order_cancelled', 'item_modified'
    walmart_order_id VARCHAR(100),
    account_identifier VARCHAR(255),
    details JSONB NOT NULL,
    success BOOLEAN NOT NULL,
    error_message TEXT,
    
    PRIMARY KEY (occurred_at, id)
);

SELECT create_hypertable('order_transactions', 'occurred_at', chunk_time_interval => INTERVAL '7 days');
```

### 4. High-Frequency Inventory Monitoring

```sql
-- Product monitoring configuration
CREATE TABLE monitored_products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    product_identifier VARCHAR(100) NOT NULL, -- SKU, UPC, or Walmart ID
    product_name TEXT,
    target_price DECIMAL(10,2),
    monitor_frequency INTERVAL DEFAULT INTERVAL '5 minutes',
    alert_conditions JSONB DEFAULT '{}', -- price drops, availability changes, etc
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(bot_instance_id, product_identifier)
);

-- Real-time inventory data (time-series optimized)
CREATE TABLE inventory_snapshots (
    id UUID DEFAULT gen_random_uuid(),
    recorded_at TIMESTAMPTZ NOT NULL,
    product_id UUID NOT NULL REFERENCES monitored_products(id) ON DELETE CASCADE,
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    availability_status VARCHAR(50), -- 'in_stock', 'out_of_stock', 'limited', 'unknown'
    current_price DECIMAL(10,2),
    original_price DECIMAL(10,2),
    discount_percentage DECIMAL(5,2),
    quantity_available INTEGER,
    location_data JSONB, -- store/zip specific data
    raw_response JSONB, -- full API response for debugging
    
    PRIMARY KEY (recorded_at, id)
);

SELECT create_hypertable('inventory_snapshots', 'recorded_at', chunk_time_interval => INTERVAL '6 hours');

-- Price change detection and alerts
CREATE TABLE price_change_events (
    id UUID DEFAULT gen_random_uuid(),
    detected_at TIMESTAMPTZ NOT NULL,
    product_id UUID NOT NULL REFERENCES monitored_products(id) ON DELETE CASCADE,
    previous_price DECIMAL(10,2),
    new_price DECIMAL(10,2),
    price_change_pct DECIMAL(8,4),
    change_type VARCHAR(20), -- 'increase', 'decrease'
    notification_sent BOOLEAN DEFAULT FALSE,
    
    PRIMARY KEY (detected_at, id)
);

SELECT create_hypertable('price_change_events', 'detected_at', chunk_time_interval => INTERVAL '1 day');
```

### 5. Request/Response Logging and Replay System

```sql
-- HTTP request/response logging
CREATE TABLE http_requests (
    id UUID DEFAULT gen_random_uuid(),
    timestamp TIMESTAMPTZ NOT NULL,
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    session_id UUID,
    request_method VARCHAR(10) NOT NULL,
    request_url TEXT NOT NULL,
    request_headers JSONB,
    request_body TEXT,
    response_status INTEGER,
    response_headers JSONB,
    response_body TEXT,
    response_time_ms INTEGER,
    proxy_used VARCHAR(500),
    success BOOLEAN,
    error_type VARCHAR(50),
    error_message TEXT,
    
    PRIMARY KEY (timestamp, id)
);

SELECT create_hypertable('http_requests', 'timestamp', chunk_time_interval => INTERVAL '1 day');

-- Request replay configurations
CREATE TABLE replay_scenarios (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    description TEXT,
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    scenario_config JSONB NOT NULL, -- filters, conditions, actions
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Replay execution tracking
CREATE TABLE replay_executions (
    id UUID DEFAULT gen_random_uuid(),
    executed_at TIMESTAMPTZ NOT NULL,
    scenario_id UUID NOT NULL REFERENCES replay_scenarios(id) ON DELETE CASCADE,
    original_request_ids UUID[] NOT NULL,
    replay_results JSONB,
    success_count INTEGER DEFAULT 0,
    failure_count INTEGER DEFAULT 0,
    
    PRIMARY KEY (executed_at, id)
);

SELECT create_hypertable('replay_executions', 'executed_at', chunk_time_interval => INTERVAL '7 days');
```

### 6. Performance Monitoring and Analytics

```sql
-- Bot performance metrics
CREATE TABLE bot_performance_metrics (
    id UUID DEFAULT gen_random_uuid(),
    measured_at TIMESTAMPTZ NOT NULL,
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    metric_category VARCHAR(50) NOT NULL, -- 'api_performance', 'proxy_health', 'success_rate'
    metric_name VARCHAR(100) NOT NULL,
    metric_value DECIMAL(15,4) NOT NULL,
    metric_unit VARCHAR(20), -- 'ms', 'percentage', 'count', 'bytes'
    tags JSONB DEFAULT '{}',
    
    PRIMARY KEY (measured_at, id)
);

SELECT create_hypertable('bot_performance_metrics', 'measured_at', chunk_time_interval => INTERVAL '1 hour');

-- Proxy performance tracking
CREATE TABLE proxy_performance (
    id UUID DEFAULT gen_random_uuid(),
    measured_at TIMESTAMPTZ NOT NULL,
    proxy_endpoint_id UUID NOT NULL REFERENCES proxy_endpoints(id) ON DELETE CASCADE,
    response_time_ms INTEGER,
    success_rate DECIMAL(5,2),
    captcha_rate DECIMAL(5,2),
    block_rate DECIMAL(5,2),
    location_data JSONB,
    
    PRIMARY KEY (measured_at, id)
);

SELECT create_hypertable('proxy_performance', 'measured_at', chunk_time_interval => INTERVAL '1 hour');
```

### 7. Configuration and Rule Management

```sql
-- Dynamic configuration management
CREATE TABLE bot_configurations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    config_key VARCHAR(100) NOT NULL,
    config_value JSONB NOT NULL,
    config_type VARCHAR(50) NOT NULL, -- 'monitoring', 'authentication', 'proxy', 'alert'
    is_encrypted BOOLEAN DEFAULT FALSE,
    version INTEGER DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(bot_instance_id, config_key)
);

-- Alert and notification rules
CREATE TABLE alert_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_instance_id UUID NOT NULL REFERENCES bot_instances(id) ON DELETE CASCADE,
    rule_name VARCHAR(100) NOT NULL,
    trigger_conditions JSONB NOT NULL, -- complex conditions for alerts
    alert_channels JSONB NOT NULL, -- email, slack, webhook, etc
    cooldown_period INTERVAL DEFAULT INTERVAL '5 minutes',
    is_active BOOLEAN DEFAULT TRUE,
    last_triggered TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Alert execution log
CREATE TABLE alert_executions (
    id UUID DEFAULT gen_random_uuid(),
    triggered_at TIMESTAMPTZ NOT NULL,
    alert_rule_id UUID NOT NULL REFERENCES alert_rules(id) ON DELETE CASCADE,
    trigger_data JSONB NOT NULL,
    alert_sent BOOLEAN DEFAULT FALSE,
    delivery_status JSONB DEFAULT '{}',
    
    PRIMARY KEY (triggered_at, id)
);

SELECT create_hypertable('alert_executions', 'triggered_at', chunk_time_interval => INTERVAL '7 days');
```

## Redis Caching Strategy

### 1. Cache Structure Design

```redis
# Session Management
walmart:session:{bot_id}:{session_type} -> {
    "cookies": {...},
    "tokens": {...},
    "headers": {...},
    "expires": 1640995200,
    "proxy_id": "uuid"
}
TTL: 24 hours

# Product Inventory Cache
walmart:inventory:{product_id} -> {
    "price": 29.99,
    "availability": "in_stock",
    "last_updated": 1640995200,
    "quantity": 100,
    "location": {...}
}
TTL: 5 minutes (high-frequency items), 1 hour (normal items)

# Proxy Performance Cache
walmart:proxy:{proxy_id}:performance -> {
    "avg_response_time": 250,
    "success_rate": 0.95,
    "last_success": 1640995200,
    "failure_count": 2
}
TTL: 10 minutes

# Rate Limiting
walmart:ratelimit:{bot_id}:{endpoint} -> {
    "count": 150,
    "window_start": 1640995200,
    "limit": 200,
    "window_size": 3600
}
TTL: 1 hour

# Configuration Cache
walmart:config:{bot_id} -> {
    "monitoring_frequency": 300,
    "proxy_rotation": true,
    "alert_rules": [...],
    "version": 12
}
TTL: 1 hour, invalidate on config change
```

### 2. Cache Access Patterns

```python
# High-Performance Inventory Lookup
class InventoryCache:
    def get_product_status(self, product_id: str) -> dict:
        cache_key = f"walmart:inventory:{product_id}"
        cached = redis.get(cache_key)
        
        if cached:
            data = json.loads(cached)
            # Check if data is still fresh
            if time.time() - data['last_updated'] < 300:  # 5 minutes
                return data
        
        # Cache miss or stale data - trigger background refresh
        self.queue_inventory_refresh(product_id)
        return self.get_from_database(product_id)

# Session Management with Automatic Refresh
class SessionManager:
    def get_valid_session(self, bot_id: str, session_type: str) -> dict:
        cache_key = f"walmart:session:{bot_id}:{session_type}"
        session = redis.hgetall(cache_key)
        
        if not session or int(session.get('expires', 0)) < time.time():
            # Session expired - create new one
            new_session = self.create_new_session(bot_id, session_type)
            self.cache_session(cache_key, new_session)
            return new_session
        
        return session
```

## Performance Optimization Strategy

### 1. Indexing Strategy

```sql
-- Critical indexes for bot operations

-- Session lookups by bot and type
CREATE INDEX CONCURRENTLY idx_bot_sessions_bot_type_expires 
ON bot_sessions (bot_instance_id, session_type, expires_at DESC) 
WHERE is_valid = TRUE;

-- Inventory monitoring by product and time
CREATE INDEX CONCURRENTLY idx_inventory_snapshots_product_time 
ON inventory_snapshots (product_id, recorded_at DESC);

-- Price change detection
CREATE INDEX CONCURRENTLY idx_price_changes_product_detected 
ON price_change_events (product_id, detected_at DESC);

-- Request logging for replay and debugging
CREATE INDEX CONCURRENTLY idx_http_requests_bot_timestamp 
ON http_requests (bot_instance_id, timestamp DESC);

-- Performance monitoring
CREATE INDEX CONCURRENTLY idx_performance_metrics_bot_category_time 
ON bot_performance_metrics (bot_instance_id, metric_category, measured_at DESC);

-- Proxy performance tracking
CREATE INDEX CONCURRENTLY idx_proxy_performance_endpoint_time 
ON proxy_performance (proxy_endpoint_id, measured_at DESC);

-- Configuration lookups
CREATE INDEX CONCURRENTLY idx_bot_configs_bot_type 
ON bot_configurations (bot_instance_id, config_type);

-- Alert rule execution
CREATE INDEX CONCURRENTLY idx_alert_executions_rule_triggered 
ON alert_executions (alert_rule_id, triggered_at DESC);

-- GIN indexes for JSON searches
CREATE INDEX CONCURRENTLY idx_walmart_orders_data 
ON walmart_orders USING gin(order_data);

CREATE INDEX CONCURRENTLY idx_inventory_raw_response 
ON inventory_snapshots USING gin(raw_response);

CREATE INDEX CONCURRENTLY idx_http_requests_headers 
ON http_requests USING gin(request_headers);
```

### 2. Data Partitioning Strategy

```sql
-- Time-based partitioning for high-volume tables
SELECT set_chunk_time_interval('bot_sessions', INTERVAL '1 day');
SELECT set_chunk_time_interval('session_performance', INTERVAL '1 hour');
SELECT set_chunk_time_interval('inventory_snapshots', INTERVAL '6 hours');
SELECT set_chunk_time_interval('http_requests', INTERVAL '1 day');
SELECT set_chunk_time_interval('bot_performance_metrics', INTERVAL '1 hour');

-- Enable compression for older data
ALTER TABLE inventory_snapshots SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'recorded_at DESC',
    timescaledb.compress_segmentby = 'product_id'
);

ALTER TABLE http_requests SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'timestamp DESC',
    timescaledb.compress_segmentby = 'bot_instance_id'
);

-- Compression policies
SELECT add_compression_policy('inventory_snapshots', INTERVAL '1 day');
SELECT add_compression_policy('http_requests', INTERVAL '7 days');
```

## Data Retention Policies

### 1. Automated Data Cleanup

```sql
-- Retention policies for time-series data
SELECT add_retention_policy('bot_sessions', INTERVAL '30 days');
SELECT add_retention_policy('session_performance', INTERVAL '90 days');
SELECT add_retention_policy('inventory_snapshots', INTERVAL '1 year');
SELECT add_retention_policy('price_change_events', INTERVAL '2 years');
SELECT add_retention_policy('http_requests', INTERVAL '6 months');
SELECT add_retention_policy('bot_performance_metrics', INTERVAL '1 year');
SELECT add_retention_policy('proxy_performance', INTERVAL '6 months');
SELECT add_retention_policy('alert_executions', INTERVAL '1 year');

-- Custom cleanup for sensitive data
CREATE OR REPLACE FUNCTION cleanup_expired_credentials()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM bot_credentials 
    WHERE expires_at < NOW() - INTERVAL '7 days';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    INSERT INTO order_transactions (
        occurred_at, bot_instance_id, transaction_type, 
        details, success
    ) VALUES (
        NOW(), '00000000-0000-0000-0000-000000000000', 'credential_cleanup',
        jsonb_build_object('deleted_count', deleted_count), TRUE
    );
    
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;
```

### 2. Data Archival Strategy

```sql
-- Create archive tables for long-term storage
CREATE TABLE archived_http_requests (LIKE http_requests INCLUDING ALL);
CREATE TABLE archived_inventory_snapshots (LIKE inventory_snapshots INCLUDING ALL);

-- Archive old data procedure
CREATE OR REPLACE FUNCTION archive_old_data()
RETURNS VOID AS $$
BEGIN
    -- Archive HTTP requests older than 6 months
    WITH moved_requests AS (
        DELETE FROM http_requests 
        WHERE timestamp < NOW() - INTERVAL '6 months'
        RETURNING *
    )
    INSERT INTO archived_http_requests SELECT * FROM moved_requests;
    
    -- Archive inventory data older than 1 year
    WITH moved_inventory AS (
        DELETE FROM inventory_snapshots 
        WHERE recorded_at < NOW() - INTERVAL '1 year'
        RETURNING *
    )
    INSERT INTO archived_inventory_snapshots SELECT * FROM moved_inventory;
    
    RAISE NOTICE 'Data archival completed at %', NOW();
END;
$$ LANGUAGE plpgsql;
```

## Security Implementation

### 1. Credential Encryption

```sql
-- Secure credential storage functions
CREATE OR REPLACE FUNCTION store_encrypted_credential(
    p_bot_instance_id UUID,
    p_credential_type VARCHAR,
    p_account_identifier VARCHAR,
    p_credential_data JSONB,
    p_expires_at TIMESTAMPTZ DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_credential_id UUID;
    v_encrypted_data BYTEA;
BEGIN
    -- Encrypt the credential data
    v_encrypted_data := pgp_sym_encrypt(
        p_credential_data::text, 
        current_setting('app.encryption_key')
    );
    
    INSERT INTO bot_credentials (
        bot_instance_id, credential_type, account_identifier,
        encrypted_data, expires_at
    ) VALUES (
        p_bot_instance_id, p_credential_type, p_account_identifier,
        v_encrypted_data, p_expires_at
    ) RETURNING id INTO v_credential_id;
    
    -- Log credential creation
    INSERT INTO order_transactions (
        occurred_at, bot_instance_id, transaction_type, 
        details, success
    ) VALUES (
        NOW(), p_bot_instance_id, 'credential_stored',
        jsonb_build_object(
            'credential_id', v_credential_id,
            'credential_type', p_credential_type,
            'account_identifier', p_account_identifier
        ), TRUE
    );
    
    RETURN v_credential_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Retrieve encrypted credentials
CREATE OR REPLACE FUNCTION get_decrypted_credential(
    p_credential_id UUID
) RETURNS JSONB AS $$
DECLARE
    v_encrypted_data BYTEA;
    v_decrypted_text TEXT;
    v_bot_instance_id UUID;
BEGIN
    SELECT encrypted_data, bot_instance_id 
    INTO v_encrypted_data, v_bot_instance_id
    FROM bot_credentials 
    WHERE id = p_credential_id 
    AND is_active = TRUE
    AND (expires_at IS NULL OR expires_at > NOW());
    
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    
    -- Decrypt the data
    v_decrypted_text := pgp_sym_decrypt(
        v_encrypted_data, 
        current_setting('app.encryption_key')
    );
    
    -- Update last used timestamp
    UPDATE bot_credentials 
    SET last_used_at = NOW()
    WHERE id = p_credential_id;
    
    -- Log credential access
    INSERT INTO order_transactions (
        occurred_at, bot_instance_id, transaction_type, 
        details, success
    ) VALUES (
        NOW(), v_bot_instance_id, 'credential_accessed',
        jsonb_build_object('credential_id', p_credential_id), TRUE
    );
    
    RETURN v_decrypted_text::JSONB;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 2. Row-Level Security

```sql
-- Enable RLS for multi-tenant bot isolation
ALTER TABLE bot_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE bot_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE walmart_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_snapshots ENABLE ROW LEVEL SECURITY;

-- Create bot operator role
CREATE ROLE bot_operator;

-- Bot isolation policy
CREATE POLICY bot_isolation ON bot_instances
    FOR ALL TO bot_operator
    USING (id = ANY(current_setting('app.allowed_bot_instances')::uuid[]));

CREATE POLICY session_isolation ON bot_sessions
    FOR ALL TO bot_operator
    USING (bot_instance_id = ANY(current_setting('app.allowed_bot_instances')::uuid[]));
```

## Data Access Patterns

### 1. High-Frequency Operations

```sql
-- Optimized inventory check procedure
CREATE OR REPLACE FUNCTION fast_inventory_check(
    p_product_ids UUID[],
    p_bot_instance_id UUID
) RETURNS TABLE (
    product_id UUID,
    current_price DECIMAL(10,2),
    availability_status VARCHAR(50),
    last_updated TIMESTAMPTZ,
    price_changed BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    WITH latest_snapshots AS (
        SELECT DISTINCT ON (s.product_id)
            s.product_id,
            s.current_price,
            s.availability_status,
            s.recorded_at as last_updated
        FROM inventory_snapshots s
        WHERE s.product_id = ANY(p_product_ids)
        AND s.bot_instance_id = p_bot_instance_id
        ORDER BY s.product_id, s.recorded_at DESC
    ),
    previous_prices AS (
        SELECT DISTINCT ON (s.product_id)
            s.product_id,
            s.current_price as previous_price
        FROM inventory_snapshots s
        WHERE s.product_id = ANY(p_product_ids)
        AND s.bot_instance_id = p_bot_instance_id
        AND s.recorded_at < NOW() - INTERVAL '1 hour'
        ORDER BY s.product_id, s.recorded_at DESC
    )
    SELECT 
        ls.product_id,
        ls.current_price,
        ls.availability_status,
        ls.last_updated,
        COALESCE(ls.current_price != pp.previous_price, FALSE) as price_changed
    FROM latest_snapshots ls
    LEFT JOIN previous_prices pp ON ls.product_id = pp.product_id;
END;
$$ LANGUAGE plpgsql;

-- Bulk session validation
CREATE OR REPLACE FUNCTION validate_bot_sessions(
    p_bot_instance_id UUID
) RETURNS TABLE (
    session_type VARCHAR(50),
    is_valid BOOLEAN,
    expires_at TIMESTAMPTZ,
    needs_refresh BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ON (s.session_type)
        s.session_type,
        s.is_valid AND s.expires_at > NOW() as is_valid,
        s.expires_at,
        s.expires_at < NOW() + INTERVAL '1 hour' as needs_refresh
    FROM bot_sessions s
    WHERE s.bot_instance_id = p_bot_instance_id
    ORDER BY s.session_type, s.created_at DESC;
END;
$$ LANGUAGE plpgsql;
```

### 2. Analytics and Reporting

```sql
-- Performance analytics view
CREATE MATERIALIZED VIEW bot_performance_summary AS
SELECT 
    bi.id as bot_instance_id,
    bi.name as bot_name,
    DATE_TRUNC('hour', bpm.measured_at) as hour,
    AVG(CASE WHEN bpm.metric_name = 'response_time' THEN bpm.metric_value END) as avg_response_time,
    AVG(CASE WHEN bpm.metric_name = 'success_rate' THEN bpm.metric_value END) as avg_success_rate,
    COUNT(CASE WHEN bpm.metric_name = 'request_count' THEN 1 END) as total_requests,
    MAX(bpm.measured_at) as last_updated
FROM bot_instances bi
JOIN bot_performance_metrics bpm ON bi.id = bpm.bot_instance_id
WHERE bpm.measured_at >= NOW() - INTERVAL '7 days'
GROUP BY bi.id, bi.name, DATE_TRUNC('hour', bpm.measured_at);

CREATE UNIQUE INDEX ON bot_performance_summary (bot_instance_id, hour);

-- Inventory monitoring effectiveness
CREATE MATERIALIZED VIEW inventory_monitoring_stats AS
SELECT 
    mp.id as product_id,
    mp.product_name,
    mp.bot_instance_id,
    COUNT(ins.id) as total_checks,
    COUNT(pce.id) as price_changes,
    MIN(ins.current_price) as min_price_seen,
    MAX(ins.current_price) as max_price_seen,
    AVG(ins.current_price) as avg_price,
    MAX(ins.recorded_at) as last_checked
FROM monitored_products mp
LEFT JOIN inventory_snapshots ins ON mp.id = ins.product_id
LEFT JOIN price_change_events pce ON mp.id = pce.product_id
WHERE ins.recorded_at >= NOW() - INTERVAL '30 days'
GROUP BY mp.id, mp.product_name, mp.bot_instance_id;

CREATE UNIQUE INDEX ON inventory_monitoring_stats (product_id);
```

## Implementation Recommendations

### 1. Database Connection Management

```python
# Connection pooling configuration
DATABASE_CONFIG = {
    'host': 'localhost',
    'port': 5432,
    'database': 'walmart_bot',
    'user': 'bot_operator',
    'password': '***',
    'pool_size': 20,
    'max_overflow': 30,
    'pool_timeout': 30,
    'pool_recycle': 3600,
    'connect_args': {
        'sslmode': 'require',
        'application_name': 'walmart_bot'
    }
}

# Redis configuration
REDIS_CONFIG = {
    'host': 'localhost',
    'port': 6379,
    'db': 0,
    'password': '***',
    'decode_responses': True,
    'health_check_interval': 30,
    'socket_connect_timeout': 5,
    'socket_timeout': 5,
    'retry_on_timeout': True,
    'max_connections': 50
}
```

### 2. Monitoring and Alerting

```sql
-- Critical monitoring queries
CREATE VIEW critical_bot_metrics AS
SELECT 
    'bot_health' as metric_type,
    bi.name as bot_name,
    CASE 
        WHEN bi.last_heartbeat > NOW() - INTERVAL '5 minutes' THEN 'healthy'
        WHEN bi.last_heartbeat > NOW() - INTERVAL '30 minutes' THEN 'warning'
        ELSE 'critical'
    END as status,
    bi.last_heartbeat
FROM bot_instances bi
WHERE bi.status = 'running'
UNION ALL
SELECT 
    'cache_performance',
    'redis_hit_rate',
    CASE 
        WHEN (redis_hits::float / NULLIF(redis_requests::float, 0)) > 0.9 THEN 'healthy'
        WHEN (redis_hits::float / NULLIF(redis_requests::float, 0)) > 0.7 THEN 'warning'
        ELSE 'critical'
    END,
    NOW()
FROM (
    SELECT 
        sum(CASE WHEN metric_name = 'cache_hit' THEN metric_value ELSE 0 END) as redis_hits,
        sum(CASE WHEN metric_name = 'cache_request' THEN metric_value ELSE 0 END) as redis_requests
    FROM bot_performance_metrics 
    WHERE measured_at >= NOW() - INTERVAL '1 hour'
) cache_stats;
```

This comprehensive database design provides a robust foundation for the Walmart bot operations with optimal performance, security, and scalability considerations. The hybrid PostgreSQL + Redis architecture ensures both data durability and high-performance access patterns required for successful bot operations.