"""
Walmart Bot Data Access Patterns and Caching Implementation
High-performance data layer optimized for bot operations
"""

import json
import time
import asyncio
from typing import Dict, List, Optional, Any, Tuple
from datetime import datetime, timedelta
from decimal import Decimal
import hashlib
import logging
from dataclasses import dataclass, asdict
from enum import Enum

import asyncpg
import redis.asyncio as redis
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker
from cryptography.fernet import Fernet

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class BotStatus(Enum):
    STOPPED = "stopped"
    STARTING = "starting"
    RUNNING = "running"
    PAUSED = "paused"
    ERROR = "error"
    MAINTENANCE = "maintenance"

@dataclass
class InventorySnapshot:
    product_id: str
    current_price: Decimal
    availability_status: str
    last_updated: datetime
    price_changed: bool
    quantity_available: Optional[int] = None
    location_data: Optional[Dict] = None

@dataclass
class SessionData:
    session_id: str
    session_type: str
    cookies: Dict[str, str]
    tokens: Dict[str, str]
    headers: Dict[str, str]
    expires_at: datetime
    proxy_id: Optional[str] = None

class WalmartBotDataLayer:
    """
    High-performance data access layer for Walmart bot operations
    Combines PostgreSQL for durability with Redis for speed
    """
    
    def __init__(self, db_url: str, redis_url: str, encryption_key: str):
        self.db_url = db_url
        self.redis_url = redis_url
        self.encryption_key = encryption_key
        self.fernet = Fernet(encryption_key.encode())
        
        # Connection pools
        self.pg_engine = create_async_engine(
            db_url,
            pool_size=20,
            max_overflow=30,
            pool_timeout=30,
            pool_recycle=3600,
            echo=False
        )
        self.async_session = sessionmaker(
            self.pg_engine, class_=AsyncSession, expire_on_commit=False
        )
        
        self.redis_pool = None
        self._cache_stats = {'hits': 0, 'misses': 0, 'sets': 0}
        
    async def initialize(self):
        """Initialize connections and cache"""
        self.redis_pool = redis.ConnectionPool.from_url(
            self.redis_url,
            max_connections=50,
            health_check_interval=30,
            socket_connect_timeout=5,
            socket_timeout=5,
            retry_on_timeout=True
        )
        self.redis_client = redis.Redis(connection_pool=self.redis_pool)
        
        # Test connections
        await self._test_connections()
        logger.info("WalmartBotDataLayer initialized successfully")
    
    async def _test_connections(self):
        """Test database connections"""
        # Test PostgreSQL
        async with self.pg_engine.connect() as conn:
            result = await conn.execute("SELECT 1")
            assert result.scalar() == 1
        
        # Test Redis
        await self.redis_client.ping()
        logger.info("Database connections verified")
    
    async def close(self):
        """Close all connections"""
        await self.pg_engine.dispose()
        await self.redis_client.close()
        logger.info("All connections closed")

    # =========================================================================
    # HIGH-FREQUENCY INVENTORY OPERATIONS
    # =========================================================================
    
    async def get_product_inventory_fast(
        self, 
        product_ids: List[str], 
        bot_instance_id: str
    ) -> List[InventorySnapshot]:
        """
        Ultra-fast inventory lookup with multi-level caching
        1. Check Redis cache first
        2. Batch database query for cache misses
        3. Update cache with fresh data
        """
        results = []
        cache_misses = []
        
        # Check Redis cache for each product
        pipe = self.redis_client.pipeline()
        for product_id in product_ids:
            cache_key = f"walmart:inventory:{product_id}"
            pipe.get(cache_key)
        
        cached_data = await pipe.execute()
        
        for i, (product_id, cached) in enumerate(zip(product_ids, cached_data)):
            if cached:
                try:
                    data = json.loads(cached)
                    # Check if data is still fresh (5 minutes for high-freq items)
                    if time.time() - data['last_updated'] < 300:
                        results.append(InventorySnapshot(
                            product_id=product_id,
                            current_price=Decimal(str(data['price'])),
                            availability_status=data['availability'],
                            last_updated=datetime.fromtimestamp(data['last_updated']),
                            price_changed=data.get('price_changed', False),
                            quantity_available=data.get('quantity'),
                            location_data=data.get('location_data')
                        ))
                        self._cache_stats['hits'] += 1
                        continue
                except (json.JSONDecodeError, KeyError, ValueError):
                    logger.warning(f"Invalid cache data for product {product_id}")
            
            cache_misses.append(product_id)
            self._cache_stats['misses'] += 1
        
        # Batch query for cache misses
        if cache_misses:
            fresh_data = await self._batch_inventory_query(cache_misses, bot_instance_id)
            results.extend(fresh_data)
            
            # Update cache with fresh data
            await self._cache_inventory_data(fresh_data)
        
        return results
    
    async def _batch_inventory_query(
        self, 
        product_ids: List[str], 
        bot_instance_id: str
    ) -> List[InventorySnapshot]:
        """Optimized batch query for inventory data"""
        async with self.pg_engine.connect() as conn:
            query = """
            SELECT * FROM fast_inventory_check($1::uuid[], $2::uuid)
            """
            result = await conn.execute(query, [product_ids, bot_instance_id])
            rows = result.fetchall()
            
            return [
                InventorySnapshot(
                    product_id=str(row.product_id),
                    current_price=row.current_price,
                    availability_status=row.availability_status,
                    last_updated=row.last_updated,
                    price_changed=row.price_changed
                ) for row in rows
            ]
    
    async def _cache_inventory_data(self, snapshots: List[InventorySnapshot]):
        """Cache inventory data with appropriate TTL"""
        pipe = self.redis_client.pipeline()
        
        for snapshot in snapshots:
            cache_key = f"walmart:inventory:{snapshot.product_id}"
            cache_data = {
                'price': float(snapshot.current_price),
                'availability': snapshot.availability_status,
                'last_updated': snapshot.last_updated.timestamp(),
                'price_changed': snapshot.price_changed,
                'quantity': snapshot.quantity_available,
                'location_data': snapshot.location_data
            }
            
            # TTL based on price volatility (5 min for changing prices, 1 hour for stable)
            ttl = 300 if snapshot.price_changed else 3600
            
            pipe.setex(cache_key, ttl, json.dumps(cache_data, default=str))
            self._cache_stats['sets'] += 1
        
        await pipe.execute()
    
    async def record_inventory_snapshot(
        self,
        bot_instance_id: str,
        product_id: str,
        inventory_data: Dict[str, Any],
        raw_response: Dict[str, Any]
    ) -> bool:
        """Record new inventory snapshot with price change detection"""
        async with self.pg_engine.connect() as conn:
            async with conn.begin():
                # Insert snapshot
                insert_query = """
                INSERT INTO inventory_snapshots (
                    recorded_at, product_id, bot_instance_id, availability_status,
                    current_price, original_price, discount_percentage, quantity_available,
                    location_data, raw_response
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                RETURNING id
                """
                
                snapshot_id = await conn.execute(insert_query, [
                    datetime.utcnow(),
                    product_id,
                    bot_instance_id,
                    inventory_data.get('availability_status'),
                    inventory_data.get('current_price'),
                    inventory_data.get('original_price'),
                    inventory_data.get('discount_percentage'),
                    inventory_data.get('quantity_available'),
                    json.dumps(inventory_data.get('location_data', {})),
                    json.dumps(raw_response)
                ])
                
                # Check for price changes and create alert if needed
                await self._check_price_changes(conn, product_id, inventory_data.get('current_price'))
                
        # Invalidate cache to force refresh
        cache_key = f"walmart:inventory:{product_id}"
        await self.redis_client.delete(cache_key)
        
        return True
    
    async def _check_price_changes(self, conn, product_id: str, new_price: Decimal):
        """Detect price changes and create alerts"""
        if not new_price:
            return
        
        # Get last price
        query = """
        SELECT current_price 
        FROM inventory_snapshots 
        WHERE product_id = $1 
        AND recorded_at < NOW() - INTERVAL '1 hour'
        ORDER BY recorded_at DESC 
        LIMIT 1
        """
        result = await conn.execute(query, [product_id])
        row = result.fetchone()
        
        if row and row.current_price != new_price:
            change_pct = ((new_price - row.current_price) / row.current_price) * 100
            change_type = 'increase' if new_price > row.current_price else 'decrease'
            
            # Record price change event
            await conn.execute("""
                INSERT INTO price_change_events (
                    detected_at, product_id, previous_price, new_price,
                    price_change_pct, change_type
                ) VALUES ($1, $2, $3, $4, $5, $6)
            """, [
                datetime.utcnow(), product_id, row.current_price,
                new_price, change_pct, change_type
            ])
            
            logger.info(f"Price change detected for {product_id}: {change_type} {abs(change_pct):.2f}%")

    # =========================================================================
    # SESSION MANAGEMENT
    # =========================================================================
    
    async def get_valid_session(
        self, 
        bot_instance_id: str, 
        session_type: str
    ) -> Optional[SessionData]:
        """Get valid session with automatic refresh"""
        cache_key = f"walmart:session:{bot_instance_id}:{session_type}"
        
        # Check cache first
        cached = await self.redis_client.hgetall(cache_key)
        if cached:
            expires = int(cached.get('expires', 0))
            if expires > time.time():
                return SessionData(
                    session_id=cached['session_id'],
                    session_type=session_type,
                    cookies=json.loads(cached['cookies']),
                    tokens=json.loads(cached['tokens']),
                    headers=json.loads(cached['headers']),
                    expires_at=datetime.fromtimestamp(expires),
                    proxy_id=cached.get('proxy_id')
                )
        
        # Cache miss or expired - get from database
        async with self.pg_engine.connect() as conn:
            query = """
            SELECT DISTINCT ON (session_type)
                id, session_data, expires_at, proxy_endpoint_id
            FROM bot_sessions 
            WHERE bot_instance_id = $1 
            AND session_type = $2
            AND is_valid = TRUE
            AND expires_at > NOW()
            ORDER BY session_type, created_at DESC
            """
            result = await conn.execute(query, [bot_instance_id, session_type])
            row = result.fetchone()
            
            if not row:
                return None
            
            session_data = SessionData(
                session_id=str(row.id),
                session_type=session_type,
                cookies=row.session_data.get('cookies', {}),
                tokens=row.session_data.get('tokens', {}),
                headers=row.session_data.get('headers', {}),
                expires_at=row.expires_at,
                proxy_id=str(row.proxy_endpoint_id) if row.proxy_endpoint_id else None
            )
            
            # Cache the session
            await self._cache_session(cache_key, session_data)
            return session_data
    
    async def _cache_session(self, cache_key: str, session: SessionData):
        """Cache session data with TTL"""
        ttl = max(int((session.expires_at - datetime.utcnow()).total_seconds()), 60)
        
        await self.redis_client.hset(cache_key, mapping={
            'session_id': session.session_id,
            'cookies': json.dumps(session.cookies),
            'tokens': json.dumps(session.tokens),
            'headers': json.dumps(session.headers),
            'expires': int(session.expires_at.timestamp()),
            'proxy_id': session.proxy_id or ''
        })
        await self.redis_client.expire(cache_key, ttl)
    
    async def create_new_session(
        self,
        bot_instance_id: str,
        session_type: str,
        session_data: Dict[str, Any],
        proxy_endpoint_id: Optional[str] = None,
        expires_in_hours: int = 24
    ) -> SessionData:
        """Create new bot session"""
        expires_at = datetime.utcnow() + timedelta(hours=expires_in_hours)
        
        async with self.pg_engine.connect() as conn:
            query = """
            INSERT INTO bot_sessions (
                bot_instance_id, session_type, session_data,
                proxy_endpoint_id, created_at, expires_at
            ) VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING id
            """
            
            result = await conn.execute(query, [
                bot_instance_id, session_type, json.dumps(session_data),
                proxy_endpoint_id, datetime.utcnow(), expires_at
            ])
            session_id = result.scalar()
        
        new_session = SessionData(
            session_id=str(session_id),
            session_type=session_type,
            cookies=session_data.get('cookies', {}),
            tokens=session_data.get('tokens', {}),
            headers=session_data.get('headers', {}),
            expires_at=expires_at,
            proxy_id=proxy_endpoint_id
        )
        
        # Cache immediately
        cache_key = f"walmart:session:{bot_instance_id}:{session_type}"
        await self._cache_session(cache_key, new_session)
        
        return new_session

    # =========================================================================
    # CREDENTIAL MANAGEMENT
    # =========================================================================
    
    async def store_encrypted_credential(
        self,
        bot_instance_id: str,
        credential_type: str,
        account_identifier: str,
        credential_data: Dict[str, Any],
        expires_at: Optional[datetime] = None
    ) -> str:
        """Store encrypted credentials securely"""
        async with self.pg_engine.connect() as conn:
            query = "SELECT store_encrypted_credential($1, $2, $3, $4, $5)"
            result = await conn.execute(query, [
                bot_instance_id, credential_type, account_identifier,
                json.dumps(credential_data), expires_at
            ])
            credential_id = result.scalar()
            
        logger.info(f"Stored encrypted credential {credential_id} for bot {bot_instance_id}")
        return str(credential_id)
    
    async def get_decrypted_credential(self, credential_id: str) -> Optional[Dict[str, Any]]:
        """Retrieve and decrypt credentials"""
        # Check cache first
        cache_key = f"walmart:credential:{credential_id}"
        cached = await self.redis_client.get(cache_key)
        if cached:
            self._cache_stats['hits'] += 1
            return json.loads(cached)
        
        async with self.pg_engine.connect() as conn:
            query = "SELECT get_decrypted_credential($1)"
            result = await conn.execute(query, [credential_id])
            credential_data = result.scalar()
            
            if credential_data:
                # Cache for 1 hour with sensitive data TTL
                await self.redis_client.setex(cache_key, 3600, json.dumps(credential_data))
                self._cache_stats['sets'] += 1
                return credential_data
            
        self._cache_stats['misses'] += 1
        return None

    # =========================================================================
    # REQUEST LOGGING AND REPLAY
    # =========================================================================
    
    async def log_http_request(
        self,
        bot_instance_id: str,
        request_data: Dict[str, Any],
        response_data: Dict[str, Any],
        session_id: Optional[str] = None,
        proxy_used: Optional[str] = None
    ) -> str:
        """Log HTTP request/response for debugging and replay"""
        async with self.pg_engine.connect() as conn:
            query = """
            INSERT INTO http_requests (
                timestamp, bot_instance_id, session_id, request_method,
                request_url, request_headers, request_body, response_status,
                response_headers, response_body, response_time_ms, proxy_used,
                success, error_type, error_message
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
            RETURNING id
            """
            
            result = await conn.execute(query, [
                datetime.utcnow(),
                bot_instance_id,
                session_id,
                request_data.get('method'),
                request_data.get('url'),
                json.dumps(request_data.get('headers', {})),
                request_data.get('body'),
                response_data.get('status'),
                json.dumps(response_data.get('headers', {})),
                response_data.get('body'),
                response_data.get('response_time_ms'),
                proxy_used,
                response_data.get('success', True),
                response_data.get('error_type'),
                response_data.get('error_message')
            ])
            
            request_id = result.scalar()
            
        # Store in Redis for real-time monitoring (short TTL)
        monitoring_key = f"walmart:recent_requests:{bot_instance_id}"
        request_summary = {
            'id': str(request_id),
            'timestamp': datetime.utcnow().isoformat(),
            'url': request_data.get('url'),
            'status': response_data.get('status'),
            'success': response_data.get('success', True)
        }
        
        await self.redis_client.lpush(monitoring_key, json.dumps(request_summary))
        await self.redis_client.ltrim(monitoring_key, 0, 99)  # Keep last 100 requests
        await self.redis_client.expire(monitoring_key, 3600)
        
        return str(request_id)

    # =========================================================================
    # PERFORMANCE MONITORING
    # =========================================================================
    
    async def record_performance_metric(
        self,
        bot_instance_id: str,
        metric_category: str,
        metric_name: str,
        metric_value: float,
        metric_unit: str = '',
        tags: Optional[Dict[str, Any]] = None
    ):
        """Record performance metrics"""
        async with self.pg_engine.connect() as conn:
            await conn.execute("""
                INSERT INTO bot_performance_metrics (
                    measured_at, bot_instance_id, metric_category,
                    metric_name, metric_value, metric_unit, tags
                ) VALUES ($1, $2, $3, $4, $5, $6, $7)
            """, [
                datetime.utcnow(), bot_instance_id, metric_category,
                metric_name, metric_value, metric_unit,
                json.dumps(tags or {})
            ])
        
        # Also store in Redis for real-time monitoring
        redis_key = f"walmart:metrics:{bot_instance_id}:{metric_category}"
        metric_data = {
            'name': metric_name,
            'value': metric_value,
            'unit': metric_unit,
            'timestamp': time.time(),
            'tags': tags or {}
        }
        
        await self.redis_client.lpush(redis_key, json.dumps(metric_data, default=str))
        await self.redis_client.ltrim(redis_key, 0, 49)  # Keep last 50 metrics
        await self.redis_client.expire(redis_key, 7200)  # 2 hours TTL
    
    async def get_bot_health_status(self, bot_instance_id: str) -> Dict[str, Any]:
        """Get comprehensive bot health status"""
        health_data = {}
        
        # Check database for bot status
        async with self.pg_engine.connect() as conn:
            query = """
            SELECT status, last_heartbeat, 
                   EXTRACT(EPOCH FROM (NOW() - last_heartbeat)) as seconds_since_heartbeat
            FROM bot_instances 
            WHERE id = $1
            """
            result = await conn.execute(query, [bot_instance_id])
            row = result.fetchone()
            
            if row:
                health_data.update({
                    'bot_status': row.status,
                    'last_heartbeat': row.last_heartbeat,
                    'seconds_since_heartbeat': row.seconds_since_heartbeat,
                    'heartbeat_healthy': row.seconds_since_heartbeat < 300  # 5 minutes
                })
        
        # Get recent performance metrics from Redis
        metrics_key = f"walmart:metrics:{bot_instance_id}:api_performance"
        recent_metrics = await self.redis_client.lrange(metrics_key, 0, 9)
        
        if recent_metrics:
            response_times = []
            success_rates = []
            
            for metric_json in recent_metrics:
                metric = json.loads(metric_json)
                if metric['name'] == 'response_time':
                    response_times.append(metric['value'])
                elif metric['name'] == 'success_rate':
                    success_rates.append(metric['value'])
            
            health_data.update({
                'avg_response_time': sum(response_times) / len(response_times) if response_times else 0,
                'avg_success_rate': sum(success_rates) / len(success_rates) if success_rates else 0,
                'recent_requests': len(recent_metrics)
            })
        
        # Check cache performance
        cache_hit_rate = 0
        if self._cache_stats['hits'] + self._cache_stats['misses'] > 0:
            cache_hit_rate = self._cache_stats['hits'] / (self._cache_stats['hits'] + self._cache_stats['misses'])
        
        health_data.update({
            'cache_hit_rate': cache_hit_rate,
            'cache_stats': self._cache_stats.copy()
        })
        
        return health_data

    # =========================================================================
    # RATE LIMITING AND THROTTLING
    # =========================================================================
    
    async def check_rate_limit(
        self,
        bot_instance_id: str,
        endpoint: str,
        limit: int = 200,
        window_seconds: int = 3600
    ) -> Tuple[bool, Dict[str, Any]]:
        """Check if request is within rate limits"""
        rate_key = f"walmart:ratelimit:{bot_instance_id}:{endpoint}"
        current_time = int(time.time())
        window_start = current_time - (current_time % window_seconds)
        
        # Use Redis pipeline for atomic operations
        pipe = self.redis_client.pipeline()
        
        # Get current count
        pipe.hget(rate_key, 'count')
        pipe.hget(rate_key, 'window_start')
        
        results = await pipe.execute()
        current_count = int(results[0] or 0)
        stored_window = int(results[1] or 0)
        
        # Reset counter if we're in a new window
        if stored_window != window_start:
            current_count = 0
            stored_window = window_start
        
        # Check if we're within limits
        within_limit = current_count < limit
        
        if within_limit:
            # Increment counter
            pipe = self.redis_client.pipeline()
            pipe.hset(rate_key, mapping={
                'count': current_count + 1,
                'window_start': stored_window,
                'limit': limit,
                'window_size': window_seconds
            })
            pipe.expire(rate_key, window_seconds)
            await pipe.execute()
        
        rate_limit_info = {
            'within_limit': within_limit,
            'current_count': current_count + (1 if within_limit else 0),
            'limit': limit,
            'window_start': stored_window,
            'window_seconds': window_seconds,
            'reset_time': stored_window + window_seconds
        }
        
        return within_limit, rate_limit_info

    # =========================================================================
    # CONFIGURATION MANAGEMENT
    # =========================================================================
    
    async def get_bot_config(self, bot_instance_id: str) -> Dict[str, Any]:
        """Get bot configuration with caching"""
        cache_key = f"walmart:config:{bot_instance_id}"
        cached = await self.redis_client.get(cache_key)
        
        if cached:
            return json.loads(cached)
        
        async with self.pg_engine.connect() as conn:
            query = """
            SELECT config_key, config_value, config_type
            FROM bot_configurations 
            WHERE bot_instance_id = $1
            """
            result = await conn.execute(query, [bot_instance_id])
            rows = result.fetchall()
            
            config = {}
            for row in rows:
                config[row.config_key] = row.config_value
            
            # Cache for 1 hour
            await self.redis_client.setex(cache_key, 3600, json.dumps(config, default=str))
            return config
    
    async def update_bot_config(
        self,
        bot_instance_id: str,
        config_key: str,
        config_value: Any,
        config_type: str = 'general'
    ):
        """Update bot configuration and invalidate cache"""
        async with self.pg_engine.connect() as conn:
            await conn.execute("""
                INSERT INTO bot_configurations 
                (bot_instance_id, config_key, config_value, config_type, updated_at)
                VALUES ($1, $2, $3, $4, $5)
                ON CONFLICT (bot_instance_id, config_key)
                DO UPDATE SET 
                    config_value = EXCLUDED.config_value,
                    updated_at = EXCLUDED.updated_at,
                    version = bot_configurations.version + 1
            """, [
                bot_instance_id, config_key, json.dumps(config_value),
                config_type, datetime.utcnow()
            ])
        
        # Invalidate cache
        cache_key = f"walmart:config:{bot_instance_id}"
        await self.redis_client.delete(cache_key)

