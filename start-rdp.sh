#!/usr/bin/env bash
# start-rdp.sh — Detect RFC1918 IP, manage xrdp, configure firewall
# Usage: ./start-rdp.sh [--restart] [--wait] [--port <PORT>] [--status]
#   --restart      : force restart xrdp even if already running
#   --wait         : keep retrying until an RFC1918 IP is found
#   --port <PORT>  : use a custom RDP port (default: 3389)
#   --status       : show current connection info without restarting

set -euo pipefail

RDP_PORT=3389
RETRY_INTERVAL=10
MAX_RETRIES=30
LOG_FILE="/var/log/start-rdp.log"
XRDP_CONFIG="/etc/xrdp/xrdp.ini"
IP_CACHE="/var/run/xrdp-server-ip"

# ── Parse arguments ────────────────────────────────────────────────────────
FORCE_RESTART=false
WAIT_FOR_IP=false
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --restart) FORCE_RESTART=true; shift ;;
    --wait)    WAIT_FOR_IP=true;   shift ;;
    --status)  STATUS_ONLY=true;   shift ;;
    --port)
      if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
        echo "❌ --port requires a numeric argument (e.g. --port 3390)"
        exit 1
      fi
      if [[ "$2" -lt 1024 || "$2" -gt 65535 ]]; then
        echo "❌ Port must be between 1024 and 65535"
        exit 1
      fi
      RDP_PORT="$2"
      shift 2
      ;;
    --help)
      echo ""
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --restart        Force restart xrdp even if already running"
      echo "  --wait           Retry until an RFC1918 IP is found (useful at boot)"
      echo "  --port <PORT>    Custom RDP port (default: 3389, range: 1024-65535)"
      echo "  --status         Show current connection info without restarting"
      echo "  --help           Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                          # Start with defaults"
      echo "  $0 --status                 # Show current status only"
      echo "  $0 --port 3390              # Use custom port"
      echo "  $0 --restart --port 3390    # Restart on custom port"
      echo "  $0 --wait --port 3390       # Wait for IP, use custom port"
      exit 0
      ;;
    *)
      echo "❌ Unknown option: $1  (use --help for usage)"
      exit 1
      ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────────────────
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

get_rfc1918_ip() {
  ip -4 addr show \
    | awk '/inet / {print $2}' \
    | cut -d/ -f1 \
    | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
    | head -n1
}

# Normalize port value from xrdp.ini — strips non-numeric suffixes
# e.g. "3389-1-1ask5900ask3389" → "3389"
get_current_port() {
  local raw
  raw=$(grep -E '^port=' "$XRDP_CONFIG" 2>/dev/null \
    | head -n1 \
    | cut -d= -f2 \
    | tr -d '[:space:]' \
    || echo "3389")
  # Extract only the leading numeric portion
  echo "$raw" | grep -oE '^[0-9]+' || echo "3389"
}

