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
SCREEN_LOCK_MINUTES=0    # 0 = disable screen lock entirely; set to minutes for a timeout

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
if [[ "$CALLING_USER" == "root" ]]; then
  log_error "Run this script with sudo, not as root directly:"
  log_error "  sudo ./install-rdp.sh"
  exit 1
fi
CALLING_HOME=$(getent passwd "$CALLING_USER" | cut -d: -f6)
if [[ -z "$CALLING_HOME" ]]; then
  log_error "Could not determine home directory for user: $CALLING_USER"
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  xRDP Auto-start Installer v2"
echo "  Ubuntu 22.04/24.04 — xfce4 + xrdp"
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

# Check SSH and login concurrency limits
# On STIG-hardened systems these can prevent SSH and RDP from being active simultaneously.
log_info "Checking SSH and PAM login concurrency limits..."

# MaxSessions: number of channels per SSH connection (multiplexing), not total connections.
# STIG often sets this to 1, which disables ControlMaster but does NOT block separate connections.
MAX_SESSIONS=$(grep -rihE '^MaxSessions[[:space:]]' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
  | awk '{print $2}' | tail -1 || echo "")
if [[ -z "$MAX_SESSIONS" ]]; then
  log_info "sshd MaxSessions: default (10) — parallel SSH connections OK"
elif [[ "$MAX_SESSIONS" -le 1 ]]; then
  log_warn "sshd MaxSessions=$MAX_SESSIONS — SSH multiplexing disabled; separate SSH connections still work"
else
  log_info "sshd MaxSessions=$MAX_SESSIONS — parallel SSH connections OK"
fi

# AllowUsers: if set, the calling user must be in the list or SSH login will be refused.
SSH_ALLOW_USERS=$(grep -rihE '^AllowUsers[[:space:]]' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
  | tail -1 | cut -d' ' -f2- || echo "")
if [[ -n "$SSH_ALLOW_USERS" ]]; then
  if echo " $SSH_ALLOW_USERS " | grep -qw "$CALLING_USER"; then
    log_info "sshd AllowUsers: $CALLING_USER is permitted ✅"
  else
    log_warn "sshd AllowUsers is set but may not include $CALLING_USER"
    log_warn "  AllowUsers: $SSH_ALLOW_USERS"
  fi
fi

# PAM maxlogins: hard cap on concurrent login sessions system-wide.
# If set to 1, SSH and RDP cannot be active at the same time — the second login is rejected.
MAXLOGINS_VAL=$(awk '!/^[[:space:]]*#/ && /maxlogins/ {print $NF}' \
  /etc/security/limits.conf 2>/dev/null | sort -n | head -1 || echo "")
if [[ -z "$MAXLOGINS_VAL" ]]; then
  log_info "PAM maxlogins: no limit set — SSH and RDP can run concurrently"
elif [[ "$MAXLOGINS_VAL" -le 1 ]]; then
  log_warn "PAM maxlogins=$MAXLOGINS_VAL — only 1 concurrent login session allowed!"
  log_warn "  SSH + RDP CANNOT be active at the same time with this setting"
  log_warn "  Fix: edit /etc/security/limits.conf and raise or remove the maxlogins line"
else
  log_info "PAM maxlogins=$MAXLOGINS_VAL — SSH and RDP can coexist"
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

# Polkit authentication agent — without one, GUI operations requiring elevation
# (network manager, package manager, disk mounts) fail silently in the xfce4 session
POLKIT_EXEC=""
if apt-cache show xfce-polkit &>/dev/null; then
  PACKAGES+=(xfce-polkit)
  POLKIT_EXEC="/usr/libexec/xfce-polkit"
  log_info "xfce-polkit available — adding to install list"
elif apt-cache show policykit-1-gnome &>/dev/null; then
  PACKAGES+=(policykit-1-gnome)
  POLKIT_EXEC="/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1"
  log_info "policykit-1-gnome available — adding to install list"
else
  log_warn "No polkit agent found — GUI operations requiring elevation may fail silently"
fi

