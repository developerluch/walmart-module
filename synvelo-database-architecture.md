# Synvelo Dual-Site SaaS Database Architecture

## 1. Database Technology Recommendation

**Primary Database: PostgreSQL 15+**

**Rationale:**
- **ACID Compliance**: Critical for financial transactions and inventory accuracy
- **JSON Support**: Native JSONB for flexible metadata and configuration storage
- **Partitioning**: Built-in table partitioning for time-series data
- **Multi-tenancy**: Row-level security (RLS) for secure tenant isolation
- **Performance**: Advanced indexing (GiST, GIN) for complex queries
- **Extensibility**: PostGIS for geospatial tracking, pg_cron for scheduled tasks
- **Compliance**: Mature ecosystem for audit logging and data governance

**Secondary Database: Redis**
- Session management and caching
- Real-time tracking data aggregation
- Rate limiting and API throttling

**Time-Series Database: TimescaleDB (PostgreSQL Extension)**
- Tracking events and metrics
- SLA monitoring data
- Performance analytics

## 2. Multi-Tenant Architecture Strategy

**Approach: Hybrid Row-Level Security + Schema Separation**

1. **Shared Tables with RLS**: Core entities (users, organizations, orders)
2. **Schema Separation**: Per-tenant schemas for large data volumes
3. **Tenant Isolation**: Automatic tenant_id filtering at application level

```sql
-- Enable RLS on all multi-tenant tables
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- Create tenant isolation policy
CREATE POLICY tenant_isolation ON orders
  FOR ALL TO application_user
  USING (tenant_id = current_setting('app.current_tenant')::uuid);
```

## 3. Complete Database Schema

### 3.1 Core Authentication & Organization Schema

```sql
-- Organizations (3PL Companies and Consumer Groups)
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    type organization_type NOT NULL, -- '3pl_operator', 'consumer_group', 'enterprise'
    slug VARCHAR(100) UNIQUE NOT NULL,
    settings JSONB DEFAULT '{}',
    subscription_id UUID,
    status organization_status DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- Custom types
CREATE TYPE organization_type AS ENUM ('3pl_operator', 'consumer_group', 'enterprise');
CREATE TYPE organization_status AS ENUM ('active', 'suspended', 'pending', 'cancelled');
CREATE TYPE user_role AS ENUM ('super_admin', 'org_admin', 'operator', 'consumer', 'viewer');
CREATE TYPE user_status AS ENUM ('active', 'inactive', 'pending_verification', 'suspended');

-- Users with multi-role support
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(320) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    phone VARCHAR(20),
    avatar_url TEXT,
    preferences JSONB DEFAULT '{}',
    status user_status DEFAULT 'pending_verification',
    email_verified_at TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- User-Organization relationships with roles
CREATE TABLE user_organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    role user_role NOT NULL,
    permissions JSONB DEFAULT '{}',
    is_primary BOOLEAN DEFAULT FALSE,
    status VARCHAR(20) DEFAULT 'active',
    invited_by UUID REFERENCES users(id),
    invited_at TIMESTAMPTZ,
    accepted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, organization_id)
);

-- Authentication sessions
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL,
    device_info JSONB,
    ip_address INET,
    expires_at TIMESTAMPTZ NOT NULL,
    last_activity_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 3.2 Core Business Schema

```sql
-- Custom business types
CREATE TYPE order_status AS ENUM (
    'draft', 'submitted', 'confirmed', 'processing', 
    'picked', 'packed', 'shipped', 'delivered', 
    'cancelled', 'returned', 'exception'
);

CREATE TYPE shipment_status AS ENUM (
    'created', 'picked_up', 'in_transit', 'out_for_delivery',
    'delivered', 'failed_delivery', 'returned', 'exception'
);

CREATE TYPE inventory_movement_type AS ENUM (
    'inbound', 'outbound', 'adjustment', 'transfer', 'damage', 'return'
);

-- Warehouses
CREATE TABLE warehouses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    code VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    address JSONB NOT NULL, -- Full address object
    coordinates POINT, -- PostGIS for geospatial queries
    timezone VARCHAR(50) DEFAULT 'UTC',
    operating_hours JSONB, -- Flexible schedule definition
    capacity_limits JSONB, -- Various capacity metrics
    settings JSONB DEFAULT '{}',
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(organization_id, code)
);

