# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Two bash scripts for setting up xRDP (Remote Desktop Protocol) on Ubuntu 22.04/24.04 with xfce4. Designed to be run on a headless Ubuntu server to make it accessible via RDP from Windows, macOS, or Linux clients.

**Target environment**: STIG-hardened Ubuntu (e.g. provisioned with a `final_updates.sh` STIG script). This matters because STIG hardening introduces several obstacles the installer explicitly works around — see Key design decisions below.

- `install-rdp.sh` — One-shot installer. Must be run with `sudo` from a regular user account (`sudo ./install-rdp.sh`). Do NOT run as raw root — the installer uses `$SUDO_USER` to determine which user to configure and hard-errors if it resolves to root. Both scripts must be in the same directory.
- `start-rdp.sh` — Installed to `/opt/rdp/start-rdp.sh` with a symlink at `/usr/local/bin/start-rdp`. Called by the `xrdp-autostart` systemd service at boot.

## Running / testing

These scripts require a live Ubuntu 22.04 system with root access — there are no unit tests and no dry-run mode. To test changes:

1. Copy both scripts to the target Ubuntu host
2. `chmod +x install-rdp.sh start-rdp.sh`
3. `sudo ./install-rdp.sh`

After install, use the management script:
```bash
sudo start-rdp --status     # show IP, port, and xrdp state
sudo start-rdp --restart    # force restart xrdp
sudo start-rdp --wait       # retry until RFC1918 IP appears (used at boot)
sudo start-rdp --port 3390  # switch to a custom port
```

Logs:
```bash
tail -f /var/log/start-rdp.log
sudo journalctl -u xrdp-autostart -f
sudo journalctl -u xrdp -n 50
```

## Key design decisions

**RFC1918 IP detection** — `start-rdp.sh` only binds to private-range IPs (10.x, 172.16–31.x, 192.168.x). The `--wait` flag retries up to 30 times (10s intervals) for use in the systemd boot service.

**Port normalization** — xrdp.ini sometimes ends up with malformed port values like `3389-1-1ask5900ask3389`. Both scripts strip non-numeric suffixes using `grep -oE '^[0-9]+'` before reading or writing the port.

**xrdp.ini has two port lines** — The global `[Globals]` `port=` sets the listener port; the `[Xorg]` section's `port=` must stay at `-1` for sesman dynamic assignment. The sed commands use `0,/^port=/` to target only the first occurrence for the global port, then a separate pass to enforce `-1` in the `[Xorg]` block.

**sesman IPv6** — `sesman.ini` is configured with `ListenAddress=::` so sesman listens on IPv6, matching how xrdp connects to it internally.

**IP cache** — The current IP:PORT is written to `/var/run/xrdp-server-ip` so `--status` can report what was last configured without re-detecting.

**Firewall** — ufw rules are managed automatically when the port changes. If ufw is absent, the step is skipped with a warning (not a fatal error).

**libexo-2-0 ESM conflict (Ubuntu 22.04 only)** — Ubuntu Pro/ESM can pre-install `libexo-2-0` at version `4.16.3-1ubuntu0.1~esm1`, which conflicts with xfce4's requirement for the base jammy version `4.16.3-1`. The installer detects this on jammy and downgrades with `--allow-downgrades` before installing xfce4.

**Session cache / black screen** — A stale `~/.cache/sessions` from a prior xfce4 session causes a black screen on first RDP connect. The installer clears this directory during setup.

**PAM faillock (STIG)** — STIG hardening wires `pam_faillock.so` into `common-auth`. The installer resets the calling user's faillock counter and warns if `deny` is not `0` in `faillock.conf`. If a user gets locked out post-install: `faillock --user <username> --reset`.

**xfce4-panel configver=2 format** — xfce4-panel 4.16 (Ubuntu 22.04) stores panel config at the xfconf path `/panels/panel-N/` (nested inside the `panels` property), not at the top-level `/panel-N/` path used in older versions. Writing config in the old format is silently ignored — xfce4-panel reads the nested path instead, which may contain stale config from a prior session (causing a blank floating panel). The XML must include `<property name="configver" type="int" value="2"/>` and nest `panel-1` inside the `panels` property.

**Session cleanup on reinstall** — The installer stops xrdp first (to release its hold on the Xorg session), then SIGKILLs xfce4-session, xfconfd, xfce4-panel, and Xorg for the calling user. SIGKILL (not SIGTERM) is required for xfconfd — SIGTERM lets it flush its in-memory cache back to disk, overwriting the freshly written xfce4-panel.xml. The user must close their RDP window and reconnect after the install to get a fresh session.

**Desktop icons** — The installer copies `xfce4-terminal.desktop` and Firefox's `.desktop` file to `~/Desktop/` and marks them executable. The executable bit is required — xfdesktop renders non-executable `.desktop` files as plain text files, not launcher icons. Firefox is detected from three locations in order: `/usr/share/applications/firefox.desktop` (deb), `/var/lib/snapd/desktop/applications/firefox_firefox.desktop` (snap), `/usr/share/applications/firefox-esr.desktop` (ESR).

**Screen-lock lockout bug** — When the xfce4 screen locker times out, unlock attempts go through PAM/faillock. Each failure increments the counter; once the threshold is hit the account is blocked even for correct passwords. The hung Xorg/sesman state also prevents a clean reconnect. Recovery command (SSH in and run): `sudo start-rdp --recover --user <username>`. This resets faillock, kills the user's Xorg and sesman, removes stale `/tmp/.X11-unix/X1*` and `/tmp/.xrdp*` files, and force-restarts xrdp. Implemented as the `--recover` flag in `start-rdp.sh`.

## Files installed on the target system

| Path | Purpose |
|------|---------|
| `/opt/rdp/start-rdp.sh` | Main management script |
| `/usr/local/bin/start-rdp` | Symlink to above |
| `/etc/systemd/system/xrdp-autostart.service` | Boot service |
| `/etc/sudoers.d/rdp-autostart` | Passwordless sudo for start-rdp |
| `/var/log/start-rdp.log` | Persistent log |
| `/var/run/xrdp-server-ip` | IP:PORT cache (transient) |
| `~/.xsession` | xfce4-session entry for the installing user |
| `/etc/xrdp/startwm.sh` | xrdp session launcher (set to xfce4) |
| `~/Desktop/firefox.desktop` | Firefox launcher icon on the xfce4 desktop |
| `~/Desktop/xfce4-terminal.desktop` | Terminal launcher icon on the xfce4 desktop |
