# Ubuntu 24 hardening scripts

Opinionated hardening for Ubuntu 24.0x  –  strong OpenSSH crypto, sane defaults, security friendly sysctl, and minimized rpcbind exposure.

## Scripts

* `ssh_harden_full.sh`  –  lock down SSH, modern ciphers and MACs, safe defaults, verification.
* `ip_forward_harden.sh`  –  persist `net.ipv4.ip_forward=0`, reload, verify, and check for conflicts.
* `rpcbind_harden.sh`  –  disable and mask rpcbind units, optionally purge the package, and provide a backout path.

## Quick start

```bash
git clone https://github.com/gittyupcowboy/ubuntu-24-hardening-scripts.git
cd ubuntu-24-hardening-scripts
chmod +x *.sh
````

### SSH harden

Interactive (prompts and shows a final verification):

```bash
sudo ./ssh_harden_full.sh
```

Non-interactive:

```bash
sudo ./ssh_harden_full.sh --non-interactive
```

Check only:

```bash
sudo ./ssh_harden_full.sh --check
```

### IPv4 forwarding harden

Interactive:

```bash
sudo ./ip_forward_harden.sh
```

Non-interactive:

```bash
sudo ./ip_forward_harden.sh --non-interactive
```

Check only:

```bash
sudo ./ip_forward_harden.sh --check
```

### rpcbind harden

Interactive:

```bash
sudo ./rpcbind_harden.sh
```

Non-interactive:

```bash
sudo ./rpcbind_harden.sh --non-interactive
```

Check only:

```bash
sudo ./rpcbind_harden.sh --check
```

Backout / restore:

```bash
sudo ./rpcbind_harden.sh --backout
```

## What these scripts do

* Write drop-in config under `/etc` with clear numeric prefixes.
* Apply changes immediately where possible.
* Print a concise “what changed” and “what is effective now” summary.

## Per script details

### `ssh_harden_full.sh`

* Ensures `/etc/ssh/sshd_config` includes `/etc/ssh/sshd_config.d/*.conf`.
* Writes a strong-crypto drop-in at `/etc/ssh/sshd_config.d/99-strong-crypto.conf` (modern KEX, ciphers, MACs).
* Comments out deprecated `UsePrivilegeSeparation` if present, without rewriting the rest of the file.
* Validates the resulting config with `sshd -T` / `sshd -t` and only reloads on a clean config.
* Creates timestamped backups under `/etc/ssh/backup/` so you can manually roll back if needed.

### `ip_forward_harden.sh`

* Writes `/etc/sysctl.d/99-ipforward.conf` with `net.ipv4.ip_forward=0`.
* Reloads sysctl via `sysctl --system` and checks the live value.
* Verifies `/proc/sys/net/ipv4/ip_forward` and the effective sysctl view agree.
* Keeps changes isolated to IPv4 forwarding – no other kernel networking tuning.

### `rpcbind_harden.sh`

* Checks whether the `rpcbind` package is installed and how its units are wired.
* Disables and masks `rpcbind.service` and `rpcbind.socket` so they cannot be started accidentally.
* Optionally purges the `rpcbind` package via `apt-get purge` when you are sure it is not needed.
* Checks for listeners on port 111 to confirm rpcbind is no longer exposed.
* Provides a backout mode that reinstalls `rpcbind` (if needed), unmasks the units, and re-enables `rpcbind.socket` so NFS / ONC RPC workloads can be restored quickly.

## What they do not do

* No mass rewrites of unrelated services.
* No kernel tuning outside the stated scope.
* No assumptions about Docker, Kubernetes, or cloud images.

## Safety and verification

* Idempotent  –  safe to re-run.
* “Check only” mode to confirm current state without changes.
* Clear exit codes for CI.

## Requirements

* Ubuntu 24.04 or 24.10
* systemd
* Run as root (use `sudo`)

## Contributing

Open an issue or PR. Keep changes small, auditable, and easy to roll back.

## License

GPL-3.0

```
```
