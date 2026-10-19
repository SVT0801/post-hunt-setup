# PostHunt setup

One-file installer for a self-hosted PostHunt server (Debian 13). It prepares the server, downloads a release from the private release catalog, verifies its checksums and starts the stack in Docker.

Installer protocol: **1**. A release whose `manifest.json` needs a newer protocol is refused — download a fresh copy of this file.

## Download

```bash
curl -fsSLO https://raw.githubusercontent.com/SVT0801/post-hunt-setup/main/posthunt-setup.sh
sha256sum posthunt-setup.sh   # compare with SHA256 below
```

SHA256 of this copy:

```text
0cbd6cc4f63a5b0656022578229b72ce1994d51fcdb9d2c61b2651158f01bc64  posthunt-setup.sh
```

## Commands

| Step | Command | Who |
|---|---|---|
| 1. Prepare | `sudo bash posthunt-setup.sh prepare ~/<key>.pub` | admin with sudo; creates user `posthunt` (docker group, no sudo), firewall 22/80/443, fail2ban, key-only SSH, Docker |
| 2. Check | `bash posthunt-setup.sh check --phase pre` | read-only, no sudo |
| 3. Install | `bash posthunt-setup.sh install --domain portal.example.com --version vX.Y.Z` | user `posthunt`, no sudo |
| 4. Check | `bash posthunt-setup.sh check --phase post --domain portal.example.com` | read-only, no sudo |
| Report | `bash posthunt-setup.sh report` | send the output to your PostHunt contact; secrets are masked |

`install` options: `--tls self-signed` (default; fine behind Cloudflare SSL "Full") or `--tls letsencrypt --email admin@example.com` (the DNS record must point to the server, port 80 reachable).

## Catalog token

You receive a read-only token for the release catalog from PostHunt through a password manager or another secure channel — never by e-mail or chat.

- `install` asks for it with hidden input, or reads `POSTHUNT_CATALOG_TOKEN` from the environment. It is never passed as a command-line argument and never printed.
- It is stored on the server in `~/post-hunt/env/catalog.token` (mode 600) for later updates.

## Server layout

```text
~/post-hunt/
  releases/<version>/   unpacked releases, the last 3 are kept
  current -> releases/<version>
  supabase/             database stack; data lives in a Docker volume
  env/                  generated secrets and certificates (700 / 600)
  state/                installed.json, deployed.log
  backups/              pg_dump before every install over an existing database
```

Secrets of the stack are generated on the server during the first `install`. Nothing is copied from a developer machine.

## Source

This file is a byte-for-byte copy of `backend/deploy/setup/posthunt-setup.sh` from the private PostHunt project. Do not edit it here.
