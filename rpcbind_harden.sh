#!/usr/bin/env bash
# rpcbind_harden.sh
#
# Ubuntu 24.04: minimize rpcbind exposure when NFS is not required.
#
# What this script does (default interactive mode):
#  - Detects whether the rpcbind package is installed
#  - Shows systemd status for rpcbind.service and rpcbind.socket
#  - Optionally disables and stops rpcbind units
#  - Optionally masks rpcbind units to prevent future activation
#  - Optionally purges the rpcbind package via apt-get
#  - Verifies that port 111 is not listening
#
# Extra modes:
#  - Check only (non-interactive):   --check / --check-only / -c
#      * Does not modify anything
#      * Exits 0 if rpcbind is effectively disabled (or not installed)
#      * Exits non-zero otherwise
#
#  - Non-interactive harden:         --non-interactive / -n
#      * No prompts
#      * Disables and masks rpcbind units if present
#      * Optionally purges rpcbind when --purge is given
#      * Verifies port 111
#
#  - Backout / restore:              --backout / --restore / -b
#      * Installs rpcbind if needed
#      * Unmasks rpcbind units
#      * Enables and starts rpcbind.socket
#      * Prints status and port 111 check

set -euo pipefail

RPC_PACKAGE="rpcbind"
UNITS=("rpcbind.socket" "rpcbind.service")

MODE="interactive"  # interactive | check | nonint | backout
PURGE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -c, --check, --check-only   Check rpcbind status only (no changes)
  -n, --non-interactive       Apply hardening without prompts
      --purge                 Also purge the rpcbind package (when hardening)
  -b, --backout, --restore    Attempt to restore rpcbind (install, unmask, enable)
  -h, --help                  Show this help message

Default (no options):
  Interactive mode - prompts before disabling, masking, and purging.
EOF
}

die() {
  printf "ERROR: %s\n" "$*" >&2
  exit 1
}

info() {
  printf "%s\n" "$*"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "This script must be run as root (use sudo)."
  fi
}

have_rpcbind_pkg() {
  if dpkg-query -W -f='${Status}' "${RPC_PACKAGE}" 2>/dev/null | grep -q 'install ok installed'; then
    return 0
  fi
  return 1
}

unit_exists() {
  local unit="$1"
  systemctl list-unit-files --type=service --type=socket --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -qx "${unit}"
}

unit_is_active() {
  local unit="$1"
  if ! unit_exists "${unit}"; then
    return 1
  fi
  systemctl is-active --quiet "${unit}"
}

unit_is_masked() {
  local unit="$1"
  if ! unit_exists "${unit}"; then
    return 0
  fi
  local out
  out="$(systemctl is-enabled "${unit}" 2>&1 || true)"
  printf '%s\n' "${out}" | grep -q 'masked'
}

print_status() {
  info "==> rpcbind package status:"
  if have_rpcbind_pkg; then
    dpkg-query -W -f='  ${Package} ${Version} ${Status}\n' "${RPC_PACKAGE}" 2>/dev/null || \
      info "  ${RPC_PACKAGE} appears installed, but dpkg-query failed."
  else
    info "  ${RPC_PACKAGE} is not installed."
  fi

  info ""
  info "==> systemd unit status:"
  local u
  for u in "${UNITS[@]}"; do
    if unit_exists "${u}"; then
      local active enabled
      active="$(systemctl is-active "${u}" 2>/dev/null || echo "unknown")"
      enabled="$(systemctl is-enabled "${u}" 2>/dev/null || echo "unknown")"
      info "  ${u}: active=${active}, enabled=${enabled}"
    else
      info "  ${u}: not present"
    fi
  done

  info ""
  info "==> port 111 listener check:"
  check_port_111 || true
}

check_port_111() {
  if command -v ss >/dev/null 2>&1; then
    if ss -tulpn 2>/dev/null | grep -qE '(^|[^0-9]):111\b'; then
      info "  Port 111 appears to be listening:"
      ss -tulpn 2>/dev/null | grep -E '(^|[^0-9]):111\b' || true
      # Listener present - treat as exposed
      return 1
    fi
    info "  No listener detected on port 111."
    return 0
  fi

  info "  ss(8) not available - skipping port 111 check."
  return 0
}

check_hardened() {
  # Acceptable states:
  #  - rpcbind package not installed and port 111 not listening
  #  - rpcbind installed, but all units are masked and not active, and port 111 not listening
  if ! check_port_111; then
    return 1
  fi

  if ! have_rpcbind_pkg; then
    # Package gone and no port 111 listener - fine.
    return 0
  fi

  local u
  for u in "${UNITS[@]}"; do
    if unit_exists "${u}"; then
      if unit_is_active "${u}"; then
        return 1
      fi
      if ! unit_is_masked "${u}"; then
        return 1
      fi
    fi
  done

  return 0
}

