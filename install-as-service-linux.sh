#!/usr/bin/env bash
# install-as-service-linux.sh — Install GoClaw gateway + web UI as systemd services (Linux).
#
# Usage:
#   sudo ./install-as-service-linux.sh                      # auto-detect user & paths
#   sudo ./install-as-service-linux.sh --user deploy         # specify user
#   sudo ./install-as-service-linux.sh --dir /opt/goclaw     # specify project directory
#   sudo ./install-as-service-linux.sh --ui-port 3000        # UI listen port (default 3000)
#   sudo ./install-as-service-linux.sh --no-ui               # skip UI service
#
# Prerequisites:
#   - Built binary (./goclaw) in project directory
#   - .env.local or .env with required environment variables
#   - For UI: node, npm, and nginx installed

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
SERVICE_USER="${SUDO_USER:-$(whoami)}"
UI_PORT=3000
INSTALL_UI=true
ENV_FILE=""

# ── Parse arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)    SERVICE_USER="$2"; shift 2 ;;
        --dir)     PROJECT_DIR="$2";  shift 2 ;;
        --ui-port) UI_PORT="$2";      shift 2 ;;
        --no-ui)   INSTALL_UI=false;   shift   ;;
        --help|-h)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Validation ───────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run with sudo."
    exit 1
fi

PROJECT_DIR="$(realpath "$PROJECT_DIR")"
BINARY="$PROJECT_DIR/goclaw"

if [[ ! -x "$BINARY" ]]; then
    echo "Error: Binary not found at $BINARY"
    echo "       Run 'make build' first."
    exit 1
fi

if ! id "$SERVICE_USER" &>/dev/null; then
    echo "Error: User '$SERVICE_USER' does not exist."
    exit 1
fi

# Find env file (.env.local preferred, fallback to .env)
if [[ -f "$PROJECT_DIR/.env.local" ]]; then
    ENV_FILE="$PROJECT_DIR/.env.local"
elif [[ -f "$PROJECT_DIR/.env" ]]; then
    ENV_FILE="$PROJECT_DIR/.env"
else
    echo "Warning: No .env.local or .env found. Service may fail without environment variables."
fi

if $INSTALL_UI; then
    if ! command -v npm &>/dev/null; then
        echo "Error: npm not found. Install it or use --no-ui to skip the UI service."
        exit 1
    fi
    if ! command -v nginx &>/dev/null; then
        echo "Error: nginx not found. Install it (e.g., sudo apt install nginx) or use --no-ui."
        exit 1
    fi
fi

# ── Stop existing services if running ────────────────────────────────────────

echo "Stopping existing services (if any)..."
systemctl stop goclaw.service 2>/dev/null || true
systemctl stop goclaw-ui.service 2>/dev/null || true

# ── Build UI assets ──────────────────────────────────────────────────────────

UI_DIST="$PROJECT_DIR/ui/web/dist"
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

if $INSTALL_UI; then
    echo "Building UI assets..."
    sudo -u "$SERVICE_USER" bash -c "cd '$PROJECT_DIR/ui/web' && npm ci && npm run build"

    if [[ ! -d "$UI_DIST" ]]; then
        echo "Error: UI build failed — dist/ not found."
        exit 1
    fi
fi

# ── Generate gateway systemd unit ────────────────────────────────────────────

echo "Installing goclaw.service..."

cat > /etc/systemd/system/goclaw.service <<EOF
[Unit]
Description=GoClaw Gateway
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$(id -gn "$SERVICE_USER")
WorkingDirectory=$PROJECT_DIR
$(if [[ -n "$ENV_FILE" ]]; then echo "EnvironmentFile=$ENV_FILE"; fi)
ExecStart=$BINARY
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$PROJECT_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# ── Generate nginx site config for UI ────────────────────────────────────────

if $INSTALL_UI; then
    echo "Installing goclaw-ui nginx config..."

    # Determine gateway address from env or default
    GW_HOST="127.0.0.1"
    GW_PORT="18790"
    if [[ -n "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        _port=$(grep -E '^GOCLAW_PORT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
        if [[ -n "${_port:-}" ]]; then GW_PORT="$_port"; fi
    fi

    mkdir -p "$NGINX_CONF_DIR" "$NGINX_ENABLED_DIR"

    cat > "$NGINX_CONF_DIR/goclaw-ui" <<NGINX
server {
    listen $UI_PORT;
    server_name _;

    root $UI_DIST;
    index index.html;

    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 256;

    # Cache static assets
    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # WebSocket proxy to gateway
    location /ws {
        proxy_pass http://$GW_HOST:$GW_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
    }

    # API proxy to gateway
    location /v1/ {
        proxy_pass http://$GW_HOST:$GW_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Health check proxy
    location /health {
        proxy_pass http://$GW_HOST:$GW_PORT;
    }

    # SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX

    # Enable site
    ln -sf "$NGINX_CONF_DIR/goclaw-ui" "$NGINX_ENABLED_DIR/goclaw-ui"

    # Remove default site if it conflicts on the same port
    if [[ -f "$NGINX_ENABLED_DIR/default" ]]; then
        echo "Note: nginx default site left in place. Remove it if port conflicts occur:"
        echo "      sudo rm $NGINX_ENABLED_DIR/default"
    fi

    # Validate nginx config
    if ! nginx -t 2>/dev/null; then
        echo "Error: nginx config validation failed. Check $NGINX_CONF_DIR/goclaw-ui"
        exit 1
    fi
fi

# ── Enable and start ─────────────────────────────────────────────────────────

echo "Reloading systemd..."
systemctl daemon-reload

echo "Enabling and starting goclaw.service..."
systemctl enable --now goclaw.service

if $INSTALL_UI; then
    echo "Restarting nginx..."
    systemctl enable --now nginx
    systemctl reload nginx
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════"
echo "  GoClaw services installed successfully"
echo "══════════════════════════════════════════════"
echo ""
echo "  Gateway:  systemctl status goclaw"
echo "  Logs:     journalctl -u goclaw -f"
if $INSTALL_UI; then
echo "  UI:       http://localhost:$UI_PORT"
echo "  nginx:    systemctl status nginx"
fi
echo ""
echo "  Commands:"
echo "    sudo systemctl stop goclaw        # stop gateway"
echo "    sudo systemctl restart goclaw     # restart gateway"
if $INSTALL_UI; then
echo "    sudo systemctl reload nginx       # reload UI config"
fi
echo ""
