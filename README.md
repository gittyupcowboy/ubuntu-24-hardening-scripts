# Ubuntu 24 hardening scripts

Opinionated hardening for Ubuntu 24.0x  –  strong OpenSSH crypto, sane defaults, and security friendly sysctl.

## Scripts

* `ssh_harden_full.sh`  –  lock down SSH, modern ciphers and MACs, safe defaults, verification.
* `ip_forward_harden.sh`  –  persist `net.ipv4.ip_forward=0`, reload, verify, and check for conflicts.

## Quick start

```bash
git clone https://github.com/gittyupcowboy/ubuntu-24-hardening-scripts.git
cd ubuntu-24-hardening-scripts
chmod +x *.sh
```

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

## What these scripts do

* Write drop-in config under `/etc` with clear numeric prefixes.
* Apply changes immediately where possible.
* Print a concise “what changed” and “what is effective now” summary.

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
