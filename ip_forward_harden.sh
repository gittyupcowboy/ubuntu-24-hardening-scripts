#!/usr/bin/env bash
# ip_forward_harden.sh
# Ubuntu 24.04: ensure net.ipv4.ip_forward=0 via /etc/sysctl.d and verify

set -euo pipefail

KEY="net.ipv4.ip_forward"
DESIRED="0"
CONF_DIR="/etc/sysctl.d"
CONF_FILE="${CONF_DIR}/99-ipforward.conf"

MODE="interactive"  # interactive | check | nonint

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
Options:
  -c, --check, --check-only   Check status only (no changes)
  -n, --non-interactive       Apply without prompts (writes file + reloads)
  -h, --help                  Show this help
Default (no options): interactive mode with prompts.
EOF
}

die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
info() { printf "%s\n" "$*"; }

need_root() { [ "$EUID" -eq 0 ] || die "Run as root (sudo)."; }

check_live() {
  local v
  v=$(sysctl -n "$KEY" 2>/dev/null || echo "unknown")
  info "Live kernel value: ${KEY}=${v}"
  [ "$v" = "$DESIRED" ]
}

check_proc() {
  local v="unknown"
  [ -r /proc/sys/net/ipv4/ip_forward ] && v=$(cat /proc/sys/net/ipv4/ip_forward)
  info "/proc value: ${KEY}=${v}"
  [ "$v" = "$DESIRED" ]
}

check_persistent() {
  if [ -f "$CONF_FILE" ] && grep -qE "^\s*${KEY}\s*=\s*${DESIRED}\s*$" "$CONF_FILE"; then
    info "Persistent config OK: ${CONF_FILE} has ${KEY}=${DESIRED}"
    return 0
  fi
  info "Persistent config missing or incorrect at ${CONF_FILE}"
  return 1
}

write_persistent() {
  install -d -m 0755 "$CONF_DIR"
  printf "%s=%s\n" "$KEY" "$DESIRED" > "$CONF_FILE"
  chmod 0644 "$CONF_FILE"
  info "Wrote ${CONF_FILE} with ${KEY}=${DESIRED}"
}

reload_now() {
  info "Reloading sysctl from config files..."
  if sysctl --system >/tmp/sysctl_reload.log 2>&1; then
    grep -E "${KEY}" /tmp/sysctl_reload.log || true
  else
    die "sysctl --system failed. See /tmp/sysctl_reload.log"
  fi
}

summary_status() {
  info "----- verification -----"
  check_live || true
  check_proc || true
  info "systemd-sysctl status (summary):"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --plain --full status systemd-sysctl.service | sed -n '1,8p' || true
  fi
  if check_live && check_proc && check_persistent; then
    info "RESULT: ${KEY} is enforced to ${DESIRED} and active."
    return 0
  fi
  info "RESULT: ${KEY} is not fully enforced."
  return 1
}

prompt() {
  read -r -p "$1 [y/N]: " ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# parse args to align with repo CLI
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--check|--check-only) MODE="check" ;;
    -n|--non-interactive)    MODE="nonint" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

need_root

case "$MODE" in
  check)
    check_persistent || true
    summary_status
    exit $?
    ;;
  nonint)
    check_persistent || write_persistent
    reload_now
    summary_status
    exit $?
    ;;
  interactive)
    info "Checking ${KEY} desired=${DESIRED}"
    if ! check_persistent; then
      if prompt "Create or fix ${CONF_FILE} now?"; then
        write_persistent
      else
        die "Aborted by user."
      fi
    else
      info "No change needed in ${CONF_FILE}"
    fi
    if prompt "Apply immediately with sysctl --system?"; then
      reload_now
    else
      info "Skipping immediate reload. Change will take effect at next boot."
    fi
    summary_status
    exit $?
    ;;
esac
