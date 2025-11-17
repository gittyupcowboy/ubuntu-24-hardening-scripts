# ubuntu-24-hardening-scripts

# ssh_harden_full.sh README.md (placeholder readme at this time)

Opinionated OpenSSH hardening for **Ubuntu 24.04 (OpenSSH 9.6)**.

This script is meant for administrators who want a **repeatable, auditable** way to:

* Kill deprecated OpenSSH options that cause scanner noise.
* Remove weak crypto (SHA1 MACs, legacy host keys).
* Enforce a clean, modern SSH server profile.
* Verify, in a deterministic way, that the daemon is actually using that profile.

It is idempotent – you can run it multiple times – and supports both interactive and non interactive modes.

> **Status / support**
>
> - **Tested only on Ubuntu 24.04** with the stock OpenSSH 9.6 and systemd.
> - It *may* work elsewhere, but you run it **at your own risk**.
> - Always review the script before using it on non lab systems.

---

## 0. Prerequisites and install

Requirements:

* Ubuntu 24.04 with:
  - `openssh-server` installed.
  - systemd managing SSH (`sshd.service` or `ssh.service`).
* You must run the script as **root** (via `sudo`).

Install / first run:

```bash
chmod +x ssh_harden_full.sh
sudo ./ssh_harden_full.sh --help
````

Help output (equivalent):

```text
Usage: ssh_harden_full.sh [options]

Options:
  -c, --check, --check-only   Check hardening status only (non-interactive, no changes)
  -n, --non-interactive       Apply hardening without prompts (backup + reload)
  -h, --help                  Show this help message

Default (no options):
  Interactive mode - prompts for backup and reload, applies hardening.
