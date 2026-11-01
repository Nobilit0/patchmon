#!/usr/bin/env bash
# may.sh — Debian 13 OpenSCAP hardening (19 findings; LXC-aware)
# Review the WARNING section before use. Run: sudo bash ./may.sh
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}

[[ $EUID -eq 0 ]] || { echo 'ERROR: Run as root: sudo bash ./may.sh' >&2; exit 1; }
[[ -r /etc/os-release ]] || { echo 'ERROR: /etc/os-release unavailable' >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || {
  echo "ERROR: This script requires Debian 13; found ${PRETTY_NAME:-unknown}." >&2; exit 1;
}

BACKUP_DIR="/root/may-backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
LOG="$BACKUP_DIR/remediation.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "ERROR: Unexpected failure on line ${LINENO}; see ${LOG}" >&2' ERR

IS_CONTAINER=0
virt=$(systemd-detect-virt --container 2>/dev/null || true)
[[ -z $virt || $virt == none ]] || IS_CONTAINER=1

OK=0; SKIPPED=0; WARNED=0
msg()  { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { echo "  OK: $*"; OK=$((OK + 1)); }
skip() { echo "  SKIP: $*"; SKIPPED=$((SKIPPED + 1)); }
warn() { echo "  WARN: $*"; WARNED=$((WARNED + 1)); }
backup() {
  local file=$1 dest
  [[ -e $file || -L $file ]] || return 0
  dest="$BACKUP_DIR$file"
  mkdir -p "$(dirname "$dest")"
  [[ -e $dest || -L $dest ]] || cp -a -- "$file" "$dest"
}
write_config() {
  local path=$1 contents=$2
  backup "$path"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$contents" > "$path"
  chmod 0644 "$path"
}
# Replace uncommented KEY value (or KEY=value); leave all other settings untouched.
set_kv() {
  local path=$1 key=$2 value=$3
  backup "$path"
  [[ -f $path ]] || : > "$path"
  sed -i -E "/^[[:space:]]*${key}([[:space:]]+|[[:space:]]*=[[:space:]]*)/d" "$path"
  printf '%s %s\n' "$key" "$value" >> "$path"
}
install_packages() {
  local package need=()
  for package in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
      need+=("$package")
    fi
  done
  if (( ${#need[@]} )); then
    echo "  Installing: ${need[*]}"
    apt-get update && apt-get install -y "${need[@]}"
  fi
}

printf 'may.sh — Debian 13 hardening\nBackup: %s\nVirtualization: %s\n' "$BACKUP_DIR" "${virt:-none}"
echo 'WARNING: PAM lockouts, shell timeouts, and SU restrictions can affect interactive logins.'
echo 'Keep an existing root console/session open while validating new logins.'

msg '1/19' 'Set UEFI Boot Loader Password'
if (( IS_CONTAINER )); then
  skip 'LXC shares the Proxmox host bootloader; no GRUB changes made.'
elif [[ ! -d /sys/firmware/efi ]]; then
  skip 'System is not using UEFI.'
else
  skip 'Manual bootloader-specific configuration and a chosen password are required.'
fi

msg '2/19' 'Prevent Login to Accounts With Empty Password'
backup /etc/shadow
backup /etc/pam.d/common-auth
mapfile -t EMPTY_USERS < <(awk -F: '$2 == "" {print $1}' /etc/shadow)
if (( ${#EMPTY_USERS[@]} )); then
  for username in "${EMPTY_USERS[@]}"; do
    passwd -l "$username" && echo "  Locked account: $username" || warn "Could not lock $username"
  done
else
  echo '  No empty-password accounts detected.'
fi
if [[ -f /etc/pam.d/common-auth ]]; then
  sed -i -E '/^[[:space:]]*auth[[:space:]]/ { s/(^|[[:space:]])nullok_secure([[:space:]]|$)/\1\2/g; s/(^|[[:space:]])nullok([[:space:]]|$)/\1\2/g; }' /etc/pam.d/common-auth
fi
ok 'Empty-password accounts are locked; common-auth nullok options removed.'

msg '3/19' 'Install systemd_timesyncd Service'
if install_packages systemd-timesyncd; then
  if (( IS_CONTAINER )); then
    skip 'Package installed; time synchronization is governed by the Proxmox host.'
  elif systemctl enable --now systemd-timesyncd.service; then
    ok 'systemd-timesyncd installed and started.'
  else
    warn 'Package installed but service could not be enabled/started.'
  fi
else
  warn 'Failed to install systemd-timesyncd (check apt output above).'
fi

msg '4/19' 'Set Account Expiration Following Inactivity'
backup /etc/default/useradd
if useradd -D -f 30; then
  uid_min=$(awk '$1 == "UID_MIN" {print $2; exit}' /etc/login.defs)
  uid_min=${uid_min:-1000}
  while IFS=: read -r username _ uid _ _ _ _; do
    [[ $uid =~ ^[0-9]+$ ]] || continue
    (( uid >= uid_min && uid < 65534 )) || continue
    shadow_pw=$(getent shadow "$username" | cut -d: -f2)
    [[ -n $shadow_pw && $shadow_pw != '!'* && $shadow_pw != '*'* ]] || continue
    chage --inactive 30 "$username" || warn "Could not update inactivity for $username"
  done < /etc/passwd
  ok 'New and eligible existing accounts have 30-day post-expiration inactivity.'
else
  warn 'Could not update useradd defaults.'
fi

msg '5–7/19' 'Lockouts: deny, pam_faillock module, and unlock time'
if [[ ! -d /etc/pam.d ]]; then
  skip 'PAM configuration directory absent.'
else
  if [[ -e /lib/x86_64-linux-gnu/security/pam_faillock.so ]] || find /lib /usr/lib -path '*/security/pam_faillock.so' -print -quit 2>/dev/null | grep -q .; then
    :
  elif ! install_packages libpam-modules libpam-runtime; then
    warn 'Could not install PAM modules; cannot safely enable faillock.'
  fi
  # Policy is shared by both PAM and audit readers, but alone does not enable PAM.
  backup /etc/security/faillock.conf
  mkdir -p /etc/security
  touch /etc/security/faillock.conf
  for key in deny fail_interval unlock_time; do
    sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" /etc/security/faillock.conf
  done
  printf '\ndeny = 3\nfail_interval = 900\nunlock_time = 900\n' >> /etc/security/faillock.conf
  chmod 0644 /etc/security/faillock.conf
  echo '  Configured 3 failed attempts / 15-minute failure window / 15-minute unlock.'

  # Use the Debian pam-auth-update system. Avoid replacing hand-managed PAM blocks.
  if ! command -v pam-auth-update >/dev/null 2>&1; then
    warn 'pam-auth-update unavailable; faillock module was not enabled.'
  elif ! find /lib /usr/lib -path '*/security/pam_faillock.so' -print -quit 2>/dev/null | grep -q .; then
    warn 'pam_faillock.so unavailable; did not edit login stack.'
  elif [[ ! -f /etc/pam.d/common-auth || ! -f /etc/pam.d/common-account ]]; then
    warn 'Standard common-auth/common-account PAM files absent; manual review required.'
  elif grep -q 'pam_faillock\.so' /etc/pam.d/common-auth && grep -q 'pam_faillock\.so' /etc/pam.d/common-account; then
    ok 'Existing PAM faillock entries detected; kept existing PAM structure.'
  else
    backup /etc/pam.d/common-account
    backup /usr/share/pam-configs/may-faillock
    backup /usr/share/pam-configs/may-faillock-notify
    cat > /usr/share/pam-configs/may-faillock <<'EOF'
Name: may.sh — record failed login attempts
Default: yes
Priority: 0
Auth-Type: Primary
Auth:
 [default=die] pam_faillock.so authfail
EOF
    cat > /usr/share/pam-configs/may-faillock-notify <<'EOF'
Name: may.sh — check login lockouts and reset successful attempts
Default: yes
Priority: 1024
Auth-Type: Primary
Auth:
 requisite pam_faillock.so preauth
Account-Type: Primary
Account:
 required pam_faillock.so
EOF
    if pam-auth-update --enable may-faillock --enable may-faillock-notify; then
      if grep -q 'pam_faillock\.so.*preauth' /etc/pam.d/common-auth &&
         grep -q 'pam_faillock\.so.*authfail' /etc/pam.d/common-auth &&
         grep -q 'pam_faillock\.so' /etc/pam.d/common-account; then
        ok 'pam_faillock enabled via Debian pam-auth-update.'
      else
        warn 'PAM update did not install expected rules; inspect /etc/pam.d/common-{auth,account}.'
      fi
    else
      warn 'pam-auth-update refused/failed (possibly locally modified PAM); manual review required.'
    fi
  fi
fi

# pam-auth-update can regenerate common-auth with the stock nullok option.
# Reapply the empty-password safeguard after any PAM regeneration.
if [[ -f /etc/pam.d/common-auth ]]; then
  sed -i -E '/^[[:space:]]*auth[[:space:]]/ { s/(^|[[:space:]])nullok_secure([[:space:]]|$)/\1\2/g; s/(^|[[:space:]])nullok([[:space:]]|$)/\1\2/g; }' /etc/pam.d/common-auth
fi

msg '8/19' 'Set Interactive Session Timeout'
write_config /etc/profile.d/99-may-session-timeout.sh '# Managed by may.sh: 15-minute timeout for interactive login shells
case $- in
  *i*) if [[ ${TMOUT:-} != 900 ]]; then TMOUT=900; fi; readonly TMOUT; export TMOUT ;;
esac'
# Interactive non-login Bash does not necessarily source /etc/profile.d.
backup /etc/bash.bashrc
if [[ -f /etc/bash.bashrc ]] && ! grep -q '^# BEGIN may.sh interactive timeout$' /etc/bash.bashrc; then
  cat >> /etc/bash.bashrc <<'EOF'

# BEGIN may.sh interactive timeout
case $- in
  *i*) if [[ ${TMOUT:-} != 900 ]]; then TMOUT=900; fi; readonly TMOUT; export TMOUT ;;
esac
# END may.sh interactive timeout
EOF
fi
ok 'TMOUT=900 set for interactive login and Bash sessions.'

msg '9–11/19' 'Set restrictive Bash, login.defs, and profile umask'
set_kv /etc/login.defs UMASK 027
for profile in /etc/profile /etc/bash.bashrc; do
  if [[ -f $profile ]]; then
    backup "$profile"
    # Replace simple existing umask directives; preserve complex shell logic.
    sed -i -E 's/^([[:space:]]*)umask[[:space:]]+0?22([[:space:]]*(#.*)?)$/\1umask 027\2/' "$profile"
    if ! grep -Eq '^[[:space:]]*umask[[:space:]]+0?27([[:space:]]|$)' "$profile"; then
      printf '\n# may.sh: restrictive default creation mask\numask 027\n' >> "$profile"
    fi
  fi
done
write_config /etc/profile.d/99-may-umask.sh '# Managed by may.sh
umask 027'
ok 'UMASK 027 in login.defs, /etc/profile, /etc/bash.bashrc, and /etc/profile.d.'

msg '13–14/19' 'Disable core dump backtraces and storing core dumps'
write_config /etc/systemd/coredump.conf.d/99-may-disable-coredumps.conf '[Coredump]
Storage=none
ProcessSizeMax=0'
ok 'Configured systemd-coredump to neither persist dumps nor process backtraces.'

msg '15/19' 'Disable Host-Based SSH Authentication'
if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
  write_config /etc/ssh/sshd_config.d/00-may-disable-hostbased.conf 'HostbasedAuthentication no'
  if /usr/sbin/sshd -t; then
    if systemctl is-active --quiet ssh.service 2>/dev/null; then
      systemctl reload ssh.service || warn 'sshd configuration valid, but SSH reload failed.'
    fi
    ok 'HostbasedAuthentication no; sshd configuration validated.'
  else
    warn 'sshd -t failed; reverting the SSH configuration drop-in.'
    rm -f /etc/ssh/sshd_config.d/00-may-disable-hostbased.conf
    if [[ -e $BACKUP_DIR/etc/ssh/sshd_config.d/00-may-disable-hostbased.conf ]]; then
      cp -a -- "$BACKUP_DIR/etc/ssh/sshd_config.d/00-may-disable-hostbased.conf" /etc/ssh/sshd_config.d/
    fi
  fi
else
  skip 'OpenSSH server not installed.'
fi

msg '16/19' 'Disable Core Dumps for All Users'
write_config /etc/security/limits.d/99-may-no-coredumps.conf '* soft core 0
* hard core 0
root soft core 0
root hard core 0'
if (( IS_CONTAINER )); then
  skip 'PAM limits configured; kernel fs.suid_dumpable must be managed on the Proxmox host.'
else
  write_config /etc/sysctl.d/99-may-no-coredumps.conf 'fs.suid_dumpable = 0'
  if sysctl -w fs.suid_dumpable=0; then
    ok 'Core size limits set to zero; fs.suid_dumpable disabled.'
  else
    warn 'Core size limits saved; could not apply fs.suid_dumpable live.'
  fi
fi

msg '17/19' 'Ensure pam_wheel Group Exists and Is Empty'
SU_GROUP=may-su-restricted
if ! getent group "$SU_GROUP" >/dev/null; then
  groupadd --system "$SU_GROUP"
fi
su_gid=$(getent group "$SU_GROUP" | cut -d: -f3)
su_members=$(getent group "$SU_GROUP" | cut -d: -f4)
primary_members=$(awk -F: -v gid="$su_gid" '$4 == gid {print $1}' /etc/passwd | paste -sd , -)
if [[ -n $su_members || -n $primary_members ]]; then
  warn "Group $SU_GROUP has users; refusing to apply empty-group restriction."
elif [[ ! -f /etc/pam.d/su ]]; then
  skip '/etc/pam.d/su absent.'
else
  backup /etc/pam.d/su
  # Remove active pam_wheel entries to avoid contradictory group rules; comments retained.
  sed -i -E '/^[[:space:]]*auth[[:space:]].*pam_wheel\.so([[:space:]]|$)/d' /etc/pam.d/su
  # Root's pam_rootok rule remains intact. All non-root su attempts are denied.
  printf '\n# may.sh: block non-root su; dedicated group must remain empty\nauth required pam_wheel.so use_uid group=%s\n' "$SU_GROUP" >> /etc/pam.d/su
  ok "pam_wheel references empty group $SU_GROUP (non-root su now denied)."
fi

msg '18/19' 'Ensure /etc/at.allow Exists'
if [[ ! -e /etc/at.allow ]]; then
  printf 'root\n' > /etc/at.allow
fi
chown root:root /etc/at.allow
chmod 0640 /etc/at.allow
ok '/etc/at.allow exists (existing entries preserved; root-only if newly created).'

msg '19/19' 'Ensure /etc/cron.allow Exists'
if [[ ! -e /etc/cron.allow ]]; then
  printf 'root\n' > /etc/cron.allow
fi
chown root:root /etc/cron.allow
chmod 0640 /etc/cron.allow
ok '/etc/cron.allow exists (existing entries preserved; root-only if newly created).'

msg '12/19' 'Build and Test AIDE Database (performed last to minimize baseline drift)'
if [[ ${MAY_AIDE:-run} == skip ]]; then
  skip 'AIDE disabled for this run via MAY_AIDE=skip.'
elif ! install_packages aide aide-common; then
  warn 'Could not install AIDE packages.'
else
  # Never silently replace an established baseline.
  aide_db=''
  for candidate in /var/lib/aide/aide.db /var/lib/aide/aide.db.gz; do
    if [[ -s $candidate ]]; then aide_db=$candidate; break; fi
  done
  if [[ -z $aide_db ]]; then
    if command -v aideinit >/dev/null 2>&1; then
      echo '  Initializing AIDE baseline; on large filesystems this can take time.'
      if aideinit -y; then
        for extension in '' .gz; do
          if [[ -s /var/lib/aide/aide.db.new$extension ]]; then
            cp -a -- "/var/lib/aide/aide.db.new$extension" "/var/lib/aide/aide.db$extension"
            aide_db="/var/lib/aide/aide.db$extension"
            break
          fi
        done
      fi
    fi
  fi
  if [[ -z $aide_db ]]; then
    warn 'AIDE database was not created; examine aideinit output/configuration.'
  else
    echo "  AIDE baseline: $aide_db"
    if command -v aide.wrapper >/dev/null 2>&1; then
      if aide.wrapper --check; then ok 'AIDE database tested with aide.wrapper.'
      else warn 'AIDE reported differences/errors; inspect output and investigate before rebasing.'; fi
    elif command -v aide >/dev/null 2>&1; then
      if aide --check; then ok 'AIDE database tested.'
      else warn 'AIDE reported differences/errors; inspect output and investigate before rebasing.'; fi
    fi
  fi
fi

printf '\n=== Summary ===\nSuccessful steps: %s\nSkipped: %s\nWarnings: %s\nBackups and detailed log: %s\n' "$OK" "$SKIPPED" "$WARNED" "$BACKUP_DIR"
echo 'Keep the current login session open and TEST a fresh SSH/password login before logging out.'
echo 'Re-run OpenSCAP; container-inapplicable bootloader/kernel findings may remain failed.'