# On Ubuntu 22.04 (jammy), Ubuntu Pro/ESM may pre-install libexo-2-0 at an ESM version
# that conflicts with xfce4's dependency on the base jammy version (4.16.3-1).
if [[ "$RELEASE" == "jammy" ]]; then
  LIBEXO_VER=$(dpkg-query -W -f='${Version}' libexo-2-0 2>/dev/null || true)
  if [[ "$LIBEXO_VER" == *esm* ]]; then
    log_warn "ESM version of libexo-2-0 detected ($LIBEXO_VER) — downgrading for xfce4 compatibility"
    LIBEXO_BASE=$(apt-cache policy libexo-2-0 2>/dev/null \
      | grep -E '^\s+[0-9]' | awk '{print $1}' | grep -v esm | head -1 || echo "")
    if [[ -n "$LIBEXO_BASE" ]]; then
      if ! apt-get install -y --allow-downgrades "libexo-2-0=$LIBEXO_BASE" 2>&1; then
        log_warn "libexo-2-0 downgrade to $LIBEXO_BASE failed — xfce4 install may fail"
      else
        log_info "libexo-2-0 downgraded to $LIBEXO_BASE"
      fi
    else
      log_warn "No non-ESM version of libexo-2-0 found in apt cache — xfce4 install may fail"
    fi
  fi
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

# lightdm: xfce4 pulls in lightdm as a display manager dependency. On a headless
# server it starts on VT7 and causes blank or failed RDP sessions.
if systemctl list-unit-files lightdm.service 2>/dev/null | grep -q 'lightdm'; then
  systemctl disable --now lightdm 2>/dev/null || true
  log_info "lightdm disabled — prevents VT conflict with xrdp on headless server"
else
  log_info "lightdm: not installed — no conflict"
fi

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

# Polkit autostart — ensures the authentication agent launches with the xfce4 session
if [[ -n "$POLKIT_EXEC" ]]; then
  AUTOSTART_DIR="$CALLING_HOME/.config/autostart"
  mkdir -p "$AUTOSTART_DIR"
  cat > "$AUTOSTART_DIR/polkit-agent.desktop" << EOF
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent
Exec=$POLKIT_EXEC
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  chown -R "$CALLING_USER:$CALLING_USER" "$AUTOSTART_DIR"
  log_info "Polkit agent autostart configured: $POLKIT_EXEC"
fi

# Stale xfce4 session cache causes a black screen on first RDP connect.
if [[ -d "$CALLING_HOME/.cache/sessions" ]]; then
  rm -rf "$CALLING_HOME/.cache/sessions"
  log_info "Cleared stale xfce4 session cache ($CALLING_HOME/.cache/sessions)"
fi

# ── Screen lock config ─────────────────────────────────────────────────────
log_section "Screen Lock: Configuring xfce4 screen timeout (${SCREEN_LOCK_MINUTES}min, 0=disabled)"

XFCE_CONF_DIR="$CALLING_HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$XFCE_CONF_DIR"

if [[ "$SCREEN_LOCK_MINUTES" -eq 0 ]]; then
  _LOCK_ON="false"
  _IDLE_DELAY=0
else
  _LOCK_ON="true"
  _IDLE_DELAY="$SCREEN_LOCK_MINUTES"
fi

# xfce4-screensaver: controls the lock screen and idle activation
cat > "$XFCE_CONF_DIR/xfce4-screensaver.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="$_LOCK_ON"/>
    <property name="mode" type="int" value="0"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="$_LOCK_ON"/>
      <property name="delay" type="int" value="$_IDLE_DELAY"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="$_LOCK_ON"/>
    <property name="saver-activation" type="empty">
      <property name="enabled" type="bool" value="$_LOCK_ON"/>
    </property>
  </property>
</channel>
XMLEOF

# xfce4-power-manager: disable screen blanking and DPMS (irrelevant for RDP but prevents blank surprise)
cat > "$XFCE_CONF_DIR/xfce4-power-manager.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="blank-on-ac" type="int" value="$_IDLE_DELAY"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
  </property>
</channel>
XMLEOF

