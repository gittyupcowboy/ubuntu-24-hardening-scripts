# rpcbind_harden.sh

Opinionated rpcbind hardening for Ubuntu 24.04 – disable socket activation, mask units, optionally purge the `rpcbind` package when NFS is not required, and provide a clean backout path if you need to restore it.

This mirrors the style and flow of the other scripts in this repo.

---

## 0. Prerequisites and install

Requirements:

* Ubuntu 24.04
* systemd present
* Run as root (via `sudo`)
* `rpcbind` may or may not be installed

Install and view help:

```bash
chmod +x rpcbind_harden.sh
sudo ./rpcbind_harden.sh --help
````

Help output (equivalent):

```text
Usage: rpcbind_harden.sh [options]

Options:
  -c, --check, --check-only   Check rpcbind status only (no changes)
  -n, --non-interactive       Apply hardening without prompts
      --purge                 Also purge the rpcbind package (when hardening)
  -b, --backout, --restore    Attempt to restore rpcbind (install, unmask, enable)
  -h, --help                  Show this help message

Default (no options):
  Interactive mode - prompts before disabling, masking, and purging.
```

---

## 1. Design goals

* Target platform: Ubuntu 24.04 with systemd.
* Single purpose: minimize rpcbind exposure on hosts that do not need it, with a simple restore path.
* Idempotent and automation friendly.
* Easy to verify and roll back.

This is aimed at general purpose servers that do not intentionally provide NFS or other ONC RPC services.

---

## 2. What it changes

### 2.1 Disables and masks rpcbind units

For each of:

```text
rpcbind.socket
rpcbind.service
```

the script:

* Disables the unit (`systemctl disable`).
* Stops it if it is currently active.
* Masks it so future dependencies cannot start it.

This is equivalent to running:

```bash
sudo systemctl disable --now rpcbind.socket rpcbind.service
sudo systemctl mask rpcbind.socket rpcbind.service
```

when the units exist.

---

### 2.2 Optionally purges the rpcbind package

If requested, the script purges the `rpcbind` package:

```bash
sudo apt-get purge -y rpcbind
```

This is controlled by:

* `--purge` together with `--non-interactive`, or
* an interactive prompt in the default mode.

Purging is recommended only when you know you do not need rpcbind on that host.

---

### 2.3 Verifies exposure on port 111

The script checks for listeners on the standard rpcbind port:

```bash
ss -tulpn | grep -E '(^|[^0-9]):111\b'
```

and reports:

* Whether anything is bound to port 111.
* Whether `rpcbind.service` or `rpcbind.socket` are active or enabled.
* Whether the `rpcbind` package is still installed.

These checks are used to decide whether the system is considered “hardened.”

---

### 2.4 Backout / restore rpcbind

The script can reverse the hardening and restore rpcbind to a usable state:

* Installs the `rpcbind` package if it is missing.
* Unmasks `rpcbind.service` and `rpcbind.socket` if they were masked.
* Enables and starts `rpcbind.socket`.
* Enables `rpcbind.service` so socket activation can manage it.

This is meant for the “oh, something actually needed rpcbind after all” scenario.

---

## 3. What it does not do

* Does **not** reconfigure or remove NFS exports.
* Does **not** edit `/etc/fstab` or any NFS mount definitions.
* Does **not** touch `nfs-common`, `nfs-kernel-server`, or related packages.
* Does **not** modify firewall rules.

If the host is intentionally providing NFS or other RPC based services, you should **not** run this script unless you understand how it will affect those services.

---

## 4. Files and components it touches

* systemd units:

  * `rpcbind.service`
  * `rpcbind.socket`

* dpkg / apt:

  * May purge the `rpcbind` package if requested.
  * May install the `rpcbind` package again in backout mode.

No files under `/etc` are edited directly. All changes to rpcbind behavior are performed through systemd and package management.

---

## 5. Modes and usage

### 5.0 Quick start

```bash
chmod +x rpcbind_harden.sh

# Interactive:
sudo ./rpcbind_harden.sh

# Check only:
sudo ./rpcbind_harden.sh --check

# Non-interactive, no purge:
sudo ./rpcbind_harden.sh --non-interactive

# Non-interactive, also purge rpcbind:
sudo ./rpcbind_harden.sh --non-interactive --purge

# Backout / restore rpcbind:
sudo ./rpcbind_harden.sh --backout
```

You must run as root. The script will exit if it is not run via `sudo` or as root.

---

### 5.1 Interactive mode (default)

```bash
sudo ./rpcbind_harden.sh
```

Flow:

1. Shows current status:

   * `rpcbind` package install state.
   * `rpcbind.service` and `rpcbind.socket` active / enabled / masked.
   * Port 111 listener summary (if `ss` is available).

2. If rpcbind already appears hardened (or not installed), offers to reapply.

3. Prompts to:

   * Disable and mask `rpcbind.service` and `rpcbind.socket`.
   * Optionally purge the `rpcbind` package with `apt-get purge`.

4. Shows post change status and reports whether the system is considered hardened.

Exit code:

* `0` if rpcbind is hardened at the end of the run.
* Non zero on errors or if hardening did not fully succeed.

---

### 5.2 Check only – non interactive

```bash
sudo ./rpcbind_harden.sh --check
# or
sudo ./rpcbind_harden.sh -c
```

Behavior:

* Prints the current package, unit, and port 111 status.
* Does **not** change anything.
* Exits with:

  * `0` if:

    * `rpcbind` is not installed **and** no listener is found on port 111, or
    * `rpcbind` is installed but all rpcbind units are masked and inactive, with no port 111 listener.

  * Non zero otherwise.

Useful for CI, reporting, or scanner tuning.

---

### 5.3 Non interactive harden

```bash
sudo ./rpcbind_harden.sh --non-interactive
sudo ./rpcbind_harden.sh --non-interactive --purge
```

Behavior:

* Disables and masks `rpcbind.service` and `rpcbind.socket` if they exist.
* If `--purge` is supplied, purges the `rpcbind` package via apt-get.
* Prints status before and after changes.
* Exits with:

  * `0` if rpcbind is hardened after the changes.
  * Non zero if not.

Safe for use in automation or configuration management.

---

### 5.4 Backout / restore mode

```bash
sudo ./rpcbind_harden.sh --backout
# or
sudo ./rpcbind_harden.sh --restore
# or
sudo ./rpcbind_harden.sh -b
```

Behavior:

* Installs the `rpcbind` package if it is not currently installed.
* Unmasks `rpcbind.service` and `rpcbind.socket` if they are masked.
* Enables and starts `rpcbind.socket`.
* Enables `rpcbind.service` (socket activation will manage the process).
* Prints package, unit, and port 111 status after changes.

This is the fast way to revert the hardening on a host that turns out to rely on rpcbind or NFS related services.

Note: after backout, you should still confirm that the host’s NFS or RPC use is intentional and secured at the network and application layers.

---

## 6. Compatibility notes

* Assumes a systemd based Ubuntu 24.04 host.
* Uses `ss` for port checks when available. If `ss` is missing, port checking is skipped but unit and package checks still run.
* If the host depends on NFS client or server functionality, you must ensure those requirements are understood before disabling or purging rpcbind.

---

## 7. Quick manual verification

After running hardening:

```bash
# Package status:
dpkg -l rpcbind | grep '^ii' || echo "rpcbind not installed"

# Systemd units:
systemctl status rpcbind.service rpcbind.socket

# Port 111:
ss -tulpn | grep -E '(^|[^0-9]):111\b' || echo "no listener on port 111"
```

Expected:

* `rpcbind` is either not installed, or installed with units masked and inactive.
* No listener is bound to port 111.

After running backout:

```bash
dpkg -l rpcbind | grep '^ii'
systemctl status rpcbind.socket
ss -tulpn | grep -E '(^|[^0-9]):111\b'
```

Expected:

* `rpcbind` package installed.
* `rpcbind.socket` enabled and active.
* Port 111 listening, if rpcbind is in use.

---

## 8. Disclaimer

Use at your own risk. Review and test before deploying to production. If a host intentionally runs NFS or other RPC based services, you may break those services by disabling or purging rpcbind, and you may alter behavior by restoring it without reviewing the broader configuration.

```
```
