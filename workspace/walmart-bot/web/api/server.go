package api

import (
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "sync/atomic"

    "github.com/agentwise/walmart-bot/internal/tlsclient"
    "github.com/sirupsen/logrus"
)

type Server struct {
    logger *logrus.Logger
    config interface{}
    srv    *http.Server
}

func NewServer(logger *logrus.Logger, config interface{}) *Server {
    return &Server{logger: logger, config: config}
}

func (s *Server) Start(ctx context.Context, port int) {
    mux := http.NewServeMux()

    // Basic CORS
    cors := func(next http.HandlerFunc) http.HandlerFunc {
        return func(w http.ResponseWriter, r *http.Request) {
            w.Header().Set("Access-Control-Allow-Origin", "*")
            w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
            w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            if r.Method == http.MethodOptions {
                w.WriteHeader(http.StatusNoContent)
                return
            }
            next.ServeHTTP(w, r)
        }
    }

    mux.HandleFunc("/api/status", cors(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(map[string]interface{}{
            "ok": true,
            "rateLimitMs": tlsclient.GetGlobalRateLimitMs(),
        })
    }))

    mux.HandleFunc("/api/rate-limit", cors(func(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost {
            w.WriteHeader(http.StatusMethodNotAllowed)
            return
        }
        var body struct{ Ms int `json:"ms"` }
        if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
            w.WriteHeader(http.StatusBadRequest)
            return
        }
        tlsclient.SetGlobalRateLimitMs(body.Ms)
        w.WriteHeader(http.StatusNoContent)
    }))

    // Stubs for additional endpoints to align with README
    mux.HandleFunc("/api/metrics", cors(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(map[string]interface{}{
            "requestsTotal": 0,
            "errorsTotal": 0,
        })
    }))

    mux.HandleFunc("/api/proxies", cors(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(map[string]interface{}{
            "total": 0,
            "working": 0,
            "failed": 0,
        })
    }))

    mux.HandleFunc("/api/orders", cors(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode([]interface{}{})
    }))

    mux.HandleFunc("/api/config", cors(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(s.config)
    }))

    s.srv = &http.Server{Addr: fmt.Sprintf(":%d", port), Handler: mux}

    go func() {
        <-ctx.Done()
        s.srv.Shutdown(context.Background())
    }()

    if err := s.srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
        atomic.AddUint32(new(uint32), 1) // no-op to keep import
        s.logger.Errorf("dashboard server error: %v", err)
    }
}