```

---

## 1. Design goals

This script is intentionally narrow in scope:

* Target platform: **Ubuntu 24.04** with the stock OpenSSH 9.6 and systemd.
* No magic auto-tuning. It applies **one** well defined hardening profile.
* Easy to drop into config management, CI checks, or one off remediation runs.
* Easy for a random admin to read and understand in a few minutes.

It does **not** try to implement every CIS / STIG / hardening benchmark. It focuses on:

* Deprecated options that break scanners.
* SHA1 and legacy crypto that you should not be using in 2025.
* Ensuring `sshd_config.d` drop ins are actually honored.

Use it as one building block in your hardening, not as a full benchmark implementation.

---

## 2. What it changes (functional summary)

### 2.1 Ensures `sshd_config.d` drop-ins are loaded

In `/etc/ssh/sshd_config`, the script makes sure there is an `Include` line:

```conf
Include /etc/ssh/sshd_config.d/*.conf
```

If it does not exist, the script inserts it near the top of the file.

Without this, `/etc/ssh/sshd_config.d/99-strong-crypto.conf` is ignored.

---

### 2.2 Comments deprecated `UsePrivilegeSeparation`

If `UsePrivilegeSeparation` is present in `/etc/ssh/sshd_config`, it is commented:

```conf
#UsePrivilegeSeparation sandbox
```

Modern OpenSSH ignores this option, but scanners still flag it as deprecated.
Commenting it out is safe and removes the noise.

---

### 2.3 Installs a strong crypto drop-in

The script creates or overwrites:

```text
/etc/ssh/sshd_config.d/99-strong-crypto.conf
```

with the following core settings:

```conf
# Disable all GSSAPI based key exchange to eliminate SHA1 based groups
GSSAPIAuthentication no
GSSAPIKeyExchange no

# Strong KEX algorithms only
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

# Strong MACs only (all SHA1 and non-etm removed)
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-64-etm@openssh.com,umac-128-etm@openssh.com

# Strong hostkey algorithms only
HostKeyAlgorithms ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-256,rsa-sha2-512
```

That means:

* No GSSAPI key exchange is allowed.
* No SHA1 MACs are allowed.
* No RSA-SHA1 / DSA host keys are allowed.
* Only modern, widely supported algorithms remain.

PAM and Duo via PAM are **not** touched – `UsePAM` and `/etc/pam.d/sshd` are left alone.

> **GSSAPI KEX note**
>
> On this OpenSSH version, `sshd -T` will still show a non empty `gssapikexalgorithms` line (including SHA1 variants) even when `GSSAPIAuthentication no` and `GSSAPIKeyExchange no` are set.
> Those values are in a dead code path and cannot be negotiated in practice. Fixing the *printout* would require patching OpenSSH itself, not sshd_config tweaks.
> This behavior is present on both fresh Ubuntu 24.04 installs and systems upgraded from 22.04; it is a quirk of OpenSSH 9.6p1’s sshd -T output, not of the upgrade process.
---

### 2.4 Validates and reloads SSH

After writing the drop in:

* Runs `sshd -t` to validate configuration syntax.
* In interactive mode, prompts whether to reload.
* In non interactive mode, reloads automatically.

Reload behavior is smart:

* If `sshd.service` exists and is running, it uses:

  ```bash
  systemctl reload sshd
  ```

* Else if `ssh.service` exists and is running, it uses:

  ```bash
  systemctl reload ssh
  ```

If neither exists / is running, it fails loudly instead of silently doing nothing.

No restart, no session drop – this is a reload, not a stop / start.

---

### 2.5 Verifies effective crypto

Finally, the script prints a filtered view of `sshd -T`:

```bash
sshd -T | grep -Ei 'gss|kexalgorithms|macs|hostkeyalgorithms'
```

This shows what the **daemon is actually using**, after includes and defaults are merged.

---

## 3. What it does not do

* Does **not** change:

  * `UsePAM`
  * `PasswordAuthentication`
  * `PubkeyAuthentication`
  * Anything under `/etc/pam.d/*`
* Does not modify any Duo configuration. Duo via PAM (`pam_duo.so`) continues to work.
* Does not configure ciphers, banners, or SSH access control.
* Does not support non systemd or non Ubuntu 24.04 environments out of the box.

If you rely on Kerberos / GSSAPI SSH SSO, this script is **not** for those hosts unless you intentionally want to disable that behavior.

---

## 4. Files it touches

* **Reads and edits:**

  * `/etc/ssh/sshd_config`

* **Writes or overwrites:**

  * `/etc/ssh/sshd_config.d/99-strong-crypto.conf`

* **Creates backups in:**

  * `/etc/ssh/backup/`

    with names like:

    * `/etc/ssh/backup/sshd_config-YYMMDD_HHMMSS.backup`
    * `/etc/ssh/backup/99-strong-crypto.conf-YYMMDD_HHMMSS.backup`

Backups live in a separate directory with a non `.conf` extension, so they are never included by normal `Include /etc/ssh/sshd_config.d/*.conf` patterns.

Nothing else under `/etc` is modified.

---

## 5. Modes and usage

### 5.0 Quick start

```bash
chmod +x ssh_harden_full.sh

# Interactive harden:
sudo ./ssh_harden_full.sh

# Check only:
sudo ./ssh_harden_full.sh --check

# Non-interactive harden:
sudo ./ssh_harden_full.sh --non-interactive
```

You must run as root (or via `sudo`). The script will exit otherwise.

---

### 5.1 Interactive harden (default)

Prompts for backup and reload.

```bash
sudo ./ssh_harden_full.sh
```

Flow:

1. Checks whether the current `sshd -T` output already matches the hardened profile.
2. If it is already hardened:

   * Asks if you still want to reapply.
3. Asks whether to create backups under `/etc/ssh/backup/`.
4. Ensures the `Include` line exists.
5. Comments `UsePrivilegeSeparation` if present.
6. Writes the `99-strong-crypto.conf` drop in.
7. Validates with `sshd -t`.
8. Asks if you want to reload SSH (`sshd` or `ssh`).
9. Prints the effective crypto view from `sshd -T`.

---

### 5.2 Check only – non interactive

Just verify status. No changes. Useful for CI, reporting, or scanner tuning.

```bash
sudo ./ssh_harden_full.sh --check
# or
sudo ./ssh_harden_full.sh -c
```

Behavior:

* Runs the internal `check_hardened` function against `sshd -T`.
* Prints the crypto view from `sshd -T`.
* Exits with:

  * `0` if the server matches the hardened profile.
  * non zero if it does not.

---

### 5.3 Non interactive harden

One shot, no prompts, safe for automation.

```bash
sudo ./ssh_harden_full.sh --non-interactive
# or
sudo ./ssh_harden_full.sh -n
```

Behavior:

* If already hardened:

  * Exits cleanly without making changes.
* If not hardened:

  * Creates backups automatically in `/etc/ssh/backup/`.
  * Ensures `Include` is present.
  * Comments `UsePrivilegeSeparation` if needed.
  * Writes the strong crypto drop in.
  * Validates with `sshd -t`.
  * Reloads SSH (`sshd` or `ssh`) without asking.
  * Prints the effective crypto view.

Exit code is non zero only on actual errors (failed validation, reload, etc.).

---

## 6. Compatibility notes

### PAM and Duo

* The script does **not** touch `UsePAM` or `/etc/pam.d/sshd`.
* Duo via PAM (`pam_duo.so`) keeps working as before.
* The only auth-related knobs changed are:

  * `GSSAPIAuthentication`
  * `GSSAPIKeyExchange`

### Legacy clients

* Only modern KEX, MAC, and host key algorithms are allowed.
* Very old SSH clients, embedded devices, or legacy network gear that only support SHA1 MACs or RSA-SHA1 may fail to connect.
* For normal Linux / macOS / Windows 10+ OpenSSH or PuTTY clients, this profile is fine.

### Service unit name (`ssh` vs `sshd`)

* Different Ubuntu installs may expose SSH as `sshd.service` or `ssh.service`, especially across upgrades.
* The script dynamically chooses:

  * `systemctl reload sshd` if `sshd` is present and running.
  * Otherwise `systemctl reload ssh` if `ssh` is present and running.
* If neither is available, the script fails with a clear error instead of pretending to succeed.

---

## 7. Customizing the profile

Two key places to adjust if you want a slightly different profile:

1. **Drop-in content**

   Edit the template inside `write_dropin()` in the script.

2. **Hardening check**

   Update:

   ```bash
   HARDENED_KEX
   HARDENED_MACS
   HARDENED_HOSTKEYS
   ```

   to match any new algorithm sets you allow. The check logic expects `sshd -T` lines to match these exactly.

If you change the drop in but not the `HARDENED_*` variables, `--check` and the “already hardened” detection will report “not hardened” even though your config may still be secure.

---

## 8. Quick verification steps

After running any mode that applies changes:

```bash
sudo sshd -T | grep -Ei 'gss|kexalgorithms|macs|hostkeyalgorithms'
```

You should see:

* `gssapiauthentication no`
* `gssapikeyexchange no`
* A `kexalgorithms` line matching the modern list in the script.
* A `macs` line with only SHA2 / UMAC ETM values.
* A `hostkeyalgorithms` line without RSA-SHA1 or DSA.
* A `gssapikexalgorithms` line that **may still mention SHA1**, but is irrelevant because GSSAPI auth and key exchange are both disabled.

At that point, the box is using the intended profile and should stop whining about SHA1 and deprecated options in Qualys or similar scanners.

---

## 9. Disclaimer

This script is provided on a **best-effort** basis:

* No warranty, no guarantee, no support contract.
* You are responsible for:

  * Reviewing the script.
  * Testing in non production first.
  * Ensuring it fits your environment and policies.

If you manage critical systems, treat this as a reference implementation and adapt it through your normal change-control pipeline.
Do not blindly paste it into prod and then act surprised.

## 10. Sources & Additional reading
* https://success.qualys.com/support/s/article/000007997