disable_and_mask_units() {
  info "==> Disabling and masking rpcbind units..."
  local u
  for u in "${UNITS[@]}"; do
    if unit_exists "${u}"; then
      # disable and stop
      if systemctl is-active --quiet "${u}"; then
        systemctl disable --now "${u}" || true
      else
        systemctl disable "${u}" 2>/dev/null || true
      fi
      # mask
      systemctl mask "${u}" 2>/dev/null || true
    fi
  done
}

purge_rpcbind_pkg() {
  if ! have_rpcbind_pkg; then
    info "==> ${RPC_PACKAGE} is already not installed. Skipping purge."
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get not found - cannot purge ${RPC_PACKAGE}."
  fi

  info "==> Purging ${RPC_PACKAGE} via apt-get..."
  DEBIAN_FRONTEND=noninteractive apt-get purge -y "${RPC_PACKAGE}"
  info "==> apt-get purge completed."
}

backout_rpcbind() {
  info "==> Backout mode - restoring rpcbind."

  if have_rpcbind_pkg; then
    info "==> rpcbind package is already installed."
  else
    if ! command -v apt-get >/dev/null 2>&1; then
      die "apt-get not found - cannot install ${RPC_PACKAGE}."
    fi
    info "==> rpcbind package is not installed. Installing..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${RPC_PACKAGE}"
  fi

  local u
  for u in "${UNITS[@]}"; do
    if unit_exists "${u}"; then
      if unit_is_masked "${u}"; then
        info "==> Unmasking ${u}"
        systemctl unmask "${u}"
      fi
    fi
  done

  if unit_exists "rpcbind.socket"; then
    info "==> Enabling and starting rpcbind.socket"
    systemctl enable --now "rpcbind.socket"
  else
    info "==> rpcbind.socket unit not found."
  fi

  if unit_exists "rpcbind.service"; then
    info "==> Enabling rpcbind.service"
    systemctl enable "rpcbind.service" 2>/dev/null || true
  fi

  info ""
  info "==> Post backout status:"
  print_status

  # Here, check_port_111 returns 1 when a listener is present.
  if check_port_111; then
    info "RESULT: rpcbind restored. No listener detected on port 111 (this may be expected in some setups)."
  else
    info "RESULT: rpcbind restored. Listener on port 111 detected."
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local ans
  read -r -p "${prompt} [${default}/$( [ "${default}" = "Y" ] && echo "n" || echo "y" )]: " ans
  ans="${ans:-${default}}"
  case "${ans}" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c|--check|--check-only)
        MODE="check"
        ;;
      -n|--non-interactive)
        MODE="nonint"
        ;;
      --purge)
        PURGE=1
        ;;
      -b|--backout|--restore)
        MODE="backout"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  require_root

  case "${MODE}" in
    check)
      info "==> Check only mode - no changes will be made."
      print_status
      if check_hardened; then
        info ""
        info "RESULT: rpcbind is effectively disabled or not installed."
        exit 0
      fi
      info ""
      info "RESULT: rpcbind is still exposed or partially enabled."
      exit 1
      ;;
    nonint)
      info "==> Non-interactive harden - disabling rpcbind exposure without prompts."
      print_status
      disable_and_mask_units
      if [ "${PURGE}" -eq 1 ]; then
        purge_rpcbind_pkg
      else
        info "==> Skipping package purge (no --purge flag)."
      fi
      info ""
      info "==> Post-change status:"
      print_status
      if check_hardened; then
        info "RESULT: rpcbind hardening complete."
        exit 0
      fi
      info "RESULT: rpcbind is not fully hardened. Review status above."
      exit 1
      ;;
    interactive)
      info "==> Interactive mode - review and confirm changes."
      print_status

      if check_hardened; then
        info ""
        info "rpcbind already appears hardened (or not installed)."
        if ! prompt_yes_no "Reapply hardening anyway?" "N"; then
          info "Exiting without changes."
          exit 0
        fi
      fi

      if prompt_yes_no "Disable and mask rpcbind.service and rpcbind.socket now?" "Y"; then
        disable_and_mask_units
      else
        die "Aborted by user before disabling rpcbind."
      fi

      if have_rpcbind_pkg; then
        if prompt_yes_no "Purge the rpcbind package via apt-get now?" "N"; then
          purge_rpcbind_pkg
        else
          info "Skipping package purge at user request."
        fi
      fi

      info ""
      info "==> Post-change status:"
      print_status
      if check_hardened; then
        info "RESULT: rpcbind hardening complete."
        exit 0
      fi
      info "RESULT: rpcbind is not fully hardened. Review status above."
      exit 1
      ;;
    backout)
      backout_rpcbind
      ;;
    *)
      die "Internal error: unknown MODE=${MODE}"
      ;;
  esac
}

main "$@"
