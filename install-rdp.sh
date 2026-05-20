#!/usr/bin/env bash
# install-rdp.sh — One-shot installer for xrdp + xfce4 + start-rdp management script
# Run as a user with sudo privileges:
#   chmod +x install-rdp.sh && sudo ./install-rdp.sh

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/rdp"
SCRIPT_NAME="start-rdp.sh"
SYMLINK="/usr/local/bin/start-rdp"
SERVICE_NAME="xrdp-autostart"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SUDOERS_FILE="/etc/sudoers.d/rdp-autostart"
LOG_FILE="/var/log/start-rdp.log"
DEFAULT_PORT=3389

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[✅ INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[⚠️  WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[❌ ERROR]${NC} $*"; }
log_section() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  $*${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Must run as root ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log_error "This installer must be run as root: sudo ./install-rdp.sh"
  exit 1
fi

# ── Detect calling user ────────────────────────────────────────────────────
CALLING_USER="${SUDO_USER:-$USER}"
CALLING_HOME=$(getent passwd "$CALLING_USER" | cut -d: -f6)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  xRDP Auto-start Installer v2"
echo "  Ubuntu 22.04 — xfce4 + xrdp"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Installing for user: $CALLING_USER ($CALLING_HOME)"
log_info "Default RDP port:    $DEFAULT_PORT"
echo ""

# ── Pre-flight checks ──────────────────────────────────────────────────────
log_section "Pre-flight: Checking system"

# Check Ubuntu version
DISTRO=$(lsb_release -is 2>/dev/null || echo "Unknown")
RELEASE=$(lsb_release -cs 2>/dev/null || echo "Unknown")
if [[ "$DISTRO" != "Ubuntu" ]]; then
  log_warn "This script is designed for Ubuntu — detected: $DISTRO"
else
  log_info "OS: $DISTRO $RELEASE"
fi

# Check internet connectivity
log_info "Checking internet connectivity..."
if ! curl -sf --max-time 5 http://archive.ubuntu.com > /dev/null 2>&1; then
  log_warn "Cannot reach archive.ubuntu.com — checking DNS..."
  if ! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
    log_error "No internet connectivity detected. Package install will likely fail."
    log_error "Check your network connection and try again."
    exit 1
  else
    log_warn "Network is up but archive.ubuntu.com may be slow — continuing..."
  fi
else
  log_info "Internet connectivity: OK"
fi

# Check and fix apt sources
log_info "Checking apt sources..."
ACTIVE_SOURCES=$(grep -c "^deb http" /etc/apt/sources.list 2>/dev/null || echo "0")

if [[ "$ACTIVE_SOURCES" -eq 0 ]]; then
  log_warn "No active apt sources found — all entries appear commented out"
  log_info "Enabling standard Ubuntu $RELEASE repositories..."

  # Uncomment deb lines only (skip deb-src — not needed)
  sed -i 's/^# deb http/deb http/g' /etc/apt/sources.list

  # Re-check
  ACTIVE_SOURCES=$(grep -c "^deb http" /etc/apt/sources.list 2>/dev/null || echo "0")
  if [[ "$ACTIVE_SOURCES" -eq 0 ]]; then
    log_error "Failed to enable apt sources. Check /etc/apt/sources.list manually."
    exit 1
  fi
  log_info "Enabled $ACTIVE_SOURCES apt source entries"
else
  log_info "Active apt sources: $ACTIVE_SOURCES entries found"
fi

# Remove any stale local file:/ apt sources
if grep -q "^deb file:" /etc/apt/sources.list 2>/dev/null; then
  log_warn "Found local file:/ apt source — removing stale entry..."
  sed -i '/^deb file:/d' /etc/apt/sources.list
  log_info "Removed stale file:/ apt source"
fi

# Check for stale /apt directory
if [[ -d /apt ]] && [[ -z "$(ls -A /apt 2>/dev/null)" ]]; then
  log_warn "Found empty /apt directory — removing..."
  rm -rf /apt
  log_info "Removed empty /apt directory"
fi

# ── Step 1: System update + package install ────────────────────────────────
log_section "Step 1: Installing packages"

log_info "Running apt update..."
if ! apt-get update 2>&1; then
  log_error "apt update failed — check sources.list and network connectivity"
  exit 1
fi

log_info "Installing xrdp, xfce4, and dependencies..."
PACKAGES=(xrdp xfce4 xfce4-goodies xorgxrdp)

# dbus-x11 was removed in newer Ubuntu — only install if available
if apt-cache show dbus-x11 &>/dev/null; then
  PACKAGES+=(dbus-x11)
  log_info "dbus-x11 available — adding to install list"
else
  log_warn "dbus-x11 not available in this release — skipping (not required)"
fi

if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}" 2>&1; then
  log_error "Package installation failed — see output above for details"
  exit 1
fi

# Verify xrdp actually installed
if ! dpkg -l xrdp 2>/dev/null | grep -q "^ii"; then
  log_error "xrdp does not appear to be installed after apt-get — aborting"
  exit 1
fi

log_info "All packages installed successfully"

# ── Step 2: Configure xfce4 as default session ────────────────────────────
log_section "Step 2: Configuring xfce4 session"

if [[ ! -f /etc/xrdp/startwm.sh ]]; then
  log_error "/etc/xrdp/startwm.sh not found — xrdp may not have installed correctly"
  log_error "Try: sudo apt install --reinstall xrdp"
  exit 1
fi

cat > /etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh
log_info "Set xfce4 as default xrdp session"

cat > "$CALLING_HOME/.xsession" << 'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec xfce4-session
EOF
chmod +x "$CALLING_HOME/.xsession"
chown "$CALLING_USER:$CALLING_USER" "$CALLING_HOME/.xsession"
log_info "Created $CALLING_HOME/.xsession"

# ── Step 3: xrdp permissions ───────────────────────────────────────────────
log_section "Step 3: Configuring xrdp permissions"

usermod -aG ssl-cert xrdp 2>/dev/null || true
usermod -aG ssl-cert "$CALLING_USER" 2>/dev/null || true
log_info "Added xrdp and $CALLING_USER to ssl-cert group"

# ── Step 4: Fix xrdp.ini port value ───────────────────────────────────────
log_section "Step 4: Normalizing xrdp.ini port"

XRDP_CONFIG="/etc/xrdp/xrdp.ini"

# Extract raw port value
RAW_PORT=$(grep -E '^port=' "$XRDP_CONFIG" 2>/dev/null \
  | head -n1 \
  | cut -d= -f2 \
  | tr -d '[:space:]' \
  || echo "")

# Normalize — strip any non-numeric suffixes (e.g. "3389-1-1ask5900ask3389")
CLEAN_PORT=$(echo "$RAW_PORT" | grep -oE '^[0-9]+' || echo "3389")

if [[ "$RAW_PORT" != "$CLEAN_PORT" ]]; then
  log_warn "Non-standard port value found in xrdp.ini: '$RAW_PORT'"
  log_info "Normalizing to: $CLEAN_PORT"
  # Only update the [Globals] port line, not session-type port lines
  sed -i "0,/^port=/{s/^port=.*/port=$CLEAN_PORT/}" "$XRDP_CONFIG"
else
  log_info "xrdp.ini port value is clean: $CLEAN_PORT"
fi

# Ensure [Xorg] section uses port=-1 (sesman dynamic assignment)
if grep -q '^\[Xorg\]' "$XRDP_CONFIG"; then
  sed -i '/^\[Xorg\]/,/^\[/{s/^port=.*/port=-1/}' "$XRDP_CONFIG"
  log_info "xrdp.ini [Xorg] port set to -1 (sesman dynamic)"
fi

# Ensure sesman listens on IPv6 to match xrdp's internal connection
if [[ -f /etc/xrdp/sesman.ini ]]; then
  sed -i 's/^ListenAddress=.*/ListenAddress=::/' /etc/xrdp/sesman.ini
  log_info "sesman.ini ListenAddress set to :: (IPv6)"
fi

# ── Step 5: Install start-rdp.sh ──────────────────────────────────────────
log_section "Step 5: Installing start-rdp script"

mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/start-rdp.sh" ]]; then
  cp "$SCRIPT_DIR/start-rdp.sh" "$INSTALL_DIR/$SCRIPT_NAME"
  log_info "Copied start-rdp.sh from $SCRIPT_DIR"
else
  log_error "start-rdp.sh not found in $SCRIPT_DIR"
  log_error "Make sure both install-rdp.sh and start-rdp.sh are in the same directory"
  exit 1
fi

chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
log_info "Installed $INSTALL_DIR/$SCRIPT_NAME"

# ── Step 6: Symlink ────────────────────────────────────────────────────────
log_section "Step 6: Creating symlink"

ln -sf "$INSTALL_DIR/$SCRIPT_NAME" "$SYMLINK"
log_info "Symlink created: $SYMLINK → $INSTALL_DIR/$SCRIPT_NAME"

# ── Step 7: Systemd service ────────────────────────────────────────────────
log_section "Step 7: Installing systemd service"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=xRDP Auto-start with RFC1918 IP detection
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_DIR/$SCRIPT_NAME --wait
ExecReload=$INSTALL_DIR/$SCRIPT_NAME --restart
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
log_info "Systemd service installed and enabled: $SERVICE_NAME"

# ── Step 8: Sudoers ────────────────────────────────────────────────────────
log_section "Step 8: Configuring sudoers"

cat > "$SUDOERS_FILE" << EOF
# Allow sudo group to run start-rdp without password prompt
%sudo ALL=(ALL) NOPASSWD: $INSTALL_DIR/$SCRIPT_NAME
EOF

chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" \
  && log_info "Sudoers entry validated and installed" \
  || { log_error "Sudoers file invalid — removing"; rm -f "$SUDOERS_FILE"; }

# ── Step 9: Log file ───────────────────────────────────────────────────────
log_section "Step 9: Setting up log file"

touch "$LOG_FILE"
chmod 664 "$LOG_FILE"
log_info "Log file ready: $LOG_FILE"

# ── Step 10: Enable and start xrdp ────────────────────────────────────────
log_section "Step 10: Enabling and starting xrdp"

systemctl enable xrdp
systemctl start xrdp
sleep 2

if systemctl is-active --quiet xrdp; then
  log_info "xrdp is running"
else
  log_warn "xrdp did not start — check: sudo journalctl -u xrdp -n 50"
fi

# ── Step 11: Initial run ───────────────────────────────────────────────────
log_section "Step 11: Running initial IP detection"

"$INSTALL_DIR/$SCRIPT_NAME" || {
  log_warn "No RFC1918 IP detected yet — run 'sudo start-rdp --wait' once network is up"
}

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation Complete ✅"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Script    : $SYMLINK"
echo "  Service   : $SERVICE_NAME"
echo "  Log       : $LOG_FILE"
echo "  Config    : $XRDP_CONFIG"
echo ""
echo "  Quick commands:"
echo "  sudo start-rdp --status"
echo "  sudo start-rdp --restart"
echo "  sudo start-rdp --wait"
echo "  sudo start-rdp --port 3390"
echo "  sudo journalctl -u xrdp-autostart -f"
echo "  tail -f /var/log/start-rdp.log"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
