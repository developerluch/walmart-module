-- Synvelo Database Migration Strategy
-- Safe migration procedures and rollback plans

-- =========================================================================
-- MIGRATION FRAMEWORK
-- =========================================================================

-- Migration tracking table
CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(20) PRIMARY KEY,
    description TEXT NOT NULL,
    applied_at TIMESTAMPTZ DEFAULT NOW(),
    rollback_sql TEXT,
    checksum VARCHAR(64)
);

-- Function to apply migration with rollback support
CREATE OR REPLACE FUNCTION apply_migration(
    p_version VARCHAR(20),
    p_description TEXT,
    p_migration_sql TEXT,
    p_rollback_sql TEXT DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_checksum VARCHAR(64);
    v_existing_version VARCHAR(20);
BEGIN
    -- Check if migration already applied
    SELECT version INTO v_existing_version 
    FROM schema_migrations 
    WHERE version = p_version;
    
    IF FOUND THEN
        RAISE NOTICE 'Migration % already applied', p_version;
        RETURN FALSE;
    END IF;
    
    -- Calculate checksum
    v_checksum := encode(digest(p_migration_sql, 'sha256'), 'hex');
    
    -- Begin migration transaction
    BEGIN
        -- Execute migration SQL
        EXECUTE p_migration_sql;
        
        -- Record migration
        INSERT INTO schema_migrations (version, description, rollback_sql, checksum)
        VALUES (p_version, p_description, p_rollback_sql, v_checksum);
        
        RAISE NOTICE 'Successfully applied migration %: %', p_version, p_description;
        RETURN TRUE;
        
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Migration % failed: %', p_version, SQLERRM;
        RAISE;
    END;
END;
$$ LANGUAGE plpgsql;

-- Function to rollback migration
CREATE OR REPLACE FUNCTION rollback_migration(p_version VARCHAR(20))
RETURNS BOOLEAN AS $$
DECLARE
    v_rollback_sql TEXT;
    v_description TEXT;
BEGIN
    -- Get rollback SQL
    SELECT rollback_sql, description 
    INTO v_rollback_sql, v_description
    FROM schema_migrations 
    WHERE version = p_version;
    
    IF NOT FOUND THEN
        RAISE NOTICE 'Migration % not found', p_version;
        RETURN FALSE;
    END IF;
    
    IF v_rollback_sql IS NULL THEN
        RAISE NOTICE 'No rollback SQL defined for migration %', p_version;
        RETURN FALSE;
    END IF;
    
    -- Execute rollback
    BEGIN
        EXECUTE v_rollback_sql;
        DELETE FROM schema_migrations WHERE version = p_version;
        
        RAISE NOTICE 'Successfully rolled back migration %: %', p_version, v_description;
        RETURN TRUE;
        
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Rollback of % failed: %', p_version, SQLERRM;
        RAISE;
    END;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- SAMPLE MIGRATIONS
-- =========================================================================

-- Migration 001: Initial Schema
SELECT apply_migration(
    '001_initial_schema',
    'Create initial database schema with all base tables',
    '
    -- This would contain the entire schema creation
    -- For brevity, assuming schema is already created
    SELECT 1;
    ',
    '
    -- Rollback would drop all tables
    DROP TABLE IF EXISTS compliance_events CASCADE;
    DROP TABLE IF EXISTS audit_logs CASCADE;
    DROP TABLE IF EXISTS usage_events CASCADE;
    DROP TABLE IF EXISTS invoice_items CASCADE;
    DROP TABLE IF EXISTS invoices CASCADE;
    DROP TABLE IF EXISTS payment_methods CASCADE;
    DROP TABLE IF EXISTS subscriptions CASCADE;
    DROP TABLE IF EXISTS subscription_plans CASCADE;
    DROP TABLE IF EXISTS automation_executions CASCADE;
    DROP TABLE IF EXISTS automation_rules CASCADE;
    DROP TABLE IF EXISTS sla_measurements CASCADE;
    DROP TABLE IF EXISTS sla_definitions CASCADE;
    DROP TABLE IF EXISTS order_status_history CASCADE;
    DROP TABLE IF EXISTS tracking_events CASCADE;
    DROP TABLE IF EXISTS shipments CASCADE;
    DROP TABLE IF EXISTS order_items CASCADE;
    DROP TABLE IF EXISTS orders CASCADE;
    DROP TABLE IF EXISTS inventory_movements CASCADE;
    DROP TABLE IF EXISTS inventory CASCADE;
    DROP TABLE IF EXISTS products CASCADE;
    DROP TABLE IF EXISTS warehouses CASCADE;
    DROP TABLE IF EXISTS user_sessions CASCADE;
    DROP TABLE IF EXISTS user_organizations CASCADE;
    DROP TABLE IF EXISTS users CASCADE;
    DROP TABLE IF EXISTS organizations CASCADE;
    '
);

-- Migration 002: Add encryption columns
SELECT apply_migration(
    '002_add_encryption',
    'Add encrypted columns for PII data',
    '
    ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_encrypted BYTEA;
    ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_info_encrypted BYTEA;
    ',
    '
    ALTER TABLE users DROP COLUMN IF EXISTS phone_encrypted;
    ALTER TABLE orders DROP COLUMN IF EXISTS customer_info_encrypted;
    '
);

-- Migration 003: Add performance indexes
SELECT apply_migration(
    '003_performance_indexes',
    'Add critical performance indexes',
    '
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_org_status_created 
    ON orders (organization_id, status, created_at DESC);
    
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_inventory_warehouse_product 
    ON inventory (warehouse_id, product_id) 
    WHERE quantity_available > 0;
    
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tracking_events_shipment_time 
    ON tracking_events (shipment_id, event_time DESC);
    ',
    '
    DROP INDEX IF EXISTS idx_orders_org_status_created;
    DROP INDEX IF EXISTS idx_inventory_warehouse_product;  
    DROP INDEX IF EXISTS idx_tracking_events_shipment_time;
    '
);

-- Migration 004: Setup TimescaleDB hypertables
SELECT apply_migration(
    '004_timescaledb_setup',
    'Convert time-series tables to hypertables',
    '
    SELECT create_hypertable(''tracking_events'', ''event_time'', 
                            chunk_time_interval => INTERVAL ''7 days'',
                            if_not_exists => TRUE);
    
    SELECT create_hypertable(''order_status_history'', ''changed_at'', 
                            chunk_time_interval => INTERVAL ''7 days'',
                            if_not_exists => TRUE);
    
    SELECT create_hypertable(''sla_measurements'', ''measured_at'', 
                            chunk_time_interval => INTERVAL ''1 day'',
                            if_not_exists => TRUE);
    
    SELECT create_hypertable(''usage_events'', ''event_time'', 
                            chunk_time_interval => INTERVAL ''1 day'',
                            if_not_exists => TRUE);
    
    SELECT create_hypertable(''audit_logs'', ''occurred_at'', 
                            chunk_time_interval => INTERVAL ''30 days'',
                            if_not_exists => TRUE);
    
    SELECT create_hypertable(''compliance_events'', ''occurred_at'', 
                            chunk_time_interval => INTERVAL ''30 days'',
                            if_not_exists => TRUE);
    ',
    '
    -- Note: Converting back from hypertable is complex and may require data migration
    -- This rollback assumes we can recreate the tables from backup
    SELECT ''Rollback requires manual intervention - restore from backup before this migration'';
    '
);

-- Migration 005: Add Row Level Security
SELECT apply_migration(
    '005_row_level_security',
    'Enable Row Level Security for multi-tenancy',
    '
    -- Enable RLS on multi-tenant tables
    ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
    ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
    ALTER TABLE shipments ENABLE ROW LEVEL SECURITY;
    ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;
    ALTER TABLE sla_measurements ENABLE ROW LEVEL SECURITY;
    ALTER TABLE usage_events ENABLE ROW LEVEL SECURITY;
    
    -- Create application role
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ''application_user'') THEN
            CREATE ROLE application_user;
        END IF;
    END
    $$;
    
    -- Create tenant isolation policies
    CREATE POLICY tenant_isolation_orders ON orders
        FOR ALL TO application_user
        USING (organization_id = current_setting(''app.current_tenant'')::uuid);
        
    CREATE POLICY tenant_isolation_shipments ON shipments
        FOR ALL TO application_user
        USING (
            order_id IN (
                SELECT id FROM orders 
                WHERE organization_id = current_setting(''app.current_tenant'')::uuid
            )
        );
    ',
    '
    DROP POLICY IF EXISTS tenant_isolation_orders ON orders;
    DROP POLICY IF EXISTS tenant_isolation_shipments ON shipments;
    
    ALTER TABLE organizations DISABLE ROW LEVEL SECURITY;
    ALTER TABLE orders DISABLE ROW LEVEL SECURITY;
    ALTER TABLE shipments DISABLE ROW LEVEL SECURITY;
    ALTER TABLE inventory DISABLE ROW LEVEL SECURITY;
    ALTER TABLE sla_measurements DISABLE ROW LEVEL SECURITY;
    ALTER TABLE usage_events DISABLE ROW LEVEL SECURITY;
    
    DROP ROLE IF EXISTS application_user;
    '
);