-- Products catalog
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    sku VARCHAR(100) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    category VARCHAR(100),
    attributes JSONB DEFAULT '{}', -- Flexible product attributes
    dimensions JSONB, -- length, width, height, weight
    images JSONB DEFAULT '[]',
    hazmat_info JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(organization_id, sku)
);

-- Inventory tracking
CREATE TABLE inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    location VARCHAR(50), -- Specific warehouse location
    quantity_available INTEGER NOT NULL DEFAULT 0,
    quantity_reserved INTEGER NOT NULL DEFAULT 0,
    quantity_damaged INTEGER NOT NULL DEFAULT 0,
    last_counted_at TIMESTAMPTZ,
    last_movement_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(warehouse_id, product_id, location),
    CONSTRAINT positive_quantities CHECK (
        quantity_available >= 0 AND 
        quantity_reserved >= 0 AND 
        quantity_damaged >= 0
    )
);

-- Inventory movement history
CREATE TABLE inventory_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inventory_id UUID NOT NULL REFERENCES inventory(id) ON DELETE CASCADE,
    type inventory_movement_type NOT NULL,
    quantity_change INTEGER NOT NULL,
    reference_type VARCHAR(50), -- 'order', 'adjustment', 'transfer', etc.
    reference_id UUID,
    reason VARCHAR(255),
    performed_by UUID REFERENCES users(id),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Orders
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    order_number VARCHAR(100) NOT NULL,
    customer_info JSONB NOT NULL, -- Flexible customer data
    shipping_address JSONB NOT NULL,
    billing_address JSONB,
    status order_status DEFAULT 'draft',
    priority INTEGER DEFAULT 0,
    requested_ship_date DATE,
    promised_delivery_date DATE,
    special_instructions TEXT,
    metadata JSONB DEFAULT '{}',
    created_by UUID REFERENCES users(id),
    assigned_to UUID REFERENCES users(id),
    total_value DECIMAL(12,2),
    currency VARCHAR(3) DEFAULT 'USD',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(organization_id, order_number)
);

-- Order items
CREATE TABLE order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price DECIMAL(10,2),
    total_price DECIMAL(12,2),
    special_requirements JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Shipments
CREATE TABLE shipments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    shipment_number VARCHAR(100) NOT NULL,
    carrier VARCHAR(100),
    service_level VARCHAR(100),
    tracking_number VARCHAR(255),
    status shipment_status DEFAULT 'created',
    estimated_delivery_date TIMESTAMPTZ,
    actual_delivery_date TIMESTAMPTZ,
    shipping_cost DECIMAL(10,2),
    weight DECIMAL(8,2),
    dimensions JSONB,
    pickup_scheduled_at TIMESTAMPTZ,
    pickup_actual_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(order_id, shipment_number)
);
```

### 3.3 Tracking & Events Schema (Time-Series)

```sql
-- Tracking events (TimescaleDB hypertable)
CREATE TABLE tracking_events (
    id UUID DEFAULT gen_random_uuid(),
    shipment_id UUID NOT NULL REFERENCES shipments(id) ON DELETE CASCADE,
    event_time TIMESTAMPTZ NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    location JSONB, -- Structured location data
    coordinates POINT,
    description TEXT,
    carrier_event_id VARCHAR(255),
    raw_data JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (event_time, id) -- TimescaleDB requires time column in primary key
);

-- Convert to hypertable for time-series optimization
SELECT create_hypertable('tracking_events', 'event_time', chunk_time_interval => INTERVAL '7 days');

-- Order status history
CREATE TABLE order_status_history (
    id UUID DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    status order_status NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL,
    changed_by UUID REFERENCES users(id),
    reason VARCHAR(255),
    metadata JSONB DEFAULT '{}',
    PRIMARY KEY (changed_at, id)
);

SELECT create_hypertable('order_status_history', 'changed_at', chunk_time_interval => INTERVAL '7 days');
```

### 3.4 SLA & Automation Schema

```sql
-- SLA definitions
CREATE TABLE sla_definitions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    metrics JSONB NOT NULL, -- Flexible SLA metrics definition
    thresholds JSONB NOT NULL, -- Warning and breach thresholds
    applies_to JSONB NOT NULL, -- Conditions for when SLA applies
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- SLA performance tracking
CREATE TABLE sla_measurements (
    id UUID DEFAULT gen_random_uuid(),
    sla_definition_id UUID NOT NULL REFERENCES sla_definitions(id) ON DELETE CASCADE,
    measured_at TIMESTAMPTZ NOT NULL,
    metric_name VARCHAR(100) NOT NULL,
    value DECIMAL(15,4) NOT NULL,
    threshold_warning DECIMAL(15,4),
    threshold_breach DECIMAL(15,4),
    status VARCHAR(20) NOT NULL, -- 'ok', 'warning', 'breach'
    reference_type VARCHAR(50), -- 'order', 'shipment', 'warehouse'
    reference_id UUID,
    metadata JSONB DEFAULT '{}',
    PRIMARY KEY (measured_at, id)
);

SELECT create_hypertable('sla_measurements', 'measured_at', chunk_time_interval => INTERVAL '1 day');

-- Automation rules
CREATE TABLE automation_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    triggers JSONB NOT NULL, -- Trigger conditions
    actions JSONB NOT NULL, -- Actions to execute
    priority INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    execution_count INTEGER DEFAULT 0,
    last_executed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Automation execution log
CREATE TABLE automation_executions (
    id UUID DEFAULT gen_random_uuid(),
    rule_id UUID NOT NULL REFERENCES automation_rules(id) ON DELETE CASCADE,
    executed_at TIMESTAMPTZ NOT NULL,
    trigger_data JSONB,
    actions_taken JSONB,
    status VARCHAR(20) NOT NULL, -- 'success', 'partial', 'failed'
    error_message TEXT,
    execution_time_ms INTEGER,
    PRIMARY KEY (executed_at, id)
);

SELECT create_hypertable('automation_executions', 'executed_at', chunk_time_interval => INTERVAL '7 days');
```

### 3.5 Billing & Subscription Schema

```sql
-- Subscription plans
CREATE TABLE subscription_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    slug VARCHAR(50) UNIQUE NOT NULL,
    description TEXT,
    tier INTEGER NOT NULL, -- 1=Starter, 2=Growth, 3=Pro, 4=Enterprise
    pricing JSONB NOT NULL, -- Flexible pricing structure
    features JSONB NOT NULL, -- Feature entitlements
    limits JSONB NOT NULL, -- Usage limits
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Organization subscriptions
CREATE TABLE subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    plan_id UUID NOT NULL REFERENCES subscription_plans(id),
    status VARCHAR(20) DEFAULT 'active', -- 'active', 'cancelled', 'suspended', 'past_due'
    billing_cycle VARCHAR(20) NOT NULL, -- 'monthly', 'yearly'
    current_period_start DATE NOT NULL,
    current_period_end DATE NOT NULL,
    trial_end DATE,
    cancelled_at TIMESTAMPTZ,
    cancel_at_period_end BOOLEAN DEFAULT FALSE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Payment methods
CREATE TABLE payment_methods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    type VARCHAR(20) NOT NULL, -- 'card', 'bank_account', 'wire'
    provider VARCHAR(50) NOT NULL, -- 'stripe', 'paypal', etc.
    provider_id VARCHAR(255) NOT NULL, -- External payment method ID
    last_four VARCHAR(4),
    brand VARCHAR(50),
    expires_at DATE,
    is_default BOOLEAN DEFAULT FALSE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Invoices