# Example usage and testing
async def example_usage():
    """Example of how to use the WalmartBotDataLayer"""
    
    # Configuration
    db_url = "postgresql+asyncpg://user:pass@localhost/walmart_bot"
    redis_url = "redis://localhost:6379/0"
    encryption_key = "your-32-byte-base64-encoded-key-here"
    
    # Initialize data layer
    data_layer = WalmartBotDataLayer(db_url, redis_url, encryption_key)
    await data_layer.initialize()
    
    try:
        bot_id = "550e8400-e29b-41d4-a716-446655440000"
        
        # Example: Fast inventory lookup
        product_ids = [
            "123e4567-e89b-12d3-a456-426614174000",
            "987fcdeb-51a2-43d1-b234-567890abcdef"
        ]
        
        inventory_data = await data_layer.get_product_inventory_fast(product_ids, bot_id)
        print(f"Retrieved inventory for {len(inventory_data)} products")
        
        # Example: Session management
        session = await data_layer.get_valid_session(bot_id, "walmart_web")
        if not session:
            # Create new session
            session_data = {
                "cookies": {"session_id": "abc123", "csrf_token": "xyz789"},
                "tokens": {"access_token": "token123"},
                "headers": {"User-Agent": "Mozilla/5.0..."}
            }
            session = await data_layer.create_new_session(bot_id, "walmart_web", session_data)
        
        print(f"Using session: {session.session_id}")
        
        # Example: Performance monitoring
        await data_layer.record_performance_metric(
            bot_id, "api_performance", "response_time", 250.5, "ms"
        )
        
        # Example: Rate limiting
        within_limit, rate_info = await data_layer.check_rate_limit(bot_id, "product_api")
        print(f"Rate limit check: {within_limit}, current: {rate_info['current_count']}")
        
        # Example: Health status
        health = await data_layer.get_bot_health_status(bot_id)
        print(f"Bot health: {health}")
        
    finally:
        await data_layer.close()

if __name__ == "__main__":
    asyncio.run(example_usage())