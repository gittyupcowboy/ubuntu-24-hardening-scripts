#!/usr/bin/env bash
# One shot OpenSSH hardening for Ubuntu 24.04
#
# What this script does (default interactive mode):
#  - Ensures /etc/ssh/sshd_config includes /etc/ssh/sshd_config.d/*.conf
#  - Checks if sshd is already using the hardened crypto profile
#  - Optionally backs up existing sshd_config and 99-strong-crypto.conf
#  - Comments deprecated UsePrivilegeSeparation in sshd_config
#  - Writes a strong crypto drop-in: /etc/ssh/sshd_config.d/99-strong-crypto.conf
#  - Validates sshd configuration syntax
#  - Optionally reloads ssh/sshd to apply changes
#  - Prints effective server side crypto settings from sshd -T
#
# Extra modes:
#  - Check only (non-interactive):   --check / --check-only / -c
#      * Does not modify anything
#      * Exits 0 if hardened, non-zero if not
#      * Prints current crypto-related sshd -T output
#
#  - Non-interactive harden:         --non-interactive / -n
#      * No prompts
#      * Creates backup
#      * Applies changes
#      * Reloads ssh/sshd
#      * Prints results

set -euo pipefail

# Path to main sshd configuration file
MAINCFG="/etc/ssh/sshd_config"

# Path to the hardening drop-in file we manage
DROPIN="/etc/ssh/sshd_config.d/99-strong-crypto.conf"

# Directory to store backups
BACKUP_DIR="/etc/ssh/backup"

# Expected hardened values as reported by `sshd -T`
# These are matched as full lines, so ordering matters.
HARDENED_KEX="kexalgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"
HARDENED_MACS="macs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-64-etm@openssh.com,umac-128-etm@openssh.com"
HARDENED_HOSTKEYS="hostkeyalgorithms ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-256,rsa-sha2-512"

# Mode flags - set from CLI arguments
NON_INTERACTIVE=0
CHECK_ONLY=0

usage() {
  cat << EOF
Usage: $0 [options]

Options:
  -c, --check, --check-only   Check hardening status only (non-interactive, no changes)
  -n, --non-interactive       Apply hardening without prompts (backup + reload)
  -h, --help                  Show this help message

Default (no options):
  Interactive mode - prompts for backup and reload, applies hardening.
EOF
}

# Ensure we are running as root.
# Many operations here touch /etc/ssh and control sshd, so non-root is pointless.
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

# Check whether sshd is already hardened according to our profile.
# Uses `sshd -T` to inspect the effective daemon config.
check_hardened() {
  local out
  if ! out="$(sshd -T 2>/dev/null)"; then
    echo "Warning: sshd -T failed, cannot check hardening status." >&2
    return 1
  fi

  # GSSAPI key exchange and authentication must both be disabled
  echo "$out" | grep -q '^gssapikeyexchange no$' || return 1
  echo "$out" | grep -q '^gssapiauthentication no$' || return 1

  # KEX, MAC, and HostKey algorithms must exactly match our allow lists
  echo "$out" | grep -q "^${HARDENED_KEX}\$" || return 1
  echo "$out" | grep -q "^${HARDENED_MACS}\$" || return 1
  echo "$out" | grep -q "^${HARDENED_HOSTKEYS}\$" || return 1

  # Additional sanity check - make sure no SHA1 MACs remain
  if echo "$out" | grep -q 'hmac-sha1'; then
    return 1
  fi

  return 0
}

# Backup existing configs into /etc/ssh/backup/
# Files are named:
#   /etc/ssh/backup/sshd_config-YYMMDD_HHMMSS.backup
#   /etc/ssh/backup/99-strong-crypto.conf-YYMMDD_HHMMSS.backup
backup_configs() {
  local ts
  ts="$(date +%y%m%d_%H%M%S)"
  echo "==> Creating backup files in ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"

  if [[ -f "${MAINCFG}" ]]; then
    local dst_main="${BACKUP_DIR}/sshd_config-${ts}.backup"
    cp -p "${MAINCFG}" "${dst_main}"
    echo "   Backed up ${MAINCFG} -> ${dst_main}"
  fi

  if [[ -f "${DROPIN}" ]]; then
    local dst_dropin="${BACKUP_DIR}/99-strong-crypto.conf-${ts}.backup"
    cp -p "${DROPIN}" "${dst_dropin}"
    echo "   Backed up ${DROPIN} -> ${dst_dropin}"
  fi
}

# Ensure that sshd_config includes the drop-in directory.
# Without this Include, the 99-strong-crypto.conf file is ignored.
ensure_include_dropin() {
  if [[ ! -f "${MAINCFG}" ]]; then
    echo "==> Warning: ${MAINCFG} not found, skipping Include check."
    return
  fi

  # If an Include line for /etc/ssh/sshd_config.d already exists, do nothing.
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "${MAINCFG}"; then
    echo "==> Include for /etc/ssh/sshd_config.d/*.conf already present in ${MAINCFG}."
    return
  fi

  echo "==> Adding Include /etc/ssh/sshd_config.d/*.conf to ${MAINCFG}..."

  local tmp_file
  tmp_file="$(mktemp)"

  # Insert Include after any leading comment block, or at top otherwise.
  # Logic:
  #  - Skip initial comment lines until we find the first non-# line
  #  - Insert the Include before that line
  #  - If file is only comments or empty, append it at the end
  awk '
    BEGIN { inserted = 0 }
    /^#/ && inserted == 0 { print; next }
    inserted == 0 {
      print "Include /etc/ssh/sshd_config.d/*.conf"
      print
      inserted = 1
      next
    }
    { print }
    END {
      if (inserted == 0) {
        print "Include /etc/ssh/sshd_config.d/*.conf"
      }
    }
  ' "${MAINCFG}" > "${tmp_file}"

  cp "${tmp_file}" "${MAINCFG}"
  rm -f "${tmp_file}"
}

# Comment out deprecated UsePrivilegeSeparation if present.
# Modern OpenSSH ignores it, but some scanners complain if it is still there.
comment_deprecated() {
  if [[ -f "${MAINCFG}" ]]; then
    echo "==> Commenting deprecated UsePrivilegeSeparation in ${MAINCFG} (if present)..."
    sed -i 's/^[[:space:]]*UsePrivilegeSeparation/#&/' "${MAINCFG}"
  fi
}

# Reload ssh/sshd using whatever service name exists on this host.
reload_ssh_service() {
  if systemctl status sshd >/dev/null 2>&1; then
    systemctl reload sshd
  elif systemctl status ssh >/dev/null 2>&1; then
    systemctl reload ssh
  else
    echo "ERROR: Could not find a running sshd/ssh service to reload." >&2
    exit 1
  fi
}

# Write our strong crypto profile drop-in to /etc/ssh/sshd_config.d/99-strong-crypto.conf
# This replaces any existing file at that path.
write_dropin() {
  echo "==> Writing strong crypto drop-in to ${DROPIN}..."
  tee "${DROPIN}" > /dev/null << 'EOF'
# Strong crypto profile for OpenSSH 9.6 on Ubuntu 24.04
#
# File: /etc/ssh/sshd_config.d/99-strong-crypto.conf
#
# After editing this file:
#
# 1) Validate sshd configuration syntax:
#    sudo sshd -t
#
# 2) Reload the SSH daemon to apply changes:
#    sudo systemctl reload sshd || sudo systemctl reload ssh
#
# 3) Verify effective SERVER crypto settings (not the client):
#    sudo sshd -T | grep -Ei 'gss|kexalgorithms|macs|hostkeyalgorithms'
#
# Expected results:
#    GSSAPIKeyExchange no
#    No MACs containing hmac-sha1 or non-etm variants
#    KexAlgorithms, MACs, and HostKeyAlgorithms match the allow list below
#
# Notes:
#    sshd -T shows the merged server config
#    ssh -G is client side and should not be used for validation
#    This file must use UNIX line endings (LF)


# Disable all GSSAPI based key exchange to eliminate SHA1 based groups
GSSAPIAuthentication no
GSSAPIKeyExchange no

# Strong KEX algorithms only
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

# Strong MACs only (all SHA1 and non-etm removed)
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-64-etm@openssh.com,umac-128-etm@openssh.com

# Strong hostkey algorithms only
HostKeyAlgorithms ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-256,rsa-sha2-512
EOF
}

# Validate sshd configuration and optionally reload the service.
validate_and_reload() {
  echo "==> Validating sshd configuration..."
  sshd -t
  echo "==> sshd configuration syntax OK."

  # Non-interactive mode - always reload without asking
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "==> Non-interactive mode - reloading ssh/sshd..."
    reload_ssh_service
    return
  fi

  # Interactive mode - ask before reload
  read -r -p "Reload sshd now to apply changes? [Y/n]: " ans
  ans="${ans:-Y}"
  if [[ "${ans}" =~ ^[Yy]$ ]]; then
    echo "==> Reloading ssh/sshd..."
    reload_ssh_service
  else
    echo "==> Skipping sshd reload at user request."
    return
  fi
}

# Show effective crypto related settings from sshd -T for quick visual verification.
show_effective() {
  echo "==> Effective server side crypto settings:"
  sshd -T | grep -Ei 'gss|kexalgorithms|macs|hostkeyalgorithms' || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--check|--check-only)
        CHECK_ONLY=1
        shift
        ;;
      -n|--non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_root

  # Check only mode - do not modify anything, just report status and exit.
  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    echo "==> Check only mode - no changes will be made."
    if check_hardened; then
      echo "==> sshd is hardened according to this profile."
      show_effective
      exit 0
    else
      echo "==> sshd is NOT fully hardened according to this profile."
      show_effective
      exit 1
    fi
  fi

  echo "==> Checking current sshd hardening status..."
  if check_hardened; then
    echo "==> sshd already matches the hardened profile."
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      echo "==> Non-interactive mode - exiting without changes."
      exit 0
    fi
    read -r -p "Do you still want to overwrite the drop-in and reapply? [y/N]: " cont
    cont="${cont:-N}"
    if [[ ! "${cont}" =~ ^[Yy]$ ]]; then
      echo "Exiting without changes."
      exit 0
    fi
  else
    echo "==> sshd is not fully hardened yet. Proceeding with hardening steps."
  fi

  # Offer to back up configs before touching them in interactive mode.
  # In non-interactive mode, always create a backup.
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "==> Non-interactive mode - creating backup without prompting."
    backup_configs
  else
    read -r -p "Create backup of existing configs before changes? [Y/n]: " backup
    backup="${backup:-Y}"
    if [[ "${backup}" =~ ^[Yy]$ ]]; then
      backup_configs
    else
      echo "==> Skipping backup at user request."
    fi
  fi

  # Ensure the main sshd_config actually includes the drop-in directory.
  ensure_include_dropin

  # Comment deprecated options and write the hardened drop-in.
  comment_deprecated
  write_dropin

  # Validate configuration and reload ssh/sshd (according to mode).
  validate_and_reload

  # Show effective crypto configuration after our changes.
  show_effective

  echo "==> Done."
}

main "$@"
