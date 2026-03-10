#!/usr/bin/env bash
# install-as-service-macos.sh — Install GoClaw gateway + web UI as launchd services (macOS).
#
# Usage:
#   ./install-as-service-macos.sh                      # auto-detect user & paths
#   ./install-as-service-macos.sh --dir /opt/goclaw     # specify project directory
#   ./install-as-service-macos.sh --ui-port 3000        # UI listen port (default 3000)
#   ./install-as-service-macos.sh --no-ui               # skip UI service
#
# Prerequisites:
#   - Built binary (./goclaw) in project directory
#   - .env.local or .env with required environment variables
#   - For UI: pnpm, node, and nginx (brew install nginx)

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
SERVICE_USER="$(whoami)"
UI_PORT=3000
INSTALL_UI=true
ENV_FILE=""

PLIST_DIR="$HOME/Library/LaunchAgents"
GW_LABEL="com.goclaw.gateway"
GW_PLIST="$PLIST_DIR/$GW_LABEL.plist"
LOG_DIR="$HOME/Library/Logs/goclaw"

# ── Parse arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
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

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: This script is for macOS only. Use install-as-service-linux.sh on Linux."
    exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
BINARY="$PROJECT_DIR/goclaw"

if [[ ! -x "$BINARY" ]]; then
    echo "Error: Binary not found at $BINARY"
    echo "       Run 'make build' first."
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
    if ! command -v pnpm &>/dev/null; then
        echo "Error: pnpm not found. Install it or use --no-ui to skip the UI service."
        exit 1
    fi
    if ! command -v nginx &>/dev/null; then
        echo "Error: nginx not found. Install it (brew install nginx) or use --no-ui."
        exit 1
    fi
fi

# ── Load environment variables ───────────────────────────────────────────────
# Parse .env file into an array for the launchd plist EnvironmentVariables dict.

declare -A ENV_VARS
if [[ -n "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Strip surrounding quotes from value
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        ENV_VARS["$key"]="$value"
    done < "$ENV_FILE"
fi

# Determine gateway port
GW_PORT="${ENV_VARS[GOCLAW_PORT]:-18790}"

# ── Stop existing services ───────────────────────────────────────────────────

echo "Stopping existing services (if any)..."
launchctl bootout "gui/$(id -u)/$GW_LABEL" 2>/dev/null || true

# ── Build UI assets ──────────────────────────────────────────────────────────

UI_DIST="$PROJECT_DIR/ui/web/dist"

if $INSTALL_UI; then
    echo "Building UI assets..."
    (cd "$PROJECT_DIR/ui/web" && pnpm install --frozen-lockfile && pnpm build)

    if [[ ! -d "$UI_DIST" ]]; then
        echo "Error: UI build failed — dist/ not found."
        exit 1
    fi
fi

# ── Generate gateway launchd plist ───────────────────────────────────────────

echo "Installing $GW_LABEL plist..."
mkdir -p "$PLIST_DIR" "$LOG_DIR"

# Build EnvironmentVariables XML block
ENV_XML=""
if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
    ENV_XML="    <key>EnvironmentVariables</key>
    <dict>"
    for key in "${!ENV_VARS[@]}"; do
        ENV_XML="$ENV_XML
      <key>$key</key>
      <string>${ENV_VARS[$key]}</string>"
    done
    ENV_XML="$ENV_XML
    </dict>"
fi

cat > "$GW_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$GW_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>

$ENV_XML

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>5</integer>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/gateway.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/gateway.err.log</string>
</dict>
</plist>
EOF

# ── Generate nginx config for UI ────────────────────────────────────────────

if $INSTALL_UI; then
    echo "Installing goclaw-ui nginx config..."

    # Detect Homebrew nginx paths
    if [[ -d "/opt/homebrew/etc/nginx/servers" ]]; then
        NGINX_SERVERS="/opt/homebrew/etc/nginx/servers"
    elif [[ -d "/usr/local/etc/nginx/servers" ]]; then
        NGINX_SERVERS="/usr/local/etc/nginx/servers"
    else
        echo "Error: Cannot find Homebrew nginx servers directory."
        echo "       Expected /opt/homebrew/etc/nginx/servers or /usr/local/etc/nginx/servers"
        exit 1
    fi

    cat > "$NGINX_SERVERS/goclaw-ui.conf" <<NGINX
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
        proxy_pass http://127.0.0.1:$GW_PORT;
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
        proxy_pass http://127.0.0.1:$GW_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Health check proxy
    location /health {
        proxy_pass http://127.0.0.1:$GW_PORT;
    }

    # SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX

    # Validate nginx config
    if ! nginx -t 2>/dev/null; then
        echo "Error: nginx config validation failed. Check $NGINX_SERVERS/goclaw-ui.conf"
        exit 1
    fi
fi

# ── Load and start ───────────────────────────────────────────────────────────

echo "Loading gateway service..."
launchctl bootstrap "gui/$(id -u)" "$GW_PLIST"

if $INSTALL_UI; then
    echo "Starting nginx..."
    brew services restart nginx 2>/dev/null || {
        # Fallback: start nginx directly if brew services isn't available
        nginx -s reload 2>/dev/null || nginx
    }
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════"
echo "  GoClaw services installed successfully"
echo "══════════════════════════════════════════════"
echo ""
echo "  Gateway plist: $GW_PLIST"
echo "  Gateway logs:  $LOG_DIR/gateway.log"
echo "  Gateway errs:  $LOG_DIR/gateway.err.log"
if $INSTALL_UI; then
echo "  UI:            http://localhost:$UI_PORT"
echo "  nginx config:  $NGINX_SERVERS/goclaw-ui.conf"
fi
echo ""
echo "  Commands:"
echo "    launchctl kickstart -k gui/$(id -u)/$GW_LABEL   # restart gateway"
echo "    launchctl bootout gui/$(id -u)/$GW_LABEL         # stop gateway"
echo "    launchctl bootstrap gui/$(id -u) $GW_PLIST       # start gateway"
echo "    tail -f $LOG_DIR/gateway.log                     # tail logs"
if $INSTALL_UI; then
echo "    brew services restart nginx                       # restart nginx"
fi
echo ""