# xfce4-panel: pre-seeding a panel config suppresses the first-run dialog that
# blocks the RDP session waiting for user input ("Use default panel configuration?")
cat > "$XFCE_CONF_DIR/xfce4-panel.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=2;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="28"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="tasklist"/>
    <property name="plugin-3" type="string" value="separator"/>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="clock"/>
    <property name="plugin-6" type="string" value="showdesktop"/>
  </property>
</channel>
XMLEOF
log_info "xfce4-panel config written — first-run dialog suppressed"

chown -R "$CALLING_USER:$CALLING_USER" "$CALLING_HOME/.config"

# Stop xrdp first so it releases its hold on the Xorg session before we kill
# the session processes. Killing xfce4-session while xrdp is still running
# leaves Xorg orphaned and causes xrdp to hang on the subsequent restart.
systemctl stop xrdp 2>/dev/null || true

# Now kill the user's xfce4 session so the next RDP connection starts fresh
# and reads the config we just wrote. Without this, xfconfd flushes its
# in-memory cache back to disk on exit, overwriting our xfce4-panel.xml.
_session_killed=false
pkill -KILL -u "$CALLING_USER" xfce4-session 2>/dev/null && _session_killed=true
pkill -KILL -u "$CALLING_USER" xfconfd      2>/dev/null || true
pkill -KILL -u "$CALLING_USER" xfce4-panel  2>/dev/null || true
pkill -KILL -u "$CALLING_USER" Xorg         2>/dev/null || true
if [[ "$_session_killed" == true ]]; then
  log_info "Stopped xrdp and killed xfce4 session — will start fresh on next connect"
else
  log_info "No active xfce4 session found"
fi

# ── Desktop icons ──────────────────────────────────────────────────────────
mkdir -p "$CALLING_HOME/Desktop"

# Terminal
if [[ -f /usr/share/applications/xfce4-terminal.desktop ]]; then
  cp /usr/share/applications/xfce4-terminal.desktop "$CALLING_HOME/Desktop/"
  chmod +x "$CALLING_HOME/Desktop/xfce4-terminal.desktop"
  log_info "Desktop icon: xfce4-terminal"
fi

# Web browser — Firefox (deb, snap, or ESM fallback)
_browser_found=false
for _f in \
  /usr/share/applications/firefox.desktop \
  /var/lib/snapd/desktop/applications/firefox_firefox.desktop \
  /usr/share/applications/firefox-esr.desktop; do
  if [[ -f "$_f" ]]; then
    cp "$_f" "$CALLING_HOME/Desktop/$(basename "$_f")"
    chmod +x "$CALLING_HOME/Desktop/$(basename "$_f")"
    log_info "Desktop icon: $(basename "$_f")"
    _browser_found=true
    break
  fi
done
[[ "$_browser_found" == false ]] && log_warn "No Firefox .desktop found — browser icon skipped"

chown -R "$CALLING_USER:$CALLING_USER" "$CALLING_HOME/Desktop"

if [[ "$SCREEN_LOCK_MINUTES" -eq 0 ]]; then
  log_info "Screen lock: DISABLED — screen will not lock on idle"
  log_warn "Re-run with SCREEN_LOCK_MINUTES=N to enable a timeout instead"
else
  log_info "Screen lock: timeout = ${SCREEN_LOCK_MINUTES} min (lock enabled)"
fi

# ── Step 3: xrdp permissions ───────────────────────────────────────────────
log_section "Step 3: Configuring xrdp permissions"

usermod -aG ssl-cert xrdp 2>/dev/null || true
usermod -aG ssl-cert "$CALLING_USER" 2>/dev/null || true
log_info "Added xrdp and $CALLING_USER to ssl-cert group"

# ── TLS Certificate ────────────────────────────────────────────────────────
log_section "TLS Certificate: Extending xrdp cert to 10 years"

# xrdp generates a 1-year self-signed cert on install. After a year all clients
# start warning or refusing. Regenerate now with a 10-year validity.
XRDP_CERT="/etc/xrdp/cert.pem"
XRDP_KEY="/etc/xrdp/key.pem"
if [[ -f "$XRDP_CERT" ]] && [[ -f "$XRDP_KEY" ]] && command -v openssl &>/dev/null; then
  CURRENT_EXPIRY=$(openssl x509 -enddate -noout -in "$XRDP_CERT" 2>/dev/null \
    | cut -d= -f2 || echo "unknown")
  log_info "Current cert expiry: $CURRENT_EXPIRY"
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$XRDP_KEY" \
    -out "$XRDP_CERT" \
    -days 3650 \
    -nodes \
    -subj "/CN=$(hostname)/O=xRDP/C=US" 2>/dev/null \
    && log_info "xrdp cert regenerated — valid 10 years from today" \
    || log_warn "Cert regeneration failed — keeping existing cert (expires: $CURRENT_EXPIRY)"
  chmod 640 "$XRDP_KEY"
  chmod 644 "$XRDP_CERT"
  chown root:ssl-cert "$XRDP_KEY" 2>/dev/null || true
else
  log_warn "xrdp cert/key not found or openssl missing — skipping cert extension"
fi

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

# Configure sesman ListenAddress — use :: (IPv6) if available, else 127.0.0.1.
# STIG hardening often disables IPv6; binding to :: on such a system silently
# prevents sesman from starting, which blocks all RDP session creation.
if [[ -f /etc/xrdp/sesman.ini ]]; then
  IPV6_DISABLED=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")
  if [[ "$IPV6_DISABLED" == "1" ]]; then
    log_warn "IPv6 is disabled — setting sesman ListenAddress=127.0.0.1"
    sed -i 's/^ListenAddress=.*/ListenAddress=127.0.0.1/' /etc/xrdp/sesman.ini
  else
    sed -i 's/^ListenAddress=.*/ListenAddress=::/' /etc/xrdp/sesman.ini
    log_info "sesman.ini ListenAddress set to :: (IPv6)"
  fi
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

# ── Step 9: PAM faillock ───────────────────────────────────────────────────
log_section "Step 9: PAM faillock check"

# STIG hardening enables pam_faillock.so in common-auth. Reset any accumulated
# failed-attempt counters so the RDP user isn't blocked at login.
if command -v faillock &>/dev/null; then
  if [[ -f /etc/security/faillock.conf ]]; then
    if ! grep -qE '^deny\s*=\s*0' /etc/security/faillock.conf; then
      log_warn "faillock.conf: deny is not 0 — repeated xrdp login failures may lock the account"
      log_warn "Consider adding 'deny = 0' and 'unlock_time = 0' to /etc/security/faillock.conf"
    else
      log_info "faillock.conf: deny=0 confirmed"
    fi
  fi
  faillock --user "$CALLING_USER" --reset 2>/dev/null \
    && log_info "faillock counter reset for $CALLING_USER" \
    || log_warn "faillock reset failed — run manually if login is blocked: faillock --user $CALLING_USER --reset"
else
  log_info "faillock not present — skipping"
fi

# ── Step 10: Log file ──────────────────────────────────────────────────────
log_section "Step 10: Setting up log file"

touch "$LOG_FILE"
chmod 664 "$LOG_FILE"
log_info "Log file ready: $LOG_FILE"

cat > /etc/logrotate.d/start-rdp << 'EOF'
/var/log/start-rdp.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
log_info "Log rotation configured: /etc/logrotate.d/start-rdp (weekly, 4 weeks)"

# ── Step 11: Enable and start xrdp ───────────────────────────────────────
log_section "Step 11: Enabling and starting xrdp"

systemctl enable xrdp
systemctl start xrdp

for _i in $(seq 1 10); do
  if systemctl is-active --quiet xrdp; then
    log_info "xrdp is running"
    break
  fi
  sleep 1
done
if ! systemctl is-active --quiet xrdp; then
  log_warn "xrdp did not start — check: sudo journalctl -u xrdp -n 50"
fi

# ── Step 12: Initial run ───────────────────────────────────────────────────
log_section "Step 12: Running initial IP detection"

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

