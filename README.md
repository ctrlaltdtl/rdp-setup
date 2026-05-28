# xRDP Auto-start Setup
Ubuntu 22.04/24.04 — xfce4 + xrdp with RFC1918 IP detection

Designed for headless Ubuntu servers on a private LAN, including STIG-hardened
systems. Tested on Ubuntu 22.04 (jammy) and 24.04 (noble).

## Files

| File | Purpose |
|------|---------|
| `install-rdp.sh` | One-shot installer — run this first as root via sudo |
| `start-rdp.sh` | Management script — installed automatically to `/opt/rdp/` |

## Installation

```bash
chmod +x install-rdp.sh start-rdp.sh
sudo ./install-rdp.sh
```

Both scripts must be in the same directory when the installer runs.

## Configuration

Edit the variables at the top of each script before running:

**`install-rdp.sh`**

| Variable | Default | Description |
|----------|---------|-------------|
| `DEFAULT_PORT` | `3389` | RDP listening port |
| `SCREEN_LOCK_MINUTES` | `0` | Screen lock timeout — `0` disables the lock entirely |

**`start-rdp.sh`**

| Variable | Default | Description |
|----------|---------|-------------|
| `PREFERRED_IFACE` | `""` | Pin RFC1918 IP detection to a specific NIC (e.g. `eth0`). Required on multi-NIC servers where more than one interface has a private IP. |

## What the installer does

**Pre-flight**
- Verifies OS, internet connectivity, and apt sources (uncomments if all entries are commented out)
- Reports SSH concurrency limits — `MaxSessions`, `AllowUsers`, PAM `maxlogins` — that could prevent SSH and RDP from running simultaneously on STIG-hardened systems

**Step 1 — Packages**
- Installs `xrdp`, `xfce4`, `xfce4-goodies`, `xorgxrdp`, and a polkit authentication agent
- Skips `dbus-x11` if unavailable (removed in newer Ubuntu releases)
- On Ubuntu 22.04: detects and downgrades ESM-version `libexo-2-0` that conflicts with xfce4
- Disables `lightdm` after install — prevents VT conflict with xrdp on headless servers

**Step 2 — xfce4 session**
- Writes `/etc/xrdp/startwm.sh` and `~/.xsession` to launch xfce4
- Configures polkit agent autostart so GUI elevation prompts work in the session
- Clears stale `~/.cache/sessions` that causes black screens on first connect

**Screen lock**
- Writes `xfce4-screensaver.xml`, `xfce4-power-manager.xml`, and `xfce4-panel.xml`
  to `~/.config/xfce4/xfconf/xfce-perchannel-xml/`
- Default: screen lock disabled (`SCREEN_LOCK_MINUTES=0`) — avoids PAM/faillock
  lockout issues on STIG systems
- Pre-seeds panel config to suppress the first-run dialog that blocks RDP sessions

**Step 3 — xrdp permissions**
- Adds `xrdp` and the installing user to the `ssl-cert` group

**TLS certificate**
- Regenerates the xrdp self-signed cert with 10-year validity to prevent
  client warnings after the default 1-year cert expires

**Step 4 — xrdp.ini**
- Normalizes malformed port values (strips non-numeric suffixes)
- Ensures `[Xorg]` section uses `port=-1` for sesman dynamic assignment
- Configures `sesman.ini ListenAddress` — detects whether IPv6 is available and
  sets `::` or falls back to `127.0.0.1` (STIG systems often disable IPv6)

**Steps 5–8 — Infrastructure**
- Installs `start-rdp.sh` to `/opt/rdp/` with a `/usr/local/bin/start-rdp` symlink
- Installs and enables the `xrdp-autostart` systemd service (runs `--wait` at boot)
- Configures sudoers for passwordless `start-rdp` execution
- Resets PAM faillock counter for the installing user

**Steps 9–12 — Finalise**
- Creates `/var/log/start-rdp.log` with logrotate config (weekly, 4 weeks)
- Enables and starts xrdp
- Runs initial RFC1918 IP detection and prints connection info

## Usage

```bash
sudo start-rdp --status                  # Show IP, port, xrdp state, and client commands
sudo start-rdp --restart                 # Force restart xrdp
sudo start-rdp --wait                    # Retry until RFC1918 IP appears (used at boot)
sudo start-rdp --port 3390               # Switch to a custom port
sudo start-rdp --restart --port 3390     # Restart on a custom port
sudo start-rdp --recover --user <name>   # Recover a stuck/locked session (see below)
sudo start-rdp --help                    # Show all options
```

## Client connection

`sudo start-rdp --status` prints the current IP and port. A Remmina profile is
auto-written to `/opt/rdp/rdp-server.remmina` each time the IP is detected.

| OS | Client | Command / Notes |
|----|--------|-----------------|
| Windows | Built-in RDP | `mstsc /v:<IP>:<PORT>` |
| macOS | Windows App | Add PC → Host: `<IP>:<PORT>` |
| Linux | xfreerdp | `xfreerdp /v:<IP> /port:<PORT> /dynamic-resolution` |
| Linux | Remmina | `remmina -c /opt/rdp/rdp-server.remmina` |

## Logs

```bash
tail -f /var/log/start-rdp.log
sudo journalctl -u xrdp-autostart -f
sudo journalctl -u xrdp -n 50
```

## Troubleshooting

**Black screen on first connect**
Stale session cache — clear it and reconnect:
```bash
rm -rf ~/.cache/sessions
sudo systemctl restart xrdp
```

**No IP found at boot**
Server may not have a network connection yet:
```bash
sudo start-rdp --wait
```
On a multi-NIC server with more than one RFC1918 address, set `PREFERRED_IFACE`
in `/opt/rdp/start-rdp.sh` to the correct interface name, then `sudo start-rdp --restart`.

**Port conflict**
```bash
sudo start-rdp --restart --port 3390
```

**xrdp won't start**
```bash
sudo journalctl -u xrdp -n 50
```

**Login blocked after failed attempts (STIG/PAM faillock)**
Reset the counter:
```bash
faillock --user <username> --reset
```
To prevent recurrence, add `deny = 0` and `unlock_time = 0` to
`/etc/security/faillock.conf`.

**Stuck session after screen lock**
If the screen lock was enabled (`SCREEN_LOCK_MINUTES > 0`) and the account is
now blocked, SSH in and recover:
```bash
sudo start-rdp --recover --user <username>
```
This resets the faillock counter, kills the hung Xorg and xfce4-session processes,
removes stale X11 sockets and xrdp temp files, and restarts xrdp.
Reconnect from your RDP client after running it.

**SSH and RDP can't be active at the same time**
Check PAM `maxlogins` — STIG hardening sometimes sets it to `1`:
```bash
grep maxlogins /etc/security/limits.conf
```
If the value is `1`, raise it to `4` or remove the line. No service restart needed;
PAM reads the file at each login.

## License
GPL v2.0 or later
