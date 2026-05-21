# xRDP Auto-start Setup v2
Ubuntu 22.04/24.04 — xfce4 + xrdp with RFC1918 IP detection

## Files
- `install-rdp.sh` — One-shot installer (run this first)
- `start-rdp.sh`   — RDP management script (installed automatically)

## Installation

```bash
chmod +x install-rdp.sh start-rdp.sh
sudo ./install-rdp.sh
```

## What the installer does

1. **Pre-flight checks** — verifies internet, fixes commented-out apt sources,
   removes stale local file:/ apt entries and empty /apt directories
2. Installs xrdp, xfce4, xfce4-goodies, xorgxrdp (skips dbus-x11 if unavailable)
3. Configures xfce4 as the default RDP session
4. Adds xrdp and the installing user to the ssl-cert group
5. **Normalizes xrdp.ini port** — strips non-numeric suffixes from port value
6. Installs start-rdp.sh to /opt/rdp/ with a /usr/local/bin/start-rdp symlink
7. Installs and enables the xrdp-autostart systemd service
8. Configures sudoers for passwordless start-rdp execution
9. Sets up the log file at /var/log/start-rdp.log
10. Enables and starts xrdp
11. Runs initial IP detection and prints connection info

## Usage

```bash
sudo start-rdp --status                # Show current status, IP, and connection info
sudo start-rdp --restart               # Force restart xrdp
sudo start-rdp --wait                  # Wait for RFC1918 IP then start (useful at boot)
sudo start-rdp --port 3390             # Use a custom port
sudo start-rdp --restart --port 3390   # Restart on a custom port
sudo start-rdp --help                  # Show all options
```

## Logs

```bash
tail -f /var/log/start-rdp.log
sudo journalctl -u xrdp-autostart -f
sudo journalctl -u xrdp -n 50
```

## Client Connection

| OS      | Client                        | Command / Notes                        |
|---------|-------------------------------|----------------------------------------|
| Windows | Built-in RDP (mstsc)          | `mstsc /v:<IP>:<PORT>`                 |
| macOS   | Windows App                   | Add PC → Host: `<IP>:<PORT>`           |
| Linux   | xfreerdp                      | `xfreerdp /v:<IP> /port:<PORT>`        |

## Troubleshooting

**Black screen on connect** — ensure `~/.xsession` contains `xfce4-session`
and restart xrdp: `sudo start-rdp --restart`

**No IP found** — server may not have a network connection yet:
`sudo start-rdp --wait`

**Port conflict** — switch to a custom port:
`sudo start-rdp --restart --port 3390`

**xrdp won't start** — check logs:
`sudo journalctl -u xrdp -n 50`

**Login blocked after failed attempts (faillock/PAM)** — reset the counter:
`faillock --user <username> --reset`
If this recurs, ensure `/etc/security/faillock.conf` contains `deny = 0` and `unlock_time = 0`.

**Screen lock → correct password rejected (can't unlock)** — the xfce4 screen locker
authenticates through PAM/faillock, which accumulates failures and blocks the account.
SSH into the server and run:
```bash
sudo start-rdp --recover --user <username>
```
This resets faillock, kills the hung Xorg/sesman state, cleans up stale X11 sockets,
and restarts xrdp. Then reconnect from your RDP client.

## License
GPL v2.0 or later

