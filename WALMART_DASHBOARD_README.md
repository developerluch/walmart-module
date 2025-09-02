# Walmart Bot Monitoring Dashboard

A comprehensive real-time monitoring dashboard for Walmart automation bot operations with WebSocket connectivity, proxy health monitoring, and advanced analytics.

## Features

### 🎯 Real-time Bot Status Display
- Live bot status (Active/Stopped) with uptime tracking
- Last check timestamp and health indicators
- Connection status with automatic reconnection

### 📊 Success/Failure Metrics Visualization
- Real-time success rate calculation with progress bars
- Success/failure counters with color-coded indicators
- Historical trend tracking

### 🔒 Proxy Health Monitoring
- Live proxy status monitoring (Healthy/Failed)
- Automatic proxy rotation indicators
- IP address and port tracking with health checks
- Active proxy counter display

### 📦 Order History Tracking
- Recent order display with status indicators
- Order ID tracking with product information
- Status categorization (Completed/Processing/Failed)

### 📈 Inventory Level Alerts
- Real-time stock level monitoring
- Color-coded stock indicators (High/Medium/Low/Out)
- Automatic alert system for low stock items
- Visual inventory status dashboard

### 🌐 WebSocket Connection for Live Updates
- Real-time data streaming from Go backend
- Automatic reconnection with exponential backoff
- Connection status indicators
- Live log streaming

### ⚙️ Configuration Management Interface
- Bot settings configuration (check intervals, retries, timeouts)
- Proxy configuration (rotation, health checks, concurrent requests)
- Real-time configuration updates
- Save/Reset configuration options

### 📋 Request/Response Log Viewer
- Live log streaming with color-coded levels
- Timestamp tracking for all operations
- Filterable log entries (Success/Info/Warning/Error)
- Automatic log rotation (keeps last 50 entries)

## Architecture

### Frontend (HTML/CSS/JavaScript)
- **Single Page Application**: Pure vanilla JavaScript with modern ES6+ features
- **WebSocket Client**: Real-time communication with Go backend
- **Responsive Design**: Mobile-first design with CSS Grid and Flexbox
- **Real-time Updates**: Live data visualization without page refreshes
- **Modern UI**: Glass morphism design with smooth animations

### Backend (Go)
- **WebSocket Server**: Real-time communication using Gorilla WebSocket
- **REST API**: RESTful endpoints for configuration and status
- **Concurrent Processing**: Goroutines for parallel operations
- **In-Memory Data**: Fast data access with mutex-protected structures
- **Health Monitoring**: Automated proxy and inventory monitoring

## Setup Instructions

### Prerequisites
- Go 1.21 or higher
- Modern web browser with WebSocket support

### Installation

1. **Clone or download the files:**
   ```bash
   # Files needed:
   # - walmart-bot-dashboard.html
   # - walmart-bot-backend.go
   # - go.mod
   ```

2. **Install Go dependencies:**
   ```bash
   go mod tidy
   ```

3. **Run the backend server:**
   ```bash
   go run walmart-bot-backend.go
   ```

4. **Access the dashboard:**
   ```
   Open your browser to: http://localhost:8080
   ```

## API Endpoints

### WebSocket
- **Endpoint**: `ws://localhost:8080/ws`
- **Purpose**: Real-time bidirectional communication
- **Messages**: JSON format with type and payload

### REST API
- **GET `/api/status`**: Get current bot status
- **GET `/api/metrics`**: Get all metrics (success, performance, proxy, inventory)
- **GET `/api/config`**: Get current configuration
- **POST `/api/config`**: Update configuration

## WebSocket Message Types

### From Backend to Frontend
```json
{
  "type": "bot_status",
  "payload": {
    "status": "ACTIVE",
    "uptime": "2h34m12s",
    "lastCheck": "12:34 PM"
  }
}
```

```json
{
  "type": "success_metrics",
  "payload": {
    "successful": 143,
    "failed": 8
  }
}
```

```json
{
  "type": "proxy_health",
  "payload": [
    {
      "ip": "192.168.1.101",
      "port": 8080,
      "healthy": true,
      "lastUsed": "2024-01-01T12:34:56Z"
    }
  ]
}
```

### From Frontend to Backend
```json
{
  "type": "command",
  "command": "start_bot",
  "payload": null,
  "timestamp": "2024-01-01T12:34:56Z"
}
```

