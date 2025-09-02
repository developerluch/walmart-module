-- Synvelo Database Maintenance Procedures
-- Data retention, optimization, and compliance functions

-- =========================================================================
-- DATA RETENTION POLICIES
-- =========================================================================

-- Set up automatic retention policies for time-series data
SELECT add_retention_policy('tracking_events', INTERVAL '6 months');
SELECT add_retention_policy('order_status_history', INTERVAL '2 years');
SELECT add_retention_policy('sla_measurements', INTERVAL '1 year');
SELECT add_retention_policy('automation_executions', INTERVAL '6 months');
SELECT add_retention_policy('usage_events', INTERVAL '2 years');
SELECT add_retention_policy('audit_logs', INTERVAL '7 years');
SELECT add_retention_policy('compliance_events', INTERVAL '7 years');

-- =========================================================================
-- CONTINUOUS AGGREGATIONS
-- =========================================================================

-- Hourly SLA aggregations for faster reporting
CREATE MATERIALIZED VIEW sla_hourly_stats
WITH (timescaledb.continuous) AS
SELECT 
    sla_definition_id,
    time_bucket(INTERVAL '1 hour', measured_at) as hour,
    metric_name,
    avg(value) as avg_value,
    min(value) as min_value,
    max(value) as max_value,
    count(*) as measurement_count,
    count(*) FILTER (WHERE status = 'breach') as breach_count
FROM sla_measurements
GROUP BY 1, 2, 3;

-- Daily order metrics
CREATE MATERIALIZED VIEW daily_order_metrics
WITH (timescaledb.continuous) AS
SELECT 
    organization_id,
    time_bucket(INTERVAL '1 day', created_at) as day,
    status,
    count(*) as order_count,
    sum(total_value) as total_value,
    avg(total_value) as avg_order_value
FROM orders
GROUP BY 1, 2, 3;

-- Hourly usage aggregations for billing
CREATE MATERIALIZED VIEW hourly_usage_stats
WITH (timescaledb.continuous) AS
SELECT 
    organization_id,
    time_bucket(INTERVAL '1 hour', event_time) as hour,
    event_type,
    sum(quantity) as total_quantity,
    count(*) as event_count
FROM usage_events
GROUP BY 1, 2, 3;

-- Set up refresh policies
SELECT add_continuous_aggregate_policy('sla_hourly_stats',
    start_offset => INTERVAL '1 day',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('daily_order_metrics',
    start_offset => INTERVAL '7 days',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('hourly_usage_stats',
    start_offset => INTERVAL '1 day',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes');

-- =========================================================================
-- MATERIALIZED VIEWS FOR PERFORMANCE
-- =========================================================================

-- Organization performance metrics
CREATE MATERIALIZED VIEW organization_metrics AS
SELECT 
    o.id,
    o.name,
    o.type,
    count(ord.id) as total_orders,
    count(ord.id) FILTER (WHERE ord.created_at >= NOW() - INTERVAL '30 days') as orders_last_30_days,
    count(ord.id) FILTER (WHERE ord.status = 'delivered') as delivered_orders,
    avg(EXTRACT(EPOCH FROM (ord.updated_at - ord.created_at))/3600) as avg_processing_hours,
    sum(ord.total_value) FILTER (WHERE ord.created_at >= NOW() - INTERVAL '30 days') as revenue_last_30_days,
    count(DISTINCT w.id) as warehouse_count,
    count(DISTINCT p.id) as product_count
FROM organizations o
LEFT JOIN orders ord ON o.id = ord.organization_id
LEFT JOIN warehouses w ON o.id = w.organization_id
LEFT JOIN products p ON o.id = p.organization_id
GROUP BY o.id, o.name, o.type;

CREATE UNIQUE INDEX ON organization_metrics (id);

-- Current inventory summary
CREATE MATERIALIZED VIEW inventory_summary AS
SELECT 
    w.organization_id,
    w.id as warehouse_id,
    w.name as warehouse_name,
    p.id as product_id,
    p.sku,
    p.name as product_name,
    i.quantity_available,
    i.quantity_reserved,
    i.quantity_damaged,
    i.last_movement_at,
    p.dimensions->>'weight' as unit_weight
FROM inventory i
JOIN warehouses w ON i.warehouse_id = w.id
JOIN products p ON i.product_id = p.id
WHERE i.quantity_available > 0 OR i.quantity_reserved > 0;

CREATE INDEX ON inventory_summary (organization_id, warehouse_id);
CREATE INDEX ON inventory_summary (organization_id, product_id);

-- Active shipment tracking
CREATE MATERIALIZED VIEW active_shipments AS
SELECT 
    s.id,
    s.shipment_number,
    s.tracking_number,
    s.status,
    s.estimated_delivery_date,
    o.organization_id,
    o.order_number,
    o.customer_info->>'name' as customer_name,
    te.event_time as last_tracking_update,
    te.location as last_known_location
FROM shipments s
JOIN orders o ON s.order_id = o.id
LEFT JOIN LATERAL (
    SELECT event_time, location
    FROM tracking_events
    WHERE shipment_id = s.id
    ORDER BY event_time DESC
    LIMIT 1
) te ON true
WHERE s.status NOT IN ('delivered', 'returned', 'cancelled');

CREATE INDEX ON active_shipments (organization_id, status);

-- =========================================================================
-- DATA QUALITY & MONITORING FUNCTIONS
-- =========================================================================

-- Function to check data integrity
CREATE OR REPLACE FUNCTION check_data_integrity()
RETURNS TABLE (
    check_name TEXT,
    table_name TEXT,
    issue_count BIGINT,
    severity TEXT,
    description TEXT
) AS $$
BEGIN
    -- Check for orphaned records
    RETURN QUERY
    SELECT 
        'orphaned_order_items'::TEXT,
        'order_items'::TEXT,
        count(*)::BIGINT,
        'high'::TEXT,
        'Order items without valid orders'::TEXT
    FROM order_items oi
    LEFT JOIN orders o ON oi.order_id = o.id
    WHERE o.id IS NULL;
    
    -- Check for negative inventory
    RETURN QUERY
    SELECT 
        'negative_inventory'::TEXT,
        'inventory'::TEXT,
        count(*)::BIGINT,
        'critical'::TEXT,
        'Inventory with negative quantities'::TEXT
    FROM inventory
    WHERE quantity_available < 0 OR quantity_reserved < 0;
    
    -- Check for expired sessions
    RETURN QUERY
    SELECT 
        'expired_sessions'::TEXT,
        'user_sessions'::TEXT,
        count(*)::BIGINT,
        'low'::TEXT,
        'Expired sessions that should be cleaned up'::TEXT
    FROM user_sessions
    WHERE expires_at < NOW();
    
    -- Check for orders without items
    RETURN QUERY
    SELECT 
        'orders_without_items'::TEXT,
        'orders'::TEXT,
        count(*)::BIGINT,
        'medium'::TEXT,
        'Orders without any items'::TEXT
    FROM orders o
    LEFT JOIN order_items oi ON o.id = oi.order_id
    WHERE oi.id IS NULL AND o.status != 'draft';
    
    -- Check for users without organizations
    RETURN QUERY
    SELECT 
        'users_without_orgs'::TEXT,
        'users'::TEXT,
        count(*)::BIGINT,
        'medium'::TEXT,
        'Active users not assigned to any organization'::TEXT
    FROM users u
    LEFT JOIN user_organizations uo ON u.id = uo.user_id
    WHERE uo.id IS NULL AND u.status = 'active';
END;
$$ LANGUAGE plpgsql;

-- Function to clean up expired sessions
CREATE OR REPLACE FUNCTION cleanup_expired_sessions()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM user_sessions 
    WHERE expires_at < NOW() - INTERVAL '1 day';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    INSERT INTO audit_logs (
        occurred_at, action, resource_type, 
        metadata
    ) VALUES (
        NOW(), 'cleanup_expired_sessions', 'user_sessions',
        jsonb_build_object('deleted_count', deleted_count)
    );
    
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- COMPLIANCE & GDPR FUNCTIONS
-- =========================================================================

-- Handle data subject requests (GDPR/CCPA)
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
            -- Return user data
            result := jsonb_build_object(
                'user_data', to_jsonb(user_record),
                'orders_count', (
                    SELECT count(*) FROM orders o 
                    JOIN user_organizations uo ON o.organization_id = uo.organization_id
                    WHERE uo.user_id = user_record.id
                ),
                'organizations', (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'organization_id', uo.organization_id,
                            'role', uo.role,
                            'joined_at', uo.created_at
                        )
                    )
                    FROM user_organizations uo
                    WHERE uo.user_id = user_record.id
                )
            );
            
        WHEN 'deletion' THEN
            -- Implement right to be forgotten
            -- Note: Some data may need to be retained for legal reasons
            UPDATE users SET 
                email = 'deleted_' || id::text || '@synvelo.deleted',
                first_name = 'DELETED',
                last_name = 'USER',
                phone = NULL,
                phone_encrypted = NULL,
                avatar_url = NULL,
                preferences = '{}',
                status = 'inactive'
            WHERE id = user_record.id;
            
            -- Anonymize related data but keep business records
            UPDATE orders SET
                customer_info = jsonb_build_object(
                    'name', 'ANONYMIZED USER',
                    'email', 'anonymized@synvelo.deleted'
                ),
                customer_info_encrypted = NULL
            WHERE created_by = user_record.id;
            
            result := jsonb_build_object('status', 'deleted');
            
        WHEN 'portability' THEN
            -- Export user data in portable format
            result := jsonb_build_object(
                'user_profile', to_jsonb(user_record),
                'orders', (
                    SELECT jsonb_agg(to_jsonb(o))
                    FROM orders o
                    JOIN user_organizations uo ON o.organization_id = uo.organization_id
                    WHERE uo.user_id = user_record.id
                ),
                'audit_trail', (
                    SELECT jsonb_agg(to_jsonb(al))
                    FROM audit_logs al
                    WHERE al.user_id = user_record.id
                    ORDER BY al.occurred_at DESC
                    LIMIT 1000
                )
            );
            
        ELSE
            result := jsonb_build_object('error', 'Invalid request type');
    END CASE;
    
    -- Update compliance event with completion
    UPDATE compliance_events 
    SET status = 'completed', completed_at = NOW()
    WHERE subject_id = subject_email 
    AND event_type = request_type
    AND occurred_at = (
        SELECT MAX(occurred_at) 
        FROM compliance_events 
        WHERE subject_id = subject_email 
        AND event_type = request_type
    );
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- BACKUP VERIFICATION
-- =========================================================================

-- Function to verify backup integrity
CREATE OR REPLACE FUNCTION verify_backup_integrity()
RETURNS TABLE (
    table_name TEXT,
    row_count BIGINT,
    checksum TEXT,
    last_updated TIMESTAMPTZ,
    size_mb NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.schemaname || '.' || t.tablename as table_name,
        t.n_tup_ins + t.n_tup_upd - t.n_tup_del as row_count,
        md5(t.schemaname || '.' || t.tablename || t.n_tup_ins::text) as checksum,
        GREATEST(t.last_vacuum, t.last_autovacuum, t.last_analyze, t.last_autoanalyze) as last_updated,
        pg_total_relation_size(t.schemaname||'.'||t.tablename) / (1024*1024) as size_mb
    FROM pg_stat_user_tables t
    WHERE t.schemaname = 'public'
    ORDER BY size_mb DESC;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- MONITORING VIEWS
-- =========================================================================

-- Database health metrics
CREATE VIEW db_health_metrics AS
SELECT 
    'active_connections' as metric,
    count(*)::bigint as value,
    'connections' as unit
FROM pg_stat_activity 
WHERE state = 'active'
UNION ALL
SELECT 
    'slow_queries',
    count(*)::bigint,
    'queries'
FROM pg_stat_activity 
WHERE state = 'active' 
AND query_start < NOW() - INTERVAL '5 minutes'
UNION ALL
SELECT 
    'database_size',
    pg_database_size(current_database())::bigint,
    'bytes'
UNION ALL
SELECT 
    'cache_hit_ratio',
    (sum(heap_blks_hit) * 100 / GREATEST(sum(heap_blks_hit + heap_blks_read), 1))::bigint,
    'percentage'
FROM pg_statio_user_tables;

-- Business metrics monitoring
CREATE VIEW business_metrics AS
SELECT 
    'orders_today' as metric,
    count(*)::bigint as value,
    'orders' as unit
FROM orders 
WHERE created_at >= CURRENT_DATE
UNION ALL
SELECT 
    'orders_last_hour',
    count(*)::bigint,
    'orders'
FROM orders 
WHERE created_at >= NOW() - INTERVAL '1 hour'
UNION ALL
SELECT 
    'active_shipments',
    count(*)::bigint,
    'shipments'
FROM shipments
WHERE status NOT IN ('delivered', 'returned', 'cancelled')
UNION ALL
SELECT 
    'sla_breaches_today',
    count(*)::bigint,
    'breaches'
FROM sla_measurements 
WHERE measured_at >= CURRENT_DATE 
AND status = 'breach'
UNION ALL
SELECT 
    'revenue_today',
    COALESCE(sum(total_value), 0)::bigint,
    'cents'
FROM orders 
WHERE created_at >= CURRENT_DATE 
AND status = 'delivered';

-- Data inventory for compliance
CREATE VIEW data_inventory AS
SELECT 
    schemaname,
    tablename,
    CASE 
        WHEN tablename IN ('users', 'orders', 'audit_logs') THEN 'high'
        WHEN tablename LIKE '%_history' THEN 'medium'
        ELSE 'low'
    END as sensitivity_level,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
    (SELECT count(*) FROM information_schema.columns 
     WHERE table_schema = schemaname AND table_name = tablename) as column_count
FROM pg_tables 
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- =========================================================================
-- SCHEDULED MAINTENANCE TASKS
-- =========================================================================

-- Create scheduled job to refresh materialized views
-- Note: This requires pg_cron extension
-- SELECT cron.schedule('refresh-org-metrics', '0 6 * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY organization_metrics;');
-- SELECT cron.schedule('refresh-inventory-summary', '0 */4 * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY inventory_summary;');
-- SELECT cron.schedule('refresh-active-shipments', '*/15 * * * *', 'REFRESH MATERIALIZED VIEW CONCURRENTLY active_shipments;');
-- SELECT cron.schedule('cleanup-sessions', '0 2 * * *', 'SELECT cleanup_expired_sessions();');

-- =========================================================================
-- PERFORMANCE MONITORING
-- =========================================================================

-- Query performance monitoring
CREATE VIEW slow_queries AS
SELECT 
    query,
    calls,
    total_time,
    mean_time,
    rows,
    100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0) AS hit_percent
FROM pg_stat_statements 
WHERE calls > 100
ORDER BY mean_time DESC 
LIMIT 20;

-- Table bloat monitoring
CREATE VIEW table_bloat AS
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
    pg_stat_get_live_tuples(c.oid) as live_tuples,
    pg_stat_get_dead_tuples(c.oid) as dead_tuples,
    CASE 
        WHEN pg_stat_get_live_tuples(c.oid) > 0 
        THEN round(100.0 * pg_stat_get_dead_tuples(c.oid) / pg_stat_get_live_tuples(c.oid), 2)
        ELSE 0
    END as bloat_ratio
FROM pg_tables t
JOIN pg_class c ON c.relname = t.tablename
WHERE schemaname = 'public'
AND pg_stat_get_dead_tuples(c.oid) > 1000
ORDER BY bloat_ratio DESC;