# PatchMon Auto-Patch

Daily PatchMon `patch_all` automation for Linux and Windows hosts.


# Automated Install::

What's included
- Automatically checks for Python 3 and installs it if missing.
- Installs Python virtual-environment support when needed.
- Prompts for the PatchMon server IP or offers 127.0.0.1:3000.
- Offers daily, weekly, monthly, and custom schedules.
- Supports running every 2, 4, 6, 8, or 12 hours.
- Offers a dry-run before enabling automatic patching.
- UUID is automatically gathered from your instance

  
  
## Option 1: Download and install
Run these commands on the machine where you want to install PatchMon auto-patching:
```bash
curl -fL -o install-patchmon.sh \
  https://raw.githubusercontent.com/Nobilit0/patchmon/main/scripts/patchmon-auto-patch-installer-v2.sh

chmod +x install-patchmon.sh

sudo ./install-patchmon.sh
```
This downloads the installer locally, makes it executable, and runs it with root privileges.


## Option 2: One-line installation:

**If you trust the script and have already reviewed it**
```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Nobilit0/patchmon/main/scripts/patchmon-auto-patch-installer-v2.sh)'
```
This executes the installer immediately without saving a local copy.


## Option 3: Single command with local download:
```bash
curl -fsSL -o /tmp/install-patchmon.sh https://raw.githubusercontent.com/Nobilit0/patchmon/main/scripts/patchmon-auto-patch-installer-v2.sh && sudo bash /tmp/install-patchmon.sh
```



# Manual Install::



## Important authentication assumption

Your DevTools observations showed a `token` cookie, no `Authorization` header,
and a login JSON response containing `token`. This script uses the login
response's `token` value as `Cookie: token=<value>`. The first `--dry-run`
performs login and read-only host/run queries to validate this assumption.
Do not enable the timer until dry-run succeeds.

## Install (Debian/Ubuntu PatchMon server or another machine with API access)

```bash
sudo install -d -m 0750 /opt/patchmon-auto-patch
sudo install -m 0750 patchmon_auto_patch.py /opt/patchmon-auto-patch/patchmon_auto_patch.py
sudo python3 -m venv /opt/patchmon-auto-patch/venv
sudo /opt/patchmon-auto-patch/venv/bin/pip install --upgrade pip
sudo install -d -m 0750 /var/log/patchmon-auto-patch
sudo install -m 0600 patchmon-auto-patch.env.example /etc/patchmon-auto-patch.env
sudoedit /etc/patchmon-auto-patch.env
```

Set `PATCHMON_USERNAME`, `PATCHMON_PASSWORD`, and a stable UUID for
`PATCHMON_DEVICE_ID`. Generate a UUID with:

```bash
python3 -c 'import uuid; print(uuid.uuid4())'
```

Protect the file:

```bash
sudo chown root:root /etc/patchmon-auto-patch.env
sudo chmod 600 /etc/patchmon-auto-patch.env
```

## Validate safely first

```bash
sudo /opt/patchmon-auto-patch/venv/bin/python \
  /opt/patchmon-auto-patch/patchmon_auto_patch.py --dry-run
```

A successful dry-run must show login success, host/run counts, and either
eligible hosts or skip reasons. It does not trigger updates. If it fails with
401/403, stop and inspect the browser's exact auth/session behavior; do not
enable the timer.

## Install and enable the systemd timer

```bash
sudo install -m 0644 patchmon-auto-patch.service /etc/systemd/system/
sudo install -m 0644 patchmon-auto-patch.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now patchmon-auto-patch.timer
systemctl list-timers patchmon-auto-patch.timer
```

The timer uses the server's local timezone and runs daily at 03:00. Confirm the
timezone with `timedatectl`.

## Manual operation and logs

```bash
# Preview only
sudo /opt/patchmon-auto-patch/venv/bin/python /opt/patchmon-auto-patch/patchmon_auto_patch.py --dry-run

# Run patching now
sudo systemctl start patchmon-auto-patch.service

# Logs
sudo journalctl -u patchmon-auto-patch.service -n 200 --no-pager
sudo tail -f /var/log/patchmon-auto-patch/patchmon-auto-patch.log
```

## Behavior and safety

- Retrieves every page of `/api/v1/dashboard/hosts` (`items` response) and `/api/v1/patching/runs` (`runs` plus `pagination` response), matching the response shapes you captured.
- Skips hosts unless active, explicitly not stale, and reporting (when supplied).
- Requires `updatesCount > 0` or `updateState == updates_pending`.
- Skips a host if any run for it has a status not in the known terminal set.
  Unknown statuses are treated as active to fail closed.
- Uses a local `flock` lock to prevent overlapping executions.
- Triggers `patch_all`; Windows gets `windows_scope: {updates: true, apps: true}`.
- Linux requests omit `windows_scope`.
- Does not reboot hosts.
- Logs trigger acceptance/failure and available run/reboot indicators.

The API response's exact trigger completion semantics and all possible terminal
run statuses have not yet been independently documented. Review logs and
PatchMon's UI after the first manually supervised run.

## Important Info

Here is a list of the newly configured items:

- Environment: /etc/patchmon-auto-patch.env (root:root, 0600)
- Program:     /opt/patchmon-auto-patch/patchmon_auto_patch.py
- Logs:        /var/log/patchmon-auto-patch/patchmon-auto-patch.log
- Timer:       systemctl status patchmon-auto-patch.time
- Service:     systemctl start patchmon-auto-patch.service
- Logs:        journalctl -u patchmon-auto-patch.service -n 100 --no-pager
