package protection

import (
    "bytes"
    "context"
    "encoding/json"
    "errors"
    "net/http"
    "strings"
    "time"

    "github.com/agentwise/walmart-bot/internal/tlsclient"
    "github.com/sirupsen/logrus"
)

// PXSolver integrates with ProtoDirect PX API to acquire and refresh PX artifacts
// (x-px-authorization header, _px3 cookie, vid/sid) and provides helpers to
// attach them to the tlsclient session and recover from PX blocks.
type PXSolver struct {
    apiKey   string
    apiBase  string
    logger   *logrus.Logger
    client   *http.Client

    // cached artifacts
    vid        string
    sid        string
    px3        string
    expiresAt  time.Time
    lastUpdate time.Time
}

func NewPXSolver(apiKey string, logger *logrus.Logger) *PXSolver {
    apiKey = strings.TrimSpace(apiKey)
    if apiKey == "" {
        return nil
    }
    if logger == nil {
        logger = logrus.New()
    }
    return &PXSolver{
        apiKey:  apiKey,
        apiBase: "https://api.parallaxsystems.io",
        logger:  logger,
        client:  &http.Client{Timeout: 15 * time.Second},
    }
}

// AttachToSession ensures valid PX artifacts and attaches them to the session.
// If ProtoDirect is unreachable or returns an error, it degrades gracefully and
// leaves any existing placeholder values intact.
func (p *PXSolver) AttachToSession(s *tlsclient.Session) {
    if p == nil || s == nil { return }

    // If cached artifacts are missing or expired, refresh them.
    if !p.hasValidArtifacts() {
        if err := p.refreshArtifacts(context.Background()); err != nil {
            p.logger.Debugf("PX refresh failed (degraded mode): %v", err)
            // Best-effort: attach at least the auth header so upstream services
            // that validate presence can proceed; cookie remains as-is.
            s.AddPXHeader("x-px-authorization", p.apiKey)
            return
        }
    }

    // Attach artifacts
    if p.apiKey != "" {
        s.AddPXHeader("x-px-authorization", p.apiKey)
    }
    if p.vid != "" { s.AddPXCookie("_pxvid", p.vid) }
    if p.sid != "" { s.AddPXCookie("_pxsid", p.sid) }
    if p.px3 != "" { s.AddPXCookie("_px3", p.px3) }
}

// IsPXBlocked performs lightweight heuristics on a response to detect PX blocks.
// Call this after requests that may be subject to PX (auth, checkout, inventory).
func (p *PXSolver) IsPXBlocked(resp *tlsclient.Response) bool {
    if resp == nil { return false }
    if resp.StatusCode == 403 { return true }
    // Heuristics: common header/body indicators used by PX protections
    if v := resp.Headers.Get("x-px-blocked"); strings.EqualFold(v, "1") { return true }
    body := strings.ToLower(resp.Body)
    if strings.Contains(body, "_px3") || strings.Contains(body, "perimeterx") || strings.Contains(body, "_px") {
        return true
    }
    return false
}

// RecoverIfBlocked attempts artifact refresh and returns true when recovery likely succeeded.
func (p *PXSolver) RecoverIfBlocked(s *tlsclient.Session) bool {
    if p == nil || s == nil { return false }
    if err := p.refreshArtifacts(context.Background()); err != nil {
        p.logger.Debugf("PX recovery failed: %v", err)
        return false
    }
    p.AttachToSession(s)
    return true
}

// hasValidArtifacts returns true if PX artifacts are present and not expired.
func (p *PXSolver) hasValidArtifacts() bool {
    if p.px3 == "" { return false }
    if p.expiresAt.IsZero() { return false }
    // Refresh a bit earlier than actual expiry to avoid edge races
    return time.Now().Add(30 * time.Second).Before(p.expiresAt)
}

// refreshArtifacts calls ProtoDirect to acquire fresh PX artifacts.
// NOTE: The exact ProtoDirect PX endpoints may differ; this implementation
// uses a conservative POST to /px/bootstrap as a placeholder. It degrades
// gracefully if the API is unavailable.
func (p *PXSolver) refreshArtifacts(ctx context.Context) error {
    if p == nil { return errors.New("nil PXSolver") }

    // Build request
    payload := map[string]any{
        "integration": "walmart-web",
        "capabilities": []string{"px3","vid","sid"},
    }
    body, _ := json.Marshal(payload)
    req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(p.apiBase, "/")+"/px/bootstrap", bytes.NewReader(body))
    if err != nil { return err }
    req.Header.Set("Content-Type", "application/json")
    // Per prompt: use apiKey as bearer/proprietary header; keep token out of logs
    req.Header.Set("x-auth-token", p.apiKey)

    // Execute
    resp, err := p.client.Do(req)
    if err != nil { return err }
    defer resp.Body.Close()

    // Parse response
    var out struct {
        Success   bool      `json:"success"`
        VID       string    `json:"vid"`
        SID       string    `json:"sid"`
        PX3       string    `json:"px3"`
        ExpiresIn int       `json:"expiresIn"`
        ExpiresAt time.Time `json:"expiresAt"`
        Message   string    `json:"message"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
        return err
    }
    if resp.StatusCode < 200 || resp.StatusCode >= 300 || !out.Success {
        if out.Message != "" {
            return errors.New(out.Message)
        }
        return errors.New("px bootstrap failed")
    }

    // Compute expiry
    var exp time.Time
    if !out.ExpiresAt.IsZero() {
        exp = out.ExpiresAt
    } else if out.ExpiresIn > 0 {
        exp = time.Now().Add(time.Duration(out.ExpiresIn) * time.Second)
    } else {
        // default short TTL if unspecified
        exp = time.Now().Add(10 * time.Minute)
    }

    // Cache
    p.vid = strings.TrimSpace(out.VID)
    p.sid = strings.TrimSpace(out.SID)
    p.px3 = strings.TrimSpace(out.PX3)
    p.expiresAt = exp
    p.lastUpdate = time.Now()
    return nil
}

