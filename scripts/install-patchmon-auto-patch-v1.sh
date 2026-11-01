#!/usr/bin/env bash
set -Eeuo pipefail

ZIP_URL="https://github.com/Nobilit0/patchmon/raw/refs/heads/main/scripts/patchmon-auto-patch-install.zip"
INSTALL_DIR="/opt/patchmon-auto-patch"
ENV_FILE="/etc/patchmon-auto-patch.env"
SERVICE_FILE="/etc/systemd/system/patchmon-auto-patch.service"
TIMER_FILE="/etc/systemd/system/patchmon-auto-patch.timer"
LOG_DIR="/var/log/patchmon-auto-patch"
PYTHON_BIN="/usr/bin/python3"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

cleanup() {
    [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

prompt() {
    local __var="$1" __message="$2" __default="${3:-}"
    local answer
    if [[ -n "$__default" ]]; then
        read -r -p "$__message [$__default]: " answer
        answer="${answer:-$__default}"
    else
        read -r -p "$__message: " answer
    fi
    printf -v "$__var" '%s' "$answer"
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

valid_hhmm() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"
}

install_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v unzip >/dev/null 2>&1 || missing+=(unzip)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required on this machine."

    if ((${#missing[@]})); then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" python3-venv
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing[@]}" python3-pip
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}" python3-pip
        else
            die "Missing dependencies (${missing[*]}) and no supported package manager found."
        fi
    fi
    PYTHON_BIN="$(command -v python3)"
}

download_and_extract() {
    WORK_DIR="$(mktemp -d /tmp/patchmon-auto-patch.XXXXXX)"
    chmod 700 "$WORK_DIR"
    info "Downloading PatchMon automation package from GitHub..."
    curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 \
        "$ZIP_URL" -o "$WORK_DIR/package.zip"

    unzip -tq "$WORK_DIR/package.zip" >/dev/null || die "Downloaded ZIP failed integrity validation."

    # Reject absolute paths and traversal entries before extraction.
    "$PYTHON_BIN" - "$WORK_DIR/package.zip" "$WORK_DIR/extracted" <<'PY'
import pathlib, sys, zipfile
archive, destination = sys.argv[1], pathlib.Path(sys.argv[2])
with zipfile.ZipFile(archive) as z:
    for info in z.infolist():
        name = pathlib.PurePosixPath(info.filename)
        if name.is_absolute() or ".." in name.parts:
            raise SystemExit(f"Unsafe ZIP member path: {info.filename}")
    z.extractall(destination)
PY

    SCRIPT_PATH="$(find "$WORK_DIR/extracted" -type f -name patchmon_auto_patch.py -print -quit)"
    SERVICE_SOURCE="$(find "$WORK_DIR/extracted" -type f -name patchmon-auto-patch.service -print -quit)"
    TIMER_SOURCE="$(find "$WORK_DIR/extracted" -type f -name patchmon-auto-patch.timer -print -quit)"
    [[ -n "$SCRIPT_PATH" ]] || die "ZIP does not contain patchmon_auto_patch.py"
    [[ -n "$SERVICE_SOURCE" ]] || die "ZIP does not contain patchmon-auto-patch.service"
    [[ -n "$TIMER_SOURCE" ]] || die "ZIP does not contain patchmon-auto-patch.timer"

    mkdir -p "$INSTALL_DIR" "$LOG_DIR"
    install -o root -g root -m 0750 "$SCRIPT_PATH" "$INSTALL_DIR/patchmon_auto_patch.py"
    install -o root -g root -m 0644 "$SERVICE_SOURCE" "$SERVICE_FILE"
    install -o root -g root -m 0644 "$TIMER_SOURCE" "$TIMER_FILE"
    chmod 0750 "$INSTALL_DIR"
    chmod 0750 "$LOG_DIR"
    ok "Automation files installed."
}

configure_environment() {
    local patchmon_url username password device_id
    prompt patchmon_url "PatchMon base URL (no trailing slash)" "http://192.168.2.15:3000"
    patchmon_url="${patchmon_url%/}"
    [[ "$patchmon_url" =~ ^https?://[^[:space:]]+$ ]] || die "Invalid PatchMon URL."
    prompt username "PatchMon username"
    [[ -n "$username" ]] || die "Username cannot be empty."

    printf "PatchMon password (input hidden): "
    IFS= read -r -s password
    printf '\n'
    [[ -n "$password" ]] || die "Password cannot be empty."
    [[ "$password" != *$'\n'* && "$password" != *$'\r'* ]] || die "Password cannot contain newline characters."

    device_id="$("$PYTHON_BIN" -c 'import uuid; print(uuid.uuid4())')"
    info "Generated persistent device UUID: $device_id"

    if [[ -e "$ENV_FILE" ]]; then
        local backup="${ENV_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
        cp -a "$ENV_FILE" "$backup"
        chmod 600 "$backup"
        warn "Existing environment file backed up to $backup"
    fi

    # Write with shell built-ins so the password is not passed in argv or echoed.
    umask 077
    {
        printf '%s\n' '# PatchMon Auto-Patch credentials. Keep this file root-readable only.'
        printf 'PATCHMON_URL=%s\n' "$patchmon_url"
        printf 'PATCHMON_USERNAME=%s\n' "$username"
        printf 'PATCHMON_PASSWORD=%s\n' "$password"
        printf 'PATCHMON_DEVICE_ID=%s\n' "$device_id"
        printf '%s\n' 'PATCHMON_LOG_FILE=/var/log/patchmon-auto-patch/patchmon-auto-patch.log'
    } > "$ENV_FILE"
    unset password
    chown root:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Credentials saved to $ENV_FILE with permissions 0600 (root:root)."
}

setup_venv() {
    if ! "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv
            "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"
        else
            die "Could not create Python virtual environment. Install python3-venv and rerun."
        fi
    fi
    chown -R root:root "$INSTALL_DIR"
    chmod 0750 "$INSTALL_DIR"
    chmod 0750 "$INSTALL_DIR/venv/bin/activate" 2>/dev/null || true
    "$INSTALL_DIR/venv/bin/python" -m py_compile "$INSTALL_DIR/patchmon_auto_patch.py" \
        || die "Python automation failed syntax validation."
    ok "Python virtual environment and syntax check completed."
}

run_dry_run() {
    if confirm "Run a read-only PatchMon dry-run now?"; then
        info "Running dry-run. This logs in and reads hosts/runs but does not trigger patches."
        if "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/patchmon_auto_patch.py" --dry-run; then
            ok "Dry-run completed successfully."
        else
            warn "Dry-run failed. Review the error above. The timer will NOT be enabled automatically."
            return 1
        fi
    else
        warn "Dry-run skipped. Validate manually before enabling scheduled patching."
        return 2
    fi
    return 0
}

calendar_for_schedule() {
    local start_time="$1" frequency="$2" weekday="$3" monthday="$4" custom="$5"
    case "$frequency" in
        daily)   printf '*-*-* %s:00' "$start_time" ;;
        weekly)  printf '%s *-*-* %s:00' "$weekday" "$start_time" ;;
        monthly) printf '*-*-%s %s:00' "$monthday" "$start_time" ;;
        custom)  printf '%s' "$custom" ;;
        *) return 1 ;;
    esac
}