```json
{
  "type": "command",
  "command": "update_config",
  "payload": {
    "checkInterval": 5000,
    "maxRetries": 3,
    "timeout": 10000
  },
  "timestamp": "2024-01-01T12:34:56Z"
}
```

## Dashboard Controls

### Bot Management
- **Start Bot**: Initiates bot operations
- **Stop Bot**: Stops bot with confirmation dialog
- **Refresh**: Forces data refresh from backend

### Configuration Management
- **Bot Settings**:
  - Check Interval (ms): Time between inventory checks
  - Max Retries: Maximum retry attempts for failed operations
  - Timeout (ms): Request timeout duration

- **Proxy Settings**:
  - Rotation Interval (s): Time between proxy rotations
  - Health Check (s): Proxy health check frequency
  - Concurrent Requests: Maximum simultaneous requests

## Customization

### Adding New Metrics
1. **Backend**: Add new data structure in `walmart-bot-backend.go`
2. **WebSocket**: Add new message type and broadcast logic
3. **Frontend**: Add message handler and UI components

### Styling Customization
- **Colors**: Modify CSS custom properties in the `<style>` section
- **Layout**: Adjust grid layouts and responsiveness
- **Animations**: Customize transitions and effects

### Extending Functionality
- **Database Integration**: Replace in-memory data with database
- **Authentication**: Add user authentication and authorization
- **Logging**: Integrate with external logging systems
- **Alerts**: Add email/SMS notification systems

## Production Deployment

### Security Considerations
1. **Origin Validation**: Update WebSocket CheckOrigin function
2. **Authentication**: Implement JWT or session-based auth
3. **HTTPS**: Enable TLS for secure connections
4. **Rate Limiting**: Add request rate limiting
5. **Input Validation**: Sanitize all user inputs

### Performance Optimizations
1. **Database**: Use persistent storage (PostgreSQL, MongoDB)
2. **Caching**: Implement Redis for fast data access
3. **Load Balancing**: Use reverse proxy (Nginx, HAProxy)
4. **Monitoring**: Add APM tools (Prometheus, Grafana)

### Environment Configuration
```bash
# Environment variables for production
export WALMART_BOT_PORT=8080
export WALMART_BOT_HOST=0.0.0.0
export WALMART_BOT_DB_URL="postgres://..."
export WALMART_BOT_LOG_LEVEL=info
```

## Integration with Existing Systems

### Walmart Bot Integration
Replace mock data with actual bot operations:
1. **Product Monitoring**: Connect to real product APIs
2. **Order Processing**: Integrate with checkout automation
3. **Proxy Management**: Connect to proxy rotation services
4. **Inventory Tracking**: Real-time stock level monitoring

### Third-party Services
- **Notification Services**: Slack, Discord, email providers
- **Analytics**: Google Analytics, custom tracking
- **Monitoring**: DataDog, New Relic, custom metrics
- **Storage**: AWS S3, Google Cloud Storage for logs

## Troubleshooting

### Common Issues

1. **WebSocket Connection Failed**
   - Check if backend server is running on port 8080
   - Verify firewall settings allow WebSocket connections
   - Check browser console for detailed error messages

2. **Dashboard Not Loading**
   - Ensure `walmart-bot-dashboard.html` is in the same directory as the Go file
   - Check browser network tab for failed requests
   - Verify Go server is serving static files correctly

3. **Real-time Updates Not Working**
   - Check WebSocket connection status indicator
   - Verify backend is broadcasting messages correctly
   - Check browser console for WebSocket errors

4. **Configuration Not Saving**
   - Check POST request to `/api/config` endpoint
   - Verify JSON format in configuration payload
   - Check backend logs for processing errors

### Development Mode
```bash
# Enable verbose logging
go run walmart-bot-backend.go -v

# Enable CORS for development
export WALMART_BOT_CORS=true
```

## License and Contributing

This dashboard is designed to be easily customizable and extensible. Feel free to modify the code to match your specific requirements.

### Contributing Guidelines
1. Follow Go coding standards and best practices
2. Maintain compatibility with existing WebSocket API
3. Add comprehensive comments for new features
4. Test all functionality before submitting changes
5. Update documentation for new features

---

**Note**: This dashboard includes simulation data for demonstration purposes. In production, replace mock data generators with actual bot operation integrations.