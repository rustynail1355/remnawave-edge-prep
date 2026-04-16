# remnawave-edge-prep

Pre-requisite bootstrap script for VPN edge nodes (Ubuntu 24.04 LTS).

Takes a **fresh Ubuntu 24.04 VPS** and turns it into a hardened base, ready for
further configuration of a VLESS + AmneziaWG + AdGuard Home + MTProxy stack.

## What it does

- Installs base system utilities (`curl`, `jq`, `git`, `htop`, `tcpdump`, `mtr-tiny`, ...)
- Installs security tooling (`nftables`, `fail2ban`, `unattended-upgrades`)
- Installs infrastructure (`chrony`, `logrotate`, `rsyslog`)
- Creates user `admin` — for a human operator (`sudo` with password)
- Creates user `claude` — for automation (`sudo NOPASSWD`, SSH pubkey only)
- Disables `root` SSH login, locks `root` password
- Applies a baseline nftables ruleset (SSH-only, optional IP whitelist)
- Enables `fail2ban` for SSH (maxretry=5, bantime=1h)
- Prints a full **inventory report** at the end (hardware, installed packages,
  user credentials, connection info) — copy/paste friendly

## What it does NOT do

- Does **not** install Docker / AmneziaWG / AdGuard Home / MTProxy / Xray —
  that is a separate step (main installer, not this script)
- Does **not** open any ports beyond SSH
- Does **not** configure VPN tunneling, NAT, or policy routing

## Requirements

- **Ubuntu 24.04 LTS** (noble) — the script will refuse to run on anything else
- Root access (script checks `EUID == 0`)
- Internet access (to `apt` mirrors)

## Quick start

On a fresh VPS, logged in as root:

```bash
curl -fsSL https://raw.githubusercontent.com/rustynail1355/remnawave-edge-prep/main/prepare-node.sh -o prepare-node.sh
sudo bash prepare-node.sh --role ru-node --hostname my-node-01
```

Or as one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/rustynail1355/remnawave-edge-prep/main/prepare-node.sh | sudo bash -s -- --role ru-node --hostname my-node-01
```

## Usage

```
sudo bash prepare-node.sh --role {ru-node|exit} [OPTIONS]

Required:
  --role ROLE                 Node role: 'ru-node' or 'exit'.

Optional:
  --hostname NAME             Set hostname. Current is kept if omitted.
  --admin-pubkey 'KEY'        SSH public key for 'admin' user. If omitted,
                              admin uses password auth only.
  --claude-pubkey 'KEY'       SSH public key for 'claude' user. If omitted,
                              a new ed25519 keypair is generated on this node
                              and the PRIVATE key is printed in the final
                              report (shown ONCE, then persisted to disk).
  --office-ips 'CSV'          Comma-separated list of IPs/CIDRs for the SSH :22
                              whitelist. Example: '1.2.3.4,5.6.7.0/24'. If
                              omitted, SSH is open to ANY IP and a warning
                              is emitted. Fail2ban is still enabled.
  --dry-run                   Print plan without making changes.
  --help, -h                  Show help and exit.
```

## Output

After successful execution, a large multi-section report is printed to
`stdout` and also saved to `/root/node-prep-report.txt` (mode 600).

Sections: `[ROLE & IDENTITY]`, `[NETWORK]`, `[HARDWARE]`, `[OS]`,
`[SOFTWARE — INSTALLED]`, `[SOFTWARE — FAILED]`, `[USERS]`,
`[CLAUDE SSH PRIVATE KEY]` (only at first generation),
`[SSH SERVER CONFIG]`, `[FIREWALL — nftables]`, `[FAIL2BAN]`,
`[CONNECTION INFO FOR CLAUDE]`, `[NEXT STEPS]`.

## Idempotency

The script is **safe to re-run**:
- `apt install` is a no-op if packages are already present.
- Users (`admin`, `claude`) are not recreated if they exist.
- `admin` password is generated only on the first run and preserved in
  `/var/lib/node-prep/admin-password.firstrun` (mode 600).
- `claude` keypair is reused if `~claude/.ssh/id_ed25519` already exists —
  the private key is **not** re-printed on subsequent runs.
- `nftables` ruleset is replaced atomically (no duplicate rules).
- `sshd_config` is backed up to `sshd_config.prep.bak` before edits; on
  validation failure (`sshd -t`), the backup is restored automatically.

## Security notes

- `claude` user has `sudo NOPASSWD` for full automation. This is
  intentional — it is used for scripted configuration over SSH.
- `root` SSH login is disabled (`PermitRootLogin no`) and the root
  password is locked (`passwd -l root`).
- `admin` SSH requires password (+ pubkey if provided).
- The generated admin password uses 16 chars from `[A-HJ-NP-Za-km-z2-9]`
  (no confusing `0/O/1/l/I`), giving ~92 bits of entropy.
- The `claude` private key, if generated on the node, is shown exactly
  once in the final report. Save it immediately to
  `~/.ssh/id_claude_<hostname>` on your local machine (chmod 600).

## Exit codes

- `0` — OK
- `1` — invalid arguments / usage error
- `2` — pre-checks failed (not root, wrong OS)
- `3` — package installation failed (list in report)
- `4` — user creation failed
- `5` — SSH config validation failed (`sshd -t`)

## License

MIT — see [LICENSE](LICENSE).