configure_timer() {
    if ! confirm "Configure and enable a systemd timer now?"; then
        warn "Timer not configured. You can install it later using the README instructions."
        return 0
    fi

    local start_time frequency weekday monthday custom calendar
    while true; do
        prompt start_time "Local server start time (HH:MM, 24-hour)" "03:00"
        valid_hhmm "$start_time" && break
        warn "Enter a valid 24-hour time, for example 03:00 or 22:30."
    done

    echo
    echo "Repeat frequency:"
    echo "  1) Daily"
    echo "  2) Weekly"
    echo "  3) Monthly"
    echo "  4) Custom systemd OnCalendar expression"
    local choice
    while true; do
        prompt choice "Choose 1-4" "1"
        [[ "$choice" =~ ^[1-4]$ ]] && break
        warn "Choose 1, 2, 3, or 4."
    done

    weekday=""
    monthday=""
    custom=""
    case "$choice" in
        1) frequency="daily" ;;
        2)
            frequency="weekly"
            prompt weekday "Day of week (Mon, Tue, Wed, Thu, Fri, Sat, Sun)" "Sun"
            case "$weekday" in Mon|Tue|Wed|Thu|Fri|Sat|Sun) ;; *) die "Invalid weekday; use Mon, Tue, Wed, Thu, Fri, Sat, or Sun." ;; esac
            ;;
        3)
            frequency="monthly"
            prompt monthday "Day of month (1-28 recommended)" "1"
            [[ "$monthday" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || die "Choose a day from 1 through 28 to ensure it occurs every month."
            ;;
        4)
            frequency="custom"
            prompt custom "Systemd OnCalendar expression (example: Mon..Fri *-*-* 03:00:00)"
            [[ -n "$custom" ]] || die "Custom calendar expression cannot be empty."
            ;;
    esac

    if [[ "$frequency" == "custom" ]]; then
        calendar="$custom"
    else
        calendar="$(calendar_for_schedule "$start_time" "$frequency" "$weekday" "$monthday" "")"
    fi

    # Validate the calendar expression with systemd before writing it.
    if ! systemd-analyze calendar "$calendar" >/dev/null 2>&1; then
        die "systemd rejected calendar expression: $calendar"
    fi

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Scheduled PatchMon automatic patching

[Timer]
OnCalendar=$calendar
Persistent=true
AccuracySec=1min
Unit=patchmon-auto-patch.service

[Install]
WantedBy=timers.target
EOF
    chown root:root "$TIMER_FILE"
    chmod 0644 "$TIMER_FILE"

    systemctl daemon-reload
    systemctl enable --now patchmon-auto-patch.timer
    ok "Timer enabled: $calendar"
    systemctl list-timers patchmon-auto-patch.timer --no-pager || true
}

main() {
    require_root
    echo
    printf '%sPatchMon Auto-Patch Installer%s\n' "$GREEN" "$NC"
    echo "This installs the automation package and optionally configures a systemd timer."
    echo
    install_dependencies
    download_and_extract
    setup_venv
    configure_environment

    local dry_status=0
    run_dry_run || dry_status=$?

    if [[ "$dry_status" -eq 1 ]]; then
        if ! confirm "Dry-run failed. Continue to timer setup anyway?"; then
            warn "Installation completed, but timer was not enabled."
            exit 0
        fi
    elif [[ "$dry_status" -eq 2 ]]; then
        if ! confirm "You skipped dry-run. Continue to timer setup anyway?"; then
            warn "Installation completed, but timer was not enabled."
            exit 0
        fi
    fi

    configure_timer
    echo
    ok "Installation workflow finished."
    echo "Environment: $ENV_FILE (root:root, 0600)"
    echo "Program:     $INSTALL_DIR/patchmon_auto_patch.py"
    echo "Logs:        $LOG_DIR/patchmon-auto-patch.log"
    echo "Timer:       systemctl status patchmon-auto-patch.timer"
    echo "Service:     systemctl start patchmon-auto-patch.service"
    echo "Logs:        journalctl -u patchmon-auto-patch.service -n 100 --no-pager"
}
main "$@"
