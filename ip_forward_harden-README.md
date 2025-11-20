# ip_forward_harden.sh

Opinionated IPv4 forwarding hardening for Ubuntu 24.04 – persist `net.ipv4.ip_forward=0`, verify live kernel state, and scan for conflicts. Mirrors the style and flow of the other scripts in this repo.

---

## 0. Prerequisites and install

Requirements:

* Ubuntu 24.04
* systemd present
* Run as root

Install and view help:

```bash
chmod +x ip_forward_harden.sh
sudo ./ip_forward_harden.sh --help
```

Help output:

```
Usage: ip_forward_harden.sh [options]
Options:
  -c, --check, --check-only   Check status only (no changes)
  -n, --non-interactive       Apply without prompts (writes file + reloads)
  -h, --help                  Show this help
Default (no options): interactive mode with prompts.
```

---

## 1. Design goals

* Target platform: Ubuntu 24.04 with systemd
* Single purpose: enforce IPv4 forwarding off
* Idempotent and automation friendly
* Verifiable output

---

## 2. What it changes

### 2.1 Creates or fixes a sysctl drop-in

Writes:

```
/etc/sysctl.d/99-ipforward.conf
```

with:

```
net.ipv4.ip_forward=0
```

### 2.2 Reloads kernel sysctls

Applies immediately with:

```
sysctl --system
```

### 2.3 Verifies effective state

Prints:

* `sysctl net.ipv4.ip_forward`
* `/proc/sys/net/ipv4/ip_forward`
* Summary of `systemd-sysctl` service status

---

## 3. What it does not do

* No edits to unrelated sysctl keys
* No changes to Docker, Kubernetes, or other services that may flip forwarding
* No IPv6 management

---

## 4. Files it touches

* Writes or overwrites:

  * `/etc/sysctl.d/99-ipforward.conf`

Nothing else under `/etc` is modified.

---

## 5. Modes and usage

### 5.0 Quick start

```bash
chmod +x ip_forward_harden.sh

# Interactive
sudo ./ip_forward_harden.sh

# Check only
sudo ./ip_forward_harden.sh --check

# Non-interactive
sudo ./ip_forward_harden.sh --non-interactive
```

Must run as root.

### 5.1 Interactive mode

Prompts before creating the drop-in and before reloading. Flow:

1. Checks live kernel value and `/proc`
2. Checks for the correct drop-in
3. Prompts to create or fix if missing
4. Prompts to apply with `sysctl --system`
5. Prints verification summary

### 5.2 Check only

No changes. Verifies the three checks and exits with non-zero if not enforced:

```bash
sudo ./ip_forward_harden.sh --check
```

### 5.3 Non-interactive

Applies changes without prompts, reloads, and verifies:

```bash
sudo ./ip_forward_harden.sh --non-interactive
```

Exit code is non-zero only on errors.

---

## 6. Compatibility notes

* Uses a numeric prefix so the drop-in wins later in lexical order
* If other software forces `net.ipv4.ip_forward=1` at runtime, the verification will expose it

---

## 7. Quick manual verification

```bash
sysctl net.ipv4.ip_forward
cat /proc/sys/net/ipv4/ip_forward
systemctl status systemd-sysctl | sed -n '1,8p'
```

Expected values are `0` for both sysctl and `/proc`, and a clean `systemd-sysctl` status.

---

## 8. Disclaimer

Use at your own risk. Review and test before deploying to production.
