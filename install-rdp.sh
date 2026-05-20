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
log_section() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
                echo -e "${BLUE}  $*${NC}"; \
                echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Must run as root ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log_error "This installer must be run as root: sudo ./install-rdp.sh"
  exit 1
fi

# ── Detect calling user ────────────────────────────────────────────────────
CALLING_USER="${SUDO_USER:-$USER}"
CALLING_HOME=$(getent passwd "$CALLING_USER" | cut -d: -f6)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         xRDP Auto-start Installer                   ║"
echo "║         Ubuntu 22.04 — xfce4 + xrdp                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
log_info "Installing for user: $CALLING_USER ($CALLING_HOME)"
log_info "Default RDP port:    $DEFAULT_PORT"
echo ""

# ── Step 1: Packages ───────────────────────────────────────────────────────
log_section "Step 1: Installing packages"
apt-get update -qq
apt-get install -y \
  xrdp \
  xfce4 \
  xfce4-goodies \
  dbus-x11 \
  xorgxrdp 2>&1 | grep -E '(Installing|already|error)' || true
log_info "Packages installed"

# ── Step 2: xfce4 session ─────────────────────────────────────────────────
log_section "Step 2: Configuring xfce4 session"

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

# ── Step 3: Permissions ────────────────────────────────────────────────────
log_section "Step 3: Configuring xrdp permissions"
usermod -aG ssl-cert xrdp 2>/dev/null || true
usermod -aG ssl-cert "$CALLING_USER" 2>/dev/null || true
log_info "Added xrdp and $CALLING_USER to ssl-cert group"

# ── Step 4: Install start-rdp.sh ──────────────────────────────────────────
log_section "Step 4: Installing start-rdp script"

mkdir -p "$INSTALL_DIR"

# Copy start-rdp.sh from the same directory as this installer
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/start-rdp.sh" ]]; then
  cp "$SCRIPT_DIR/start-rdp.sh" "$INSTALL_DIR/$SCRIPT_NAME"
  log_info "Copied start-rdp.sh from $SCRIPT_DIR"
else
  log_error "start-rdp.sh not found in $SCRIPT_DIR — make sure both files are in the same directory"
  exit 1
fi

chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
log_info "Installed $INSTALL_DIR/$SCRIPT_NAME"

# ── Step 5: Symlink ────────────────────────────────────────────────────────
log_section "Step 5: Creating symlink"
ln -sf "$INSTALL_DIR/$SCRIPT_NAME" "$SYMLINK"
log_info "Symlink created: $SYMLINK → $INSTALL_DIR/$SCRIPT_NAME"

# ── Step 6: Systemd service ────────────────────────────────────────────────
log_section "Step 6: Installing systemd service"

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

# ── Step 7: Sudoers ────────────────────────────────────────────────────────
log_section "Step 7: Configuring sudoers"

cat > "$SUDOERS_FILE" << EOF
# Allow sudo group to run start-rdp without password prompt
%sudo ALL=(ALL) NOPASSWD: $INSTALL_DIR/$SCRIPT_NAME
EOF

chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" && log_info "Sudoers entry validated and installed" \
  || { log_error "Sudoers file invalid — removing"; rm -f "$SUDOERS_FILE"; }

# ── Step 8: Log file ───────────────────────────────────────────────────────
log_section "Step 8: Setting up log file"
touch "$LOG_FILE"
chmod 664 "$LOG_FILE"
log_info "Log file ready: $LOG_FILE"

# ── Step 9: Enable and start xrdp ─────────────────────────────────────────
log_section "Step 9: Enabling and starting xrdp"
systemctl enable xrdp
systemctl start xrdp
sleep 2

if systemctl is-active --quiet xrdp; then
  log_info "xrdp is running"
else
  log_warn "xrdp did not start — check: sudo journalctl -u xrdp -n 50"
fi

# ── Step 10: Initial run ───────────────────────────────────────────────────
log_section "Step 10: Running initial IP detection"
"$INSTALL_DIR/$SCRIPT_NAME" || {
  log_warn "No RFC1918 IP detected yet — run 'sudo start-rdp --wait' once network is up"
}

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║           Installation Complete ✅                  ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Script    : %-39s║\n" "$SYMLINK"
printf "║  Service   : %-39s║\n" "$SERVICE_NAME"
printf "║  Log       : %-39s║\n" "$LOG_FILE"
printf "║  Config    : %-39s║\n" "/etc/xrdp/xrdp.ini"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Quick commands:                                     ║"
printf "║  %-51s║\n" "sudo start-rdp --status"
printf "║  %-51s║\n" "sudo start-rdp --restart"
printf "║  %-51s║\n" "sudo start-rdp --wait"
printf "║  %-51s║\n" "sudo start-rdp --port 3390"
printf "║  %-51s║\n" "sudo journalctl -u xrdp-autostart -f"
printf "║  %-51s║\n" "tail -f /var/log/start-rdp.log"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