-- =========================================================================
-- ZERO-DOWNTIME MIGRATION STRATEGIES
-- =========================================================================

-- Strategy for adding columns with default values
CREATE OR REPLACE FUNCTION safe_add_column(
    p_table_name TEXT,
    p_column_name TEXT,
    p_column_type TEXT,
    p_default_value TEXT DEFAULT NULL,
    p_not_null BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN AS $$
DECLARE
    v_sql TEXT;
BEGIN
    -- Step 1: Add column as nullable
    v_sql := format('ALTER TABLE %I ADD COLUMN %I %s', 
                    p_table_name, p_column_name, p_column_type);
    
    IF p_default_value IS NOT NULL THEN
        v_sql := v_sql || format(' DEFAULT %s', p_default_value);
    END IF;
    
    EXECUTE v_sql;
    RAISE NOTICE 'Added column %I.%I', p_table_name, p_column_name;
    
    -- Step 2: If we need NOT NULL, update existing rows first
    IF p_not_null AND p_default_value IS NOT NULL THEN
        v_sql := format('UPDATE %I SET %I = %s WHERE %I IS NULL', 
                        p_table_name, p_column_name, p_default_value, p_column_name);
        EXECUTE v_sql;
        
        -- Step 3: Add NOT NULL constraint
        v_sql := format('ALTER TABLE %I ALTER COLUMN %I SET NOT NULL', 
                        p_table_name, p_column_name);
        EXECUTE v_sql;
        RAISE NOTICE 'Set column %I.%I to NOT NULL', p_table_name, p_column_name;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Strategy for dropping columns safely
CREATE OR REPLACE FUNCTION safe_drop_column(
    p_table_name TEXT,
    p_column_name TEXT,
    p_create_backup BOOLEAN DEFAULT TRUE
) RETURNS BOOLEAN AS $$
DECLARE
    v_backup_table TEXT;
    v_sql TEXT;
BEGIN
    IF p_create_backup THEN
        -- Create backup table with just the column being dropped
        v_backup_table := p_table_name || '_' || p_column_name || '_backup_' || 
                         to_char(NOW(), 'YYYYMMDD_HH24MI');
        
        v_sql := format('CREATE TABLE %I AS SELECT id, %I FROM %I', 
                        v_backup_table, p_column_name, p_table_name);
        EXECUTE v_sql;
        RAISE NOTICE 'Created backup table: %', v_backup_table;
    END IF;
    
    -- Drop the column
    v_sql := format('ALTER TABLE %I DROP COLUMN %I', p_table_name, p_column_name);
    EXECUTE v_sql;
    RAISE NOTICE 'Dropped column %I.%I', p_table_name, p_column_name;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Strategy for renaming columns
CREATE OR REPLACE FUNCTION safe_rename_column(
    p_table_name TEXT,
    p_old_column TEXT,
    p_new_column TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    v_sql TEXT;
BEGIN
    -- Use a transaction to ensure atomicity
    BEGIN
        v_sql := format('ALTER TABLE %I RENAME COLUMN %I TO %I', 
                        p_table_name, p_old_column, p_new_column);
        EXECUTE v_sql;
        RAISE NOTICE 'Renamed column %I.%I to %I', p_table_name, p_old_column, p_new_column;
        RETURN TRUE;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Failed to rename column: %', SQLERRM;
        RETURN FALSE;
    END;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- MIGRATION VALIDATION
-- =========================================================================

-- Function to validate migration state
CREATE OR REPLACE FUNCTION validate_migration_state()
RETURNS TABLE (
    validation_name TEXT,
    status TEXT,
    message TEXT,
    details JSONB
) AS $$
BEGIN
    -- Check required extensions
    RETURN QUERY
    SELECT 
        'extensions_installed'::TEXT,
        CASE WHEN count(*) = 4 THEN 'passed' ELSE 'failed' END::TEXT,
        format('Required extensions: %s/4 installed', count(*))::TEXT,
        jsonb_agg(extname) as details
    FROM pg_extension 
    WHERE extname IN ('uuid-ossp', 'pgcrypto', 'postgis', 'timescaledb');
    
    -- Check TimescaleDB hypertables
    RETURN QUERY
    SELECT 
        'hypertables_configured'::TEXT,
        CASE WHEN count(*) >= 6 THEN 'passed' ELSE 'warning' END::TEXT,
        format('TimescaleDB hypertables: %s configured', count(*))::TEXT,
        jsonb_agg(hypertable_name) as details
    FROM timescaledb_information.hypertables
    WHERE hypertable_schema = 'public';
    
    -- Check RLS policies
    RETURN QUERY
    SELECT 
        'rls_policies'::TEXT,
        CASE WHEN count(*) >= 2 THEN 'passed' ELSE 'warning' END::TEXT,
        format('RLS policies: %s configured', count(*))::TEXT,
        jsonb_agg(policyname) as details
    FROM pg_policies 
    WHERE schemaname = 'public';
    
    -- Check indexes
    RETURN QUERY
    SELECT 
        'performance_indexes'::TEXT,
        CASE WHEN count(*) >= 10 THEN 'passed' ELSE 'warning' END::TEXT,
        format('Performance indexes: %s created', count(*))::TEXT,
        jsonb_agg(indexname) as details
    FROM pg_indexes 
    WHERE schemaname = 'public' 
    AND indexname LIKE 'idx_%';
    
    -- Check foreign key constraints
    RETURN QUERY
    SELECT 
        'foreign_keys'::TEXT,
        CASE WHEN count(*) >= 20 THEN 'passed' ELSE 'failed' END::TEXT,
        format('Foreign key constraints: %s', count(*))::TEXT,
        jsonb_agg(constraint_name) as details
    FROM information_schema.table_constraints 
    WHERE constraint_schema = 'public' 
    AND constraint_type = 'FOREIGN KEY';
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- SAMPLE DATA INSERTION (FOR TESTING)
-- =========================================================================

-- Function to create sample data
CREATE OR REPLACE FUNCTION create_sample_data()
RETURNS BOOLEAN AS $$
DECLARE
    v_org_id UUID;
    v_user_id UUID;
    v_warehouse_id UUID;
    v_product_id UUID;
    v_plan_id UUID;
    v_subscription_id UUID;
BEGIN
    -- Create sample subscription plan
    INSERT INTO subscription_plans (id, name, slug, tier, pricing, features, limits)
    VALUES (
        gen_random_uuid(),
        'Growth Plan',
        'growth',
        2,
        '{"monthly": 299, "yearly": 2990}'::jsonb,
        '["advanced_analytics", "api_access", "custom_integrations"]'::jsonb,
        '{"orders_per_month": 10000, "warehouses": 5, "users": 50}'::jsonb
    )
    RETURNING id INTO v_plan_id;
    
    -- Create sample organization
    INSERT INTO organizations (id, name, type, slug, status)
    VALUES (
        gen_random_uuid(),
        'QuickShip Logistics',
        '3pl_operator',
        'quickship-logistics',
        'active'
    )
    RETURNING id INTO v_org_id;
    
    -- Create subscription for organization
    INSERT INTO subscriptions (id, organization_id, plan_id, billing_cycle, current_period_start, current_period_end)
    VALUES (
        gen_random_uuid(),
        v_org_id,
        v_plan_id,
        'monthly',
        CURRENT_DATE,
        CURRENT_DATE + INTERVAL '1 month'
    )
    RETURNING id INTO v_subscription_id;
    
    -- Update organization with subscription
    UPDATE organizations SET subscription_id = v_subscription_id WHERE id = v_org_id;
    
    -- Create sample user
    INSERT INTO users (id, email, password_hash, first_name, last_name, status, email_verified_at)
    VALUES (
        gen_random_uuid(),
        'admin@quickship.com',
        '$2b$12$example.hash.for.testing.only',
        'John',
        'Smith',
        'active',
        NOW()
    )
    RETURNING id INTO v_user_id;
    
    -- Link user to organization
    INSERT INTO user_organizations (user_id, organization_id, role, is_primary, accepted_at)
    VALUES (v_user_id, v_org_id, 'org_admin', TRUE, NOW());
    
    -- Create sample warehouse
    INSERT INTO warehouses (id, organization_id, code, name, address, timezone)
    VALUES (
        gen_random_uuid(),
        v_org_id,
        'QS001',
        'QuickShip Main Warehouse',
        '{"street": "123 Warehouse Blvd", "city": "Los Angeles", "state": "CA", "zip": "90210", "country": "USA"}'::jsonb,
        'America/Los_Angeles'
    )
    RETURNING id INTO v_warehouse_id;
    
    -- Create sample products
    INSERT INTO products (id, organization_id, sku, name, description, dimensions)
    VALUES 
    (
        gen_random_uuid(),
        v_org_id,
        'WIDGET001',
        'Premium Widget',
        'High-quality premium widget for industrial use',
        '{"length": 10, "width": 5, "height": 3, "weight": 2.5}'::jsonb
    ),
    (
        gen_random_uuid(),
        v_org_id,
        'GADGET002', 
        'Smart Gadget',
        'IoT-enabled smart gadget with wireless connectivity',
        '{"length": 8, "width": 6, "height": 2, "weight": 1.8}'::jsonb
    )
    RETURNING id INTO v_product_id;
    
    -- Create sample inventory
    INSERT INTO inventory (warehouse_id, product_id, quantity_available, quantity_reserved, last_counted_at)
    SELECT 
        v_warehouse_id,
        p.id,
        floor(random() * 1000 + 100)::integer,
        floor(random() * 50)::integer,
        NOW() - (random() * INTERVAL '30 days')
    FROM products p WHERE p.organization_id = v_org_id;
    
    -- Create sample SLA definition
    INSERT INTO sla_definitions (organization_id, name, metrics, thresholds, applies_to)
    VALUES (
        v_org_id,
        'Order Processing Time',
        '{"metric": "processing_time_hours", "description": "Time from order submission to shipment"}'::jsonb,
        '{"warning": 24, "breach": 48}'::jsonb,
        '{"order_priority": ["standard", "high"]}'::jsonb
    );
    
    RAISE NOTICE 'Sample data created successfully for organization: %', v_org_id;
    RETURN TRUE;
    
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Failed to create sample data: %', SQLERRM;
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- DATA SEEDING FOR SUBSCRIPTION PLANS
-- =========================================================================

-- Insert default subscription plans
INSERT INTO subscription_plans (name, slug, tier, pricing, features, limits) VALUES
(
    'Starter',
    'starter',
    1,
    '{"monthly": 99, "yearly": 990}'::jsonb,
    '["basic_analytics", "email_support", "standard_integrations"]'::jsonb,
    '{"orders_per_month": 1000, "warehouses": 1, "users": 5, "api_calls_per_day": 1000}'::jsonb
),
(
    'Growth',
    'growth', 
    2,
    '{"monthly": 299, "yearly": 2990}'::jsonb,
    '["advanced_analytics", "priority_support", "api_access", "custom_integrations", "sla_monitoring"]'::jsonb,
    '{"orders_per_month": 10000, "warehouses": 5, "users": 50, "api_calls_per_day": 10000}'::jsonb
),
(
    'Pro',
    'pro',
    3,
    '{"monthly": 799, "yearly": 7990}'::jsonb,
    '["premium_analytics", "dedicated_support", "unlimited_api", "custom_integrations", "advanced_sla", "automation_rules"]'::jsonb,
    '{"orders_per_month": 50000, "warehouses": 20, "users": 200, "api_calls_per_day": 100000}'::jsonb
),
(
    'Enterprise',
    'enterprise',
    4,
    '{"monthly": 1999, "yearly": 19990}'::jsonb,
    '["enterprise_analytics", "white_glove_support", "unlimited_everything", "custom_development", "advanced_automation", "compliance_tools"]'::jsonb,
    '{"orders_per_month": -1, "warehouses": -1, "users": -1, "api_calls_per_day": -1}'::jsonb
)
ON CONFLICT (slug) DO NOTHING;

-- =========================================================================
-- MIGRATION STATUS AND REPORTING
-- =========================================================================

-- View to show migration history
CREATE VIEW migration_history AS
SELECT 
    version,
    description,
    applied_at,
    CASE WHEN rollback_sql IS NOT NULL THEN 'Yes' ELSE 'No' END as has_rollback,
    left(checksum, 8) || '...' as checksum_preview
FROM schema_migrations
ORDER BY applied_at DESC;

-- Function to show current migration status
CREATE OR REPLACE FUNCTION migration_status()
RETURNS TABLE (
    total_migrations INTEGER,
    latest_version VARCHAR(20),
    latest_applied TIMESTAMPTZ,
    validation_status TEXT
) AS $$
DECLARE
    v_validation_failed INTEGER;
BEGIN
    -- Check validation status
    SELECT count(*) INTO v_validation_failed
    FROM validate_migration_state()
    WHERE status = 'failed';
    
    RETURN QUERY
    SELECT 
        count(*)::INTEGER as total_migrations,
        (SELECT version FROM schema_migrations ORDER BY applied_at DESC LIMIT 1)::VARCHAR(20) as latest_version,
        (SELECT applied_at FROM schema_migrations ORDER BY applied_at DESC LIMIT 1)::TIMESTAMPTZ as latest_applied,
        CASE WHEN v_validation_failed = 0 THEN 'healthy' ELSE 'issues_detected' END::TEXT as validation_status
    FROM schema_migrations;
END;
$$ LANGUAGE plpgsql;