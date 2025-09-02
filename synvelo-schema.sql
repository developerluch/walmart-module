-- Synvelo Database Schema
-- PostgreSQL 15+ with TimescaleDB extension
-- Multi-tenant SaaS architecture for 3PL operators and consumers

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "timescaledb";

-- Create custom types
CREATE TYPE organization_type AS ENUM ('3pl_operator', 'consumer_group', 'enterprise');
CREATE TYPE organization_status AS ENUM ('active', 'suspended', 'pending', 'cancelled');
CREATE TYPE user_role AS ENUM ('super_admin', 'org_admin', 'operator', 'consumer', 'viewer');
CREATE TYPE user_status AS ENUM ('active', 'inactive', 'pending_verification', 'suspended');
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

-- =========================================================================
-- AUTHENTICATION & ORGANIZATION SCHEMA
-- =========================================================================

-- Organizations (3PL Companies and Consumer Groups)
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    type organization_type NOT NULL,
    slug VARCHAR(100) UNIQUE NOT NULL,
    settings JSONB DEFAULT '{}',
    subscription_id UUID,
    status organization_status DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- Users with multi-role support
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(320) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    phone VARCHAR(20),
    phone_encrypted BYTEA, -- Encrypted PII
    avatar_url TEXT,
    preferences JSONB DEFAULT '{}',
    status user_status DEFAULT 'pending_verification',
    email_verified_at TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    data_classification VARCHAR(20) DEFAULT 'internal',
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

-- =========================================================================
-- CORE BUSINESS SCHEMA
-- =========================================================================

-- Warehouses
CREATE TABLE warehouses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    code VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    address JSONB NOT NULL,
    coordinates POINT, -- PostGIS for geospatial queries
    timezone VARCHAR(50) DEFAULT 'UTC',
    operating_hours JSONB,
    capacity_limits JSONB,
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
    attributes JSONB DEFAULT '{}',
    dimensions JSONB,
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
    location VARCHAR(50),
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
    reference_type VARCHAR(50),
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
    customer_info JSONB NOT NULL,
    customer_info_encrypted BYTEA, -- Encrypted PII
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
    contains_pii BOOLEAN DEFAULT true,
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

-- =========================================================================
-- TIME-SERIES TRACKING & EVENTS
-- =========================================================================

-- Tracking events (TimescaleDB hypertable)
CREATE TABLE tracking_events (
    id UUID DEFAULT gen_random_uuid(),
    shipment_id UUID NOT NULL REFERENCES shipments(id) ON DELETE CASCADE,
    event_time TIMESTAMPTZ NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    location JSONB,
    coordinates POINT,
    description TEXT,
    carrier_event_id VARCHAR(255),
    raw_data JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (event_time, id)
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

-- =========================================================================
-- SLA & AUTOMATION SCHEMA
-- =========================================================================

-- SLA definitions
CREATE TABLE sla_definitions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    metrics JSONB NOT NULL,
    thresholds JSONB NOT NULL,
    applies_to JSONB NOT NULL,
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
    status VARCHAR(20) NOT NULL,
    reference_type VARCHAR(50),
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
    triggers JSONB NOT NULL,
    actions JSONB NOT NULL,
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
    status VARCHAR(20) NOT NULL,
    error_message TEXT,
    execution_time_ms INTEGER,
    PRIMARY KEY (executed_at, id)
);

SELECT create_hypertable('automation_executions', 'executed_at', chunk_time_interval => INTERVAL '7 days');

-- =========================================================================
-- BILLING & SUBSCRIPTION SCHEMA
-- =========================================================================

-- Subscription plans
CREATE TABLE subscription_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    slug VARCHAR(50) UNIQUE NOT NULL,
    description TEXT,
    tier INTEGER NOT NULL,
    pricing JSONB NOT NULL,
    features JSONB NOT NULL,
    limits JSONB NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Organization subscriptions
CREATE TABLE subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    plan_id UUID NOT NULL REFERENCES subscription_plans(id),
    status VARCHAR(20) DEFAULT 'active',
    billing_cycle VARCHAR(20) NOT NULL,
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
    type VARCHAR(20) NOT NULL,
    provider VARCHAR(50) NOT NULL,
    provider_id VARCHAR(255) NOT NULL,
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
    status VARCHAR(20) DEFAULT 'draft',
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
    event_type VARCHAR(50) NOT NULL,
    quantity DECIMAL(15,4) NOT NULL,
    metadata JSONB DEFAULT '{}',
    PRIMARY KEY (event_time, id)
);

SELECT create_hypertable('usage_events', 'event_time', chunk_time_interval => INTERVAL '1 day');

-- =========================================================================
-- AUDIT & COMPLIANCE SCHEMA
-- =========================================================================

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
    changes JSONB,
    metadata JSONB DEFAULT '{}',
    PRIMARY KEY (occurred_at, id)
);

SELECT create_hypertable('audit_logs', 'occurred_at', chunk_time_interval => INTERVAL '30 days');

-- Data retention policies
CREATE TABLE data_retention_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name VARCHAR(100) NOT NULL,
    retention_period INTERVAL NOT NULL,
    conditions JSONB DEFAULT '{}',
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
    compliance_type VARCHAR(50) NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    subject_id VARCHAR(255),
    details JSONB NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (occurred_at, id)
);

SELECT create_hypertable('compliance_events', 'occurred_at', chunk_time_interval => INTERVAL '30 days');

-- =========================================================================
-- ROW LEVEL SECURITY POLICIES
-- =========================================================================

-- Enable RLS on multi-tenant tables
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE sla_measurements ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_events ENABLE ROW LEVEL SECURITY;

-- Create application role for RLS
CREATE ROLE application_user;

-- Tenant isolation policies
CREATE POLICY tenant_isolation_orders ON orders
    FOR ALL TO application_user
    USING (organization_id = current_setting('app.current_tenant')::uuid);

CREATE POLICY tenant_isolation_shipments ON shipments
    FOR ALL TO application_user
    USING (
        order_id IN (
            SELECT id FROM orders 
            WHERE organization_id = current_setting('app.current_tenant')::uuid
        )
    );

CREATE POLICY tenant_isolation_inventory ON inventory
    FOR ALL TO application_user
    USING (
        warehouse_id IN (
            SELECT id FROM warehouses 
            WHERE organization_id = current_setting('app.current_tenant')::uuid
        )
    );

-- =========================================================================
-- PERFORMANCE INDEXES
-- =========================================================================

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

-- User session management indexes
CREATE INDEX CONCURRENTLY idx_user_sessions_token 
ON user_sessions USING hash (token_hash);

CREATE INDEX CONCURRENTLY idx_user_sessions_expiry 
ON user_sessions (expires_at) 
WHERE expires_at > NOW();