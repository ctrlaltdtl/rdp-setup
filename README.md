# xRDP Auto-start Setup
Ubuntu 22.04 — xfce4 + xrdp with RFC1918 IP detection

## Files
- `install-rdp.sh` — One-shot installer (run this first)
- `start-rdp.sh`   — RDP management script (installed by installer)

## Installation

```bash
chmod +x install-rdp.sh start-rdp.sh
sudo ./install-rdp.sh
```

## Usage

```bash
sudo start-rdp --status          # Show current status, IP, and connection info
sudo start-rdp --restart         # Force restart xrdp
sudo start-rdp --wait            # Wait for RFC1918 IP then start (useful at boot)
sudo start-rdp --port 3390       # Use a custom port
sudo start-rdp --restart --port 3390  # Restart on a custom port
sudo start-rdp --help            # Show all options
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
| macOS   | Microsoft Remote Desktop      | Add PC → Host: `<IP>:<PORT>`           |
| Linux   | xfreerdp                      | `xfreerdp /v:<IP> /port:<PORT>`        |

## License
GPL v2.0 or later
