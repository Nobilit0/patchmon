# PatchMon Auto-Patch

Daily PatchMon `patch_all` automation for Linux and Windows hosts.

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