print_connection_info() {
  local ip="$1"
  local port="$2"
  local status="$3"
  local uptime="$4"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  RDP Server Status"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Server IP   : $ip"
  echo "  Port        : $port"
  echo "  xrdp status : $status"
  echo "  Uptime      : $uptime"
  echo "  Log file    : $LOG_FILE"
  echo ""
  echo "  Client Connection Commands:"
  echo "  Windows : mstsc /v:$ip:$port"
  echo "  macOS   : Add PC in Microsoft Remote Desktop"
  echo "            Host: $ip:$port"
  echo "  Linux   : xfreerdp /v:$ip /port:$port"
  echo ""
  echo "  On-demand commands:"
  echo "  sudo start-rdp --status"
  echo "  sudo start-rdp --restart"
  echo "  sudo start-rdp --wait"
  echo "  sudo start-rdp --port 3390"
  echo "  sudo start-rdp --restart --port 3390"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ── STATUS ONLY ────────────────────────────────────────────────────────────
if [[ "$STATUS_ONLY" == true ]]; then
  log "📋 Status check requested (no restart)"

  if [[ -f "$IP_CACHE" ]]; then
    CACHED=$(cat "$IP_CACHE")
    CACHED_IP=$(echo "$CACHED" | cut -d: -f1)
    CACHED_PORT=$(echo "$CACHED" | cut -d: -f2)
  else
    CACHED_IP="unknown (not yet started)"
    CACHED_PORT="unknown"
  fi

  if systemctl is-active --quiet xrdp; then
    XRDP_STATUS="active ✅"
  else
    XRDP_STATUS="inactive ❌"
  fi

  XRDP_UPTIME=$(systemctl show xrdp --property=ActiveEnterTimestamp \
    | cut -d= -f2 \
    | xargs -I{} bash -c 'echo "since {}"' 2>/dev/null || echo "unknown")

  LIVE_IP=$(get_rfc1918_ip || echo "")

  if [[ -z "$LIVE_IP" ]]; then
    log "⚠️  No RFC1918 IP currently detected on any interface"
    LIVE_IP="none detected ⚠️"
  fi

  if [[ "$LIVE_IP" != "$CACHED_IP" && "$LIVE_IP" != "none detected ⚠️" ]]; then
    log "⚠️  Live IP ($LIVE_IP) differs from cached IP ($CACHED_IP)"
    log "   Run 'sudo start-rdp --restart' to update"
    CACHED_IP="$LIVE_IP (changed — restart recommended)"
  fi

  print_connection_info "$CACHED_IP" "$CACHED_PORT" "$XRDP_STATUS" "$XRDP_UPTIME"
  exit 0
fi

# ── Wait loop ──────────────────────────────────────────────────────────────
RFC1918_IP=""
attempt=1

while true; do
  RFC1918_IP=$(get_rfc1918_ip)

  if [[ -n "$RFC1918_IP" ]]; then
    log "✅ RFC1918 IP found: $RFC1918_IP"
    break
  fi

  if [[ "$WAIT_FOR_IP" == false ]]; then
    log "❌ No RFC1918 address found. Is the server connected to a switch/network?"
    log "   Tip: run with --wait to keep retrying, or check 'ip addr'"
    exit 1
  fi

  if [[ $attempt -ge $MAX_RETRIES ]]; then
    log "❌ Gave up after $MAX_RETRIES attempts ($((MAX_RETRIES * RETRY_INTERVAL))s)."
    exit 1
  fi

  log "⏳ Attempt $attempt/$MAX_RETRIES — no RFC1918 IP yet. Retrying in ${RETRY_INTERVAL}s..."
  sleep "$RETRY_INTERVAL"
  ((attempt++))
done

# ── Port config — normalized ───────────────────────────────────────────────
CURRENT_PORT=$(get_current_port)

if [[ "$RDP_PORT" != "$CURRENT_PORT" ]]; then
  log "🔧 Updating xrdp port: $CURRENT_PORT → $RDP_PORT"
  # Only update the first (global) port= line, not session-type sections
  sed -i "0,/^port=/{s/^port=.*/port=$RDP_PORT/}" "$XRDP_CONFIG"
  # Ensure [Xorg] stays at -1 for sesman dynamic port assignment
  sed -i '/^\[Xorg\]/,/^\[/{s/^port=.*/port=-1/}' "$XRDP_CONFIG"
  FORCE_RESTART=true
else
  log "🔧 xrdp port: $RDP_PORT — no change needed"
fi

# ── Firewall ───────────────────────────────────────────────────────────────
log "🔒 Configuring firewall for port $RDP_PORT..."
if command -v ufw &>/dev/null; then
  if [[ "$RDP_PORT" != "$CURRENT_PORT" ]]; then
    if ufw status | grep -q "${CURRENT_PORT}/tcp"; then
      ufw delete allow "${CURRENT_PORT}/tcp" >> "$LOG_FILE" 2>&1
      log "   ufw: removed old rule for port $CURRENT_PORT"
    fi
  fi
  if ! ufw status | grep -q "${RDP_PORT}/tcp"; then
    ufw allow "${RDP_PORT}/tcp" >> "$LOG_FILE" 2>&1
    log "   ufw: rule added for port $RDP_PORT"
  else
    log "   ufw: rule already exists for port $RDP_PORT"
  fi
else
  log "   ⚠️  ufw not found — skipping firewall config"
fi

# ── xrdp service ───────────────────────────────────────────────────────────
if [[ "$FORCE_RESTART" == true ]]; then
  log "🔄 Restarting xrdp..."
  systemctl restart xrdp
elif systemctl is-active --quiet xrdp; then
  log "✅ xrdp is already running"
else
  log "⚙️  Starting xrdp..."
  systemctl start xrdp
fi

sleep 2
STATUS=$(systemctl is-active xrdp)

if [[ "$STATUS" != "active" ]]; then
  log "❌ xrdp failed to start. Check: sudo journalctl -u xrdp -n 50"
  exit 1
fi

# ── Cache IP:PORT ──────────────────────────────────────────────────────────
echo "$RFC1918_IP:$RDP_PORT" | tee "$IP_CACHE" > /dev/null

XRDP_UPTIME=$(systemctl show xrdp --property=ActiveEnterTimestamp \
  | cut -d= -f2 \
  | xargs -I{} bash -c 'echo "since {}"' 2>/dev/null || echo "just started")

print_connection_info "$RFC1918_IP" "$RDP_PORT" "$STATUS ✅" "$XRDP_UPTIME"

log "✅ RDP server ready at $RFC1918_IP:$RDP_PORT"