CREATE TABLE invoices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    subscription_id UUID REFERENCES subscriptions(id),
    invoice_number VARCHAR(50) NOT NULL UNIQUE,
    status VARCHAR(20) DEFAULT 'draft', -- 'draft', 'open', 'paid', 'void', 'uncollectible'
    subtotal DECIMAL(12,2) NOT NULL,
    tax_amount DECIMAL(12,2) DEFAULT 0,
    total DECIMAL(12,2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'USD',
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    due_date DATE,
    paid_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Invoice line items
CREATE TABLE invoice_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    description VARCHAR(255) NOT NULL,
    quantity DECIMAL(10,2) NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    total DECIMAL(12,2) NOT NULL,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Usage tracking for billing
CREATE TABLE usage_events (
    id UUID DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    event_time TIMESTAMPTZ NOT NULL,
    event_type VARCHAR(50) NOT NULL, -- 'api_call', 'order_processed', 'storage_gb_hour'
    quantity DECIMAL(15,4) NOT NULL,
    metadata JSONB DEFAULT '{}',
    PRIMARY KEY (event_time, id)
);

SELECT create_hypertable('usage_events', 'event_time', chunk_time_interval => INTERVAL '1 day');
```

### 3.6 Audit & Compliance Schema

```sql
-- Audit log for all significant actions
CREATE TABLE audit_logs (
    id UUID DEFAULT gen_random_uuid(),
    occurred_at TIMESTAMPTZ NOT NULL,
    organization_id UUID REFERENCES organizations(id) ON DELETE SET NULL,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    action VARCHAR(100) NOT NULL,
    resource_type VARCHAR(50) NOT NULL,
    resource_id UUID,
    ip_address INET,
    user_agent TEXT,
    changes JSONB, -- Before/after values
    metadata JSONB DEFAULT '{}',
    PRIMARY KEY (occurred_at, id)
);

SELECT create_hypertable('audit_logs', 'occurred_at', chunk_time_interval => INTERVAL '30 days');

-- Data retention policies
CREATE TABLE data_retention_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name VARCHAR(100) NOT NULL,
    retention_period INTERVAL NOT NULL,
    conditions JSONB DEFAULT '{}', -- Additional retention conditions
    is_active BOOLEAN DEFAULT TRUE,
    last_cleanup_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Compliance tracking
CREATE TABLE compliance_events (
    id UUID DEFAULT gen_random_uuid(),
    occurred_at TIMESTAMPTZ NOT NULL,
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    compliance_type VARCHAR(50) NOT NULL, -- 'gdpr', 'ccpa', 'sox', 'pci'
    event_type VARCHAR(50) NOT NULL, -- 'data_request', 'data_deletion', 'access_grant'
    subject_id VARCHAR(255), -- Data subject identifier
    details JSONB NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (occurred_at, id)
);

SELECT create_hypertable('compliance_events', 'occurred_at', chunk_time_interval => INTERVAL '30 days');
```

## 4. Indexing Strategy for Performance

```sql
-- Primary business indexes
CREATE INDEX CONCURRENTLY idx_orders_org_status_created 
ON orders (organization_id, status, created_at DESC);

CREATE INDEX CONCURRENTLY idx_orders_number_lookup 
ON orders USING hash (order_number);

CREATE INDEX CONCURRENTLY idx_inventory_warehouse_product 
ON inventory (warehouse_id, product_id) 
WHERE quantity_available > 0;

CREATE INDEX CONCURRENTLY idx_shipments_tracking_number 
ON shipments USING hash (tracking_number);

-- Time-series optimized indexes
CREATE INDEX CONCURRENTLY idx_tracking_events_shipment_time 
ON tracking_events (shipment_id, event_time DESC);

CREATE INDEX CONCURRENTLY idx_sla_measurements_def_time 
ON sla_measurements (sla_definition_id, measured_at DESC);

-- Full-text search indexes
CREATE INDEX CONCURRENTLY idx_products_search 
ON products USING gin(to_tsvector('english', name || ' ' || description));

CREATE INDEX CONCURRENTLY idx_orders_customer_search 
ON orders USING gin(to_tsvector('english', customer_info::text));

-- Geospatial indexes
CREATE INDEX CONCURRENTLY idx_warehouses_location 
ON warehouses USING gist(coordinates);

-- JSON indexes for flexible queries
CREATE INDEX CONCURRENTLY idx_organizations_settings 
ON organizations USING gin(settings);

CREATE INDEX CONCURRENTLY idx_users_preferences 
ON users USING gin(preferences);

-- Partial indexes for common queries
CREATE INDEX CONCURRENTLY idx_active_subscriptions 
ON subscriptions (organization_id, current_period_end) 
WHERE status = 'active';

CREATE INDEX CONCURRENTLY idx_unpaid_invoices 
ON invoices (organization_id, due_date) 
WHERE status IN ('open', 'past_due');
```

## 5. Data Partitioning Strategy

### 5.1 Time-Based Partitioning (TimescaleDB)
- **tracking_events**: 7-day chunks, 6-month retention
- **order_status_history**: 7-day chunks, 2-year retention  
- **sla_measurements**: 1-day chunks, 1-year retention
- **audit_logs**: 30-day chunks, 7-year retention
- **usage_events**: 1-day chunks, 2-year retention

### 5.2 Tenant-Based Partitioning
```sql
-- For large tables, partition by organization hash
CREATE TABLE orders_partitioned (LIKE orders INCLUDING ALL)
PARTITION BY HASH (organization_id);

-- Create 16 partitions for load distribution
DO $$ 
BEGIN
  FOR i IN 0..15 LOOP
    EXECUTE format('CREATE TABLE orders_p%s PARTITION OF orders_partitioned 
                   FOR VALUES WITH (modulus 16, remainder %s)', i, i);
  END LOOP;
END $$;
```

## 6. Time-Series Data Handling

### 6.1 Automated Data Rollups
```sql
-- Hourly SLA aggregations
CREATE MATERIALIZED VIEW sla_hourly_stats AS
SELECT 
    sla_definition_id,
    date_trunc('hour', measured_at) as hour,
    metric_name,
    avg(value) as avg_value,
    min(value) as min_value,
    max(value) as max_value,
    count(*) as measurement_count,
    count(*) FILTER (WHERE status = 'breach') as breach_count
FROM sla_measurements
GROUP BY 1, 2, 3;

-- Refresh policy for continuous aggregation
SELECT add_continuous_aggregate_policy('sla_hourly_stats',
    start_offset => INTERVAL '1 day',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');
```

### 6.2 Data Retention Policies
```sql
-- Automatic data retention for time-series tables
SELECT add_retention_policy('tracking_events', INTERVAL '6 months');
SELECT add_retention_policy('sla_measurements', INTERVAL '1 year');
SELECT add_retention_policy('audit_logs', INTERVAL '7 years');
SELECT add_retention_policy('usage_events', INTERVAL '2 years');
```

## 7. Backup and Recovery Strategy

### 7.1 Backup Configuration
```bash
# Continuous WAL archiving
archive_mode = on
archive_command = 'aws s3 cp %p s3://synvelo-db-backups/wal/%f'
wal_level = replica

# Point-in-time recovery setup
max_wal_senders = 5
wal_keep_size = 1GB
```

### 7.2 Backup Schedule
- **Continuous**: WAL archiving to S3
- **Daily**: Full database backup at 2 AM UTC
- **Weekly**: Full backup with verification
- **Monthly**: Long-term archival backup

### 7.3 Recovery Testing
```sql
-- Automated backup verification procedure
CREATE OR REPLACE FUNCTION verify_backup_integrity()
RETURNS TABLE (
    table_name TEXT,
    row_count BIGINT,
    checksum TEXT,
    last_updated TIMESTAMPTZ
) AS $$
BEGIN
    -- Implementation for backup verification
    RETURN QUERY
    SELECT 
        t.table_name::TEXT,
        t.n_tup_ins + t.n_tup_upd - t.n_tup_del as row_count,
        md5(t.table_name) as checksum,
        NOW() as last_updated
    FROM pg_stat_user_tables t;
END;
$$ LANGUAGE plpgsql;
```

## 8. Data Privacy and Compliance

### 8.1 Data Classification
```sql
-- Add data sensitivity labels
ALTER TABLE users ADD COLUMN data_classification VARCHAR(20) DEFAULT 'internal';
ALTER TABLE orders ADD COLUMN contains_pii BOOLEAN DEFAULT true;

-- Create compliance view for data inventory
CREATE VIEW data_inventory AS
SELECT 
    schemaname,
    tablename,
    CASE 
        WHEN tablename IN ('users', 'orders') THEN 'high'
        WHEN tablename LIKE '%_history' THEN 'medium'
        ELSE 'low'
    END as sensitivity_level,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
WHERE schemaname NOT IN ('information_schema', 'pg_catalog');
```

### 8.2 Data Subject Rights (GDPR/CCPA)
```sql
-- Data subject request handling
CREATE OR REPLACE FUNCTION handle_data_subject_request(
    subject_email VARCHAR,
    request_type VARCHAR, -- 'access', 'deletion', 'portability'
    organization_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    result JSONB;
    user_record RECORD;
BEGIN
    -- Find user record
    SELECT * INTO user_record FROM users WHERE email = subject_email;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'Subject not found');
    END IF;
    
    -- Log compliance event
    INSERT INTO compliance_events (
        occurred_at, organization_id, compliance_type, 
        event_type, subject_id, details
    ) VALUES (
        NOW(), organization_id, 'gdpr', 
        request_type, subject_email,
        jsonb_build_object('user_id', user_record.id)
    );
    
    -- Handle based on request type
    CASE request_type
        WHEN 'access' THEN
            result := jsonb_build_object(
                'user_data', to_jsonb(user_record),
                'orders_count', (SELECT count(*) FROM orders o 
                                JOIN user_organizations uo ON o.organization_id = uo.organization_id
                                WHERE uo.user_id = user_record.id)
            );
        WHEN 'deletion' THEN
            -- Implement right to be forgotten
            -- Note: Some data may need to be retained for legal reasons
            UPDATE users SET 
                email = 'deleted_' || id::text || '@synvelo.deleted',
                first_name = 'DELETED',
                last_name = 'USER',
                phone = NULL,
                avatar_url = NULL,
                preferences = '{}',
                deleted_at = NOW()
            WHERE id = user_record.id;
            
            result := jsonb_build_object('status', 'deleted');
        ELSE
            result := jsonb_build_object('error', 'Invalid request type');
    END CASE;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;
```

### 8.3 Encryption at Rest
```sql
-- Enable transparent data encryption
ALTER SYSTEM SET ssl = on;
ALTER SYSTEM SET ssl_cert_file = '/etc/ssl/certs/server.crt';
ALTER SYSTEM SET ssl_key_file = '/etc/ssl/private/server.key';

-- Encrypt sensitive columns
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Add encrypted columns for PII
ALTER TABLE users ADD COLUMN phone_encrypted BYTEA;
ALTER TABLE orders ADD COLUMN customer_info_encrypted BYTEA;
```

## 9. Performance Optimization Recommendations

### 9.1 Connection Pooling
```bash
# PgBouncer configuration
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 25
reserve_pool_size = 5
```

### 9.2 Query Optimization
```sql
-- Materialized views for common aggregations
CREATE MATERIALIZED VIEW organization_metrics AS
SELECT 
    o.id,
    o.name,
    count(ord.id) as total_orders,
    count(ord.id) FILTER (WHERE ord.created_at >= NOW() - INTERVAL '30 days') as orders_last_30_days,
    avg(EXTRACT(EPOCH FROM (ord.updated_at - ord.created_at))/3600) as avg_processing_hours
FROM organizations o
LEFT JOIN orders ord ON o.id = ord.organization_id
GROUP BY o.id, o.name;

-- Refresh daily
CREATE UNIQUE INDEX ON organization_metrics (id);
```

### 9.3 Read Replicas Strategy
- **Primary**: All writes and critical reads
- **Analytics Replica**: Reporting and dashboard queries  
- **API Replica**: High-frequency API reads
- **Backup Replica**: Backup verification and testing

## 10. Monitoring and Alerting

### 10.1 Key Metrics to Monitor
```sql
-- Database health metrics
CREATE VIEW db_health_metrics AS
SELECT 
    'active_connections' as metric,
    count(*) as value
FROM pg_stat_activity 
WHERE state = 'active'
UNION ALL
SELECT 
    'slow_queries',
    count(*)
FROM pg_stat_activity 
WHERE state = 'active' 
AND query_start < NOW() - INTERVAL '5 minutes'
UNION ALL
SELECT 
    'replication_lag',
    EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))
WHERE pg_is_in_recovery();
```

### 10.2 Business Metrics Monitoring
```sql
-- Real-time business metrics
CREATE VIEW business_metrics AS
SELECT 
    'orders_last_hour' as metric,
    count(*) as value
FROM orders 
WHERE created_at >= NOW() - INTERVAL '1 hour'
UNION ALL
SELECT 
    'sla_breaches_today',
    count(*)
FROM sla_measurements 
WHERE measured_at >= CURRENT_DATE 
AND status = 'breach';
```

This comprehensive database architecture provides a solid foundation for the Synvelo dual-site SaaS platform, with careful consideration for scalability, performance, compliance, and multi-tenancy requirements.