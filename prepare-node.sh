#!/usr/bin/env bash
#
# prepare-node.sh — Node preparation for remnawave-edge-stack
#
# Purpose: Turn a fresh Ubuntu 24.04 VPS into a node that is ready for
#          install.sh (Build-phase of remnawave-edge-stack).
#
# Contract: see README.md (public) / docs/08-node-prep.md (internal)
# Public:   https://github.com/rustynail1355/remnawave-edge-prep
#
# Safety:   All steps are idempotent — the script is safe to re-run.
#           A sshd_config backup is created before ANY ssh change.
#           On failure during ssh hardening, backup is restored.
#
# Exit codes:
#   0  OK
#   1  Invalid arguments / usage error
#   2  Pre-checks failed (not root, wrong OS, missing --role)
#   3  Package installation failed (list in report)
#   4  User creation failed
#   5  SSH validation failed (sshd -t)
#

set -euo pipefail
IFS=$'\n\t'

# ══════════════════════════════════════════════════════════════════════════════
#  Constants
# ══════════════════════════════════════════════════════════════════════════════

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="prepare-node.sh"

readonly STATE_DIR="/var/lib/node-prep"
readonly MARKER_ADMIN="${STATE_DIR}/admin-ready"
readonly ADMIN_PASSWORD_FILE="${STATE_DIR}/admin-password.firstrun"
readonly RUN_COUNT_FILE="${STATE_DIR}/run-count"
readonly FIRST_RUN_TS_FILE="${STATE_DIR}/first-prepared-at"

readonly REPORT_FILE="/root/node-prep-report.txt"
readonly SSHD_BACKUP="/etc/ssh/sshd_config.prep.bak"
readonly LOG_FILE="/var/log/node-prep.log"

# Packages to install on every node (both ru-node and exit)
readonly BASE_PACKAGES=(
    # System utilities
    curl wget ca-certificates
    git jq
    vim nano
    htop ncdu iotop
    net-tools iproute2 dnsutils
    tcpdump mtr-tiny traceroute
    rsync unzip tar lsof strace
    # Security
    nftables fail2ban unattended-upgrades gnupg
    # Infrastructure
    chrony logrotate rsyslog cron sudo
)

# ══════════════════════════════════════════════════════════════════════════════
#  CLI defaults
# ══════════════════════════════════════════════════════════════════════════════

ROLE=""
HOSTNAME_NEW=""
ADMIN_PUBKEY=""
CLAUDE_PUBKEY=""
OFFICE_IPS=""
DRY_RUN=false

# Runtime state
INSTALLED_OK=()
INSTALLED_FAIL=()
GENERATED_CLAUDE_PRIVKEY=""
GENERATED_CLAUDE_PUBKEY=""
ADMIN_PASSWORD_NEW=""
SSHD_CHANGED=false

# ══════════════════════════════════════════════════════════════════════════════
#  Logging / output helpers
# ══════════════════════════════════════════════════════════════════════════════

_ts() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }

# Write to $LOG_FILE best-effort (silent fail when not root / file not yet created).
_tee_log() { tee -a "$LOG_FILE" 2>/dev/null || cat; }

log()  { printf '[%s] %s\n' "$(_ts)" "$*" | _tee_log >&2; }
warn() { printf '[%s] \033[33mWARN\033[0m  %s\n' "$(_ts)" "$*" | _tee_log >&2; }
err()  { printf '[%s] \033[31mERROR\033[0m %s\n' "$(_ts)" "$*" | _tee_log >&2; }
ok()   { printf '[%s] \033[32m  OK\033[0m  %s\n' "$(_ts)" "$*" | _tee_log >&2; }

die() { err "$@"; exit "${2:-1}"; }

# Run a command, respecting --dry-run. On dry-run, only print intent.
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[DRY-RUN] would run: %s\n' "$*" >&2
    else
        "$@"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Usage / CLI parsing
# ══════════════════════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
Usage: sudo bash $SCRIPT_NAME --role {ru-node|exit} [OPTIONS]

Required:
  --role ROLE                 Node role: 'ru-node' or 'exit'.

Optional:
  --hostname NAME             Set hostname. If omitted, current is kept.
  --admin-pubkey 'KEY'        SSH public key for 'admin' user.
                              If omitted, admin uses password auth only.
  --claude-pubkey 'KEY'       SSH public key for 'claude' user.
                              If omitted, a new ed25519 key pair is generated
                              on this node and the PRIVATE key is printed in
                              the final report (show-once).
  --office-ips 'CSV'          Comma-separated list of IPs/CIDRs to whitelist
                              for SSH (:22). If omitted, SSH is open to ANY IP
                              and a warning is emitted in the report.
                              Example: '1.2.3.4,5.6.7.0/24,2001:db8::/64'
  --dry-run                   Print plan without making changes.
  --help, -h                  Show this help and exit.

Examples:
  sudo bash $SCRIPT_NAME --role ru-node --hostname ru-node-01
  sudo bash $SCRIPT_NAME --role exit --claude-pubkey "\$(cat ~/.ssh/id_edge.pub)" \\
      --office-ips "203.0.113.10,198.51.100.0/24"

See README.md for details.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)          ROLE="${2:-}";          shift 2 ;;
            --hostname)      HOSTNAME_NEW="${2:-}";  shift 2 ;;
            --admin-pubkey)  ADMIN_PUBKEY="${2:-}";  shift 2 ;;
            --claude-pubkey) CLAUDE_PUBKEY="${2:-}"; shift 2 ;;
            --office-ips)    OFFICE_IPS="${2:-}";    shift 2 ;;
            --dry-run)       DRY_RUN=true;           shift   ;;
            --help|-h)       usage; exit 0 ;;
            *) err "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done

    # Validate required
    if [[ -z "$ROLE" ]]; then
        err "--role is required"; usage; exit 1
    fi
    case "$ROLE" in
        ru-node|exit) ;;
        *) die "Invalid --role '$ROLE' (must be 'ru-node' or 'exit')" 1 ;;
    esac

    # Validate hostname format
    if [[ -n "$HOSTNAME_NEW" ]]; then
        if ! [[ "$HOSTNAME_NEW" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
            die "Invalid --hostname: must match [a-z][a-z0-9-]{0,62}" 1
        fi
    fi

    # Basic sanity on pubkeys (not validating the full format, just prefix)
    if [[ -n "$ADMIN_PUBKEY" ]] && ! [[ "$ADMIN_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]]; then
        die "--admin-pubkey does not look like a valid ssh public key" 1
    fi
    if [[ -n "$CLAUDE_PUBKEY" ]] && ! [[ "$CLAUDE_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]]; then
        die "--claude-pubkey does not look like a valid ssh public key" 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 1 — Pre-checks
# ══════════════════════════════════════════════════════════════════════════════

pre_checks() {
    log "Step 1/11: Pre-checks"

    # root?
    if [[ $EUID -ne 0 ]]; then
        die "Must be run as root (try: sudo bash $SCRIPT_NAME ...)" 2
    fi

    # Ubuntu 24.04?
    if [[ ! -f /etc/os-release ]]; then
        die "/etc/os-release not found — unsupported OS" 2
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        die "Unsupported OS: ${ID:-?} ${VERSION_ID:-?} (required: ubuntu 24.04)" 2
    fi

    # Internet reachability (best-effort, no-fail)
    if ! curl -fsS --max-time 5 --head https://deb.debian.org >/dev/null 2>&1; then
        warn "Internet reachability check failed (HTTPS to deb.debian.org). Continuing."
    fi

    # State dir
    run mkdir -p "$STATE_DIR"
    run chmod 700 "$STATE_DIR"

    # Touch log file
    run touch "$LOG_FILE"

    # Bump run counter
    local count=0
    [[ -f "$RUN_COUNT_FILE" ]] && count=$(cat "$RUN_COUNT_FILE" 2>/dev/null || echo 0)
    count=$((count + 1))
    [[ "$DRY_RUN" == "false" ]] && echo "$count" > "$RUN_COUNT_FILE"

    # First-run timestamp
    if [[ ! -f "$FIRST_RUN_TS_FILE" && "$DRY_RUN" == "false" ]]; then
        _ts > "$FIRST_RUN_TS_FILE"
    fi

    ok "Pre-checks passed (run #$count, Ubuntu ${VERSION_ID})"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 2 — Hostname
# ══════════════════════════════════════════════════════════════════════════════

set_hostname() {
    log "Step 2/11: Hostname"

    if [[ -z "$HOSTNAME_NEW" ]]; then
        log "  (skipped: --hostname not provided; current: $(hostname))"
        return
    fi

    local current; current=$(hostname)
    if [[ "$current" == "$HOSTNAME_NEW" ]]; then
        log "  Hostname already '$HOSTNAME_NEW', nothing to do"
        return
    fi

    run hostnamectl set-hostname "$HOSTNAME_NEW"

    # Update /etc/hosts
    if [[ "$DRY_RUN" == "false" ]]; then
        if grep -qE "^127\.0\.1\.1\s" /etc/hosts; then
            sed -i -E "s|^127\.0\.1\.1\s+.*$|127.0.1.1\t${HOSTNAME_NEW}|" /etc/hosts
        else
            echo -e "127.0.1.1\t${HOSTNAME_NEW}" >> /etc/hosts
        fi
    fi

    ok "Hostname set: $current → $HOSTNAME_NEW"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 3 — apt update + security
# ══════════════════════════════════════════════════════════════════════════════

apt_update_security() {
    log "Step 3/11: apt update + security upgrades"

    export DEBIAN_FRONTEND=noninteractive
    run apt-get update -q

    # Security upgrades (best-effort; continue on failure)
    if command -v unattended-upgrade >/dev/null 2>&1; then
        run unattended-upgrade --verbose || warn "unattended-upgrade returned non-zero"
    else
        log "  unattended-upgrade not yet installed (will be installed in step 4)"
    fi

    ok "apt sources refreshed"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 4 — Install base software
# ══════════════════════════════════════════════════════════════════════════════

install_base_software() {
    log "Step 4/11: Install base software (${#BASE_PACKAGES[@]} packages)"

    export DEBIAN_FRONTEND=noninteractive

    # Install all at once (faster, apt handles deps together)
    if [[ "$DRY_RUN" == "false" ]]; then
        apt-get install -y --no-install-recommends "${BASE_PACKAGES[@]}" \
            || warn "apt-get install returned non-zero (individual pkg status will be checked)"
    else
        printf '[DRY-RUN] would install: %s\n' "${BASE_PACKAGES[*]}" >&2
    fi

    # Verify each package
    for pkg in "${BASE_PACKAGES[@]}"; do
        local ver
        if [[ "$DRY_RUN" == "true" ]]; then
            INSTALLED_OK+=("${pkg}|DRY-RUN")
            continue
        fi
        ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "")
        if [[ -n "$ver" ]]; then
            INSTALLED_OK+=("${pkg}|${ver}")
        else
            INSTALLED_FAIL+=("${pkg}|not-installed")
        fi
    done

    if [[ ${#INSTALLED_FAIL[@]} -gt 0 ]]; then
        warn "Some packages failed to install: ${#INSTALLED_FAIL[@]}/${#BASE_PACKAGES[@]}"
    fi
    ok "Package installation done: ${#INSTALLED_OK[@]} OK, ${#INSTALLED_FAIL[@]} FAILED"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 5 — chrony
# ══════════════════════════════════════════════════════════════════════════════

setup_chrony() {
    log "Step 5/11: chrony (time sync)"
    run systemctl enable --now chrony
    ok "chrony enabled and running"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 6 — nftables (firewall)
# ══════════════════════════════════════════════════════════════════════════════

setup_nftables() {
    log "Step 6/11: nftables baseline"

    local ssh_rule
    if [[ -n "$OFFICE_IPS" ]]; then
        # Build saddr set from CSV. Separate v4 and v6.
        local v4_set="" v6_set=""
        IFS=',' read -ra IPS <<< "$OFFICE_IPS"
        for ip in "${IPS[@]}"; do
            ip=$(echo "$ip" | tr -d ' ')
            [[ -z "$ip" ]] && continue
            if [[ "$ip" == *:* ]]; then
                v6_set+="${ip}, "
            else
                v4_set+="${ip}, "
            fi
        done
        v4_set="${v4_set%, }"
        v6_set="${v6_set%, }"

        ssh_rule=""
        [[ -n "$v4_set" ]] && ssh_rule+="        tcp dport 22 ip saddr { $v4_set } accept"$'\n'
        [[ -n "$v6_set" ]] && ssh_rule+="        tcp dport 22 ip6 saddr { $v6_set } accept"$'\n'
    else
        ssh_rule="        tcp dport 22 accept  # WARN: SSH open to ANY IP (no --office-ips)"
    fi

    local conf="/etc/nftables.conf"

    if [[ "$DRY_RUN" == "false" ]]; then
        cat > "$conf" <<NFT
#!/usr/sbin/nft -f
# Generated by prepare-node.sh v${SCRIPT_VERSION} at $(_ts)
# Baseline firewall — SSH only. install.sh extends this at Build phase.

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        ct state invalid drop
        icmp type { echo-request, destination-unreachable, time-exceeded } accept
        icmpv6 type { echo-request, destination-unreachable, packet-too-big, \
                      time-exceeded, parameter-problem, \
                      nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
${ssh_rule}
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFT
        chmod 644 "$conf"
        # Validate syntax before applying
        if ! nft -c -f "$conf"; then
            die "nftables ruleset syntax error in $conf" 3
        fi
        # Apply atomically
        nft -f "$conf"
        systemctl enable --now nftables
    fi

    if [[ -z "$OFFICE_IPS" ]]; then
        warn "SSH is OPEN TO ANY IP (no --office-ips). fail2ban protects vs brute-force, but narrow after prep."
    fi
    ok "nftables baseline applied"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 7 — fail2ban
# ══════════════════════════════════════════════════════════════════════════════

setup_fail2ban() {
    log "Step 7/11: fail2ban"

    local jail_local="/etc/fail2ban/jail.local"
    if [[ "$DRY_RUN" == "false" ]]; then
        cat > "$jail_local" <<'F2B'
# Generated by prepare-node.sh — baseline SSH protection
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = 22
F2B
    fi

    run systemctl enable --now fail2ban
    run systemctl restart fail2ban  # pick up jail.local
    ok "fail2ban configured (sshd jail: maxretry=5, bantime=1h)"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 8 — User: admin
# ══════════════════════════════════════════════════════════════════════════════

# Generate password: 16 chars from A-HJ-NP-Za-km-z2-9 (no confusing 0 O 1 l I)
gen_password() {
    local chars='A-HJ-NP-Za-km-z2-9'
    local pass=""
    while [[ ${#pass} -lt 16 ]]; do
        # shellcheck disable=SC2002
        pass+=$(head -c 128 /dev/urandom | tr -dc "$chars" | head -c 16 || true)
    done
    echo "${pass:0:16}"
}

create_user_admin() {
    log "Step 8/11: User 'admin'"

    if ! id -u admin >/dev/null 2>&1; then
        run useradd -m -s /bin/bash -c "Operator (human admin)" admin
        run usermod -aG sudo,adm admin
    else
        log "  User 'admin' already exists"
    fi

    # Password: generate only once on first prep run
    if [[ ! -f "$MARKER_ADMIN" ]]; then
        ADMIN_PASSWORD_NEW=$(gen_password)
        if [[ "$DRY_RUN" == "false" ]]; then
            echo "admin:${ADMIN_PASSWORD_NEW}" | chpasswd
            # Persist for report on re-runs
            umask 077
            echo "$ADMIN_PASSWORD_NEW" > "$ADMIN_PASSWORD_FILE"
            chmod 600 "$ADMIN_PASSWORD_FILE"
            touch "$MARKER_ADMIN"
        fi
        ok "admin password generated (first run)"
    else
        if [[ -f "$ADMIN_PASSWORD_FILE" ]]; then
            ADMIN_PASSWORD_NEW=$(cat "$ADMIN_PASSWORD_FILE")
        else
            ADMIN_PASSWORD_NEW="(unknown: marker exists but password file missing)"
        fi
        log "  admin password preserved from first run"
    fi

    # Install admin pubkey if provided
    if [[ -n "$ADMIN_PUBKEY" && "$DRY_RUN" == "false" ]]; then
        install -d -o admin -g admin -m 700 /home/admin/.ssh
        echo "$ADMIN_PUBKEY" > /home/admin/.ssh/authorized_keys
        chown admin:admin /home/admin/.ssh/authorized_keys
        chmod 600 /home/admin/.ssh/authorized_keys
    fi

    # sudoers: admin ALL=(ALL) ALL (with password)
    if [[ "$DRY_RUN" == "false" ]]; then
        echo 'admin ALL=(ALL) ALL' > /etc/sudoers.d/admin
        chmod 440 /etc/sudoers.d/admin
        visudo -c -f /etc/sudoers.d/admin >/dev/null || die "invalid sudoers.d/admin" 4
    fi

    ok "admin configured (groups: sudo,adm; sudoers: password required)"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 9 — User: claude
# ══════════════════════════════════════════════════════════════════════════════

create_user_claude() {
    log "Step 9/11: User 'claude'"

    if ! id -u claude >/dev/null 2>&1; then
        run useradd -m -s /bin/bash -c "Automation user (Claude)" claude
        run usermod -aG sudo claude
    else
        log "  User 'claude' already exists"
    fi

    # Lock password regardless
    run passwd -l claude >/dev/null

    # Ensure .ssh directory
    if [[ "$DRY_RUN" == "false" ]]; then
        install -d -o claude -g claude -m 700 /home/claude/.ssh
    fi

    # Pubkey: provided or generate
    local pub_line=""
    if [[ -n "$CLAUDE_PUBKEY" ]]; then
        pub_line="$CLAUDE_PUBKEY"
        if [[ "$DRY_RUN" == "false" ]]; then
            echo "$pub_line" > /home/claude/.ssh/authorized_keys
            chown claude:claude /home/claude/.ssh/authorized_keys
            chmod 600 /home/claude/.ssh/authorized_keys
        fi
        GENERATED_CLAUDE_PRIVKEY=""  # not generated; not shown in report
        GENERATED_CLAUDE_PUBKEY="$pub_line"
        ok "claude pubkey installed (provided via --claude-pubkey)"
    else
        # Generate ed25519 pair — only if one doesn't already exist (idempotency)
        local key_path="/home/claude/.ssh/id_ed25519"
        if [[ -f "$key_path" && "$DRY_RUN" == "false" ]]; then
            pub_line=$(cat "${key_path}.pub")
            GENERATED_CLAUDE_PRIVKEY=""  # Do not re-show on re-runs
            GENERATED_CLAUDE_PUBKEY="$pub_line"
            log "  claude keypair already exists, re-using (privkey not shown)"
        elif [[ "$DRY_RUN" == "false" ]]; then
            sudo -u claude ssh-keygen -t ed25519 -N "" \
                -f "$key_path" \
                -C "claude@$(hostname)" >/dev/null
            pub_line=$(cat "${key_path}.pub")
            cat "${key_path}.pub" > /home/claude/.ssh/authorized_keys
            chown claude:claude /home/claude/.ssh/authorized_keys
            chmod 600 /home/claude/.ssh/authorized_keys
            GENERATED_CLAUDE_PRIVKEY=$(cat "$key_path")
            GENERATED_CLAUDE_PUBKEY="$pub_line"
            ok "claude keypair generated (ed25519)"
        else
            pub_line="(would be generated)"
            GENERATED_CLAUDE_PUBKEY="$pub_line"
        fi
    fi

    # sudoers: NOPASSWD for automation
    if [[ "$DRY_RUN" == "false" ]]; then
        echo 'claude ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/claude
        chmod 440 /etc/sudoers.d/claude
        visudo -c -f /etc/sudoers.d/claude >/dev/null || die "invalid sudoers.d/claude" 4
    fi

    ok "claude configured (sudoers: NOPASSWD; ssh: publickey only)"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 10 — SSH hardening
# ══════════════════════════════════════════════════════════════════════════════

# Set sshd_config option, idempotently. Adds if missing.
set_sshd_option() {
    local key="$1" val="$2" file="/etc/ssh/sshd_config"
    if grep -qE "^\s*#?\s*${key}\b" "$file"; then
        sed -i -E "s|^\s*#?\s*${key}\b.*|${key} ${val}|" "$file"
    else
        echo "${key} ${val}" >> "$file"
    fi
}

harden_ssh() {
    log "Step 10/11: SSH hardening"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [DRY-RUN] would set PermitRootLogin no, PasswordAuthentication yes, add Match claude block"
        return
    fi

    # Backup
    cp -a /etc/ssh/sshd_config "$SSHD_BACKUP"
    SSHD_CHANGED=true  # we have a backup; cleanup trap may use it

    # Apply options
    set_sshd_option "PermitRootLogin"        "no"
    set_sshd_option "PasswordAuthentication" "yes"
    set_sshd_option "PubkeyAuthentication"   "yes"
    set_sshd_option "ChallengeResponseAuthentication" "no"
    set_sshd_option "UsePAM"                 "yes"
    set_sshd_option "X11Forwarding"          "no"
    set_sshd_option "MaxAuthTries"           "3"
    set_sshd_option "LoginGraceTime"         "30s"

    # Match User claude block — add only if not present
    if ! grep -qE "^\s*Match\s+User\s+claude\b" /etc/ssh/sshd_config; then
        cat >> /etc/ssh/sshd_config <<'SSHD_CLAUDE'

# Added by prepare-node.sh: claude is automation user, pubkey only
Match User claude
    PasswordAuthentication no
    AuthenticationMethods publickey
SSHD_CLAUDE
    fi

    # Validate syntax
    if ! sshd -t 2>/tmp/sshd-t.err; then
        err "sshd -t failed. Restoring backup."
        cp -a "$SSHD_BACKUP" /etc/ssh/sshd_config
        cat /tmp/sshd-t.err >&2 || true
        die "SSH config validation failed" 5
    fi

    # Lock root password
    passwd -l root >/dev/null

    # Reload (NOT restart — keeps current session alive)
    systemctl reload ssh || systemctl restart ssh

    ok "SSH hardened (root disabled, claude pubkey-only, validated)"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helpers for report
# ══════════════════════════════════════════════════════════════════════════════

get_primary_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' \
        || ip -6 route show default 2>/dev/null | awk '{print $5; exit}'
}

get_ipv4_addr() {
    local iface="$1"
    ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}'
}

get_ipv6_addr() {
    local iface="$1"
    ip -6 -o addr show dev "$iface" scope global 2>/dev/null \
        | awk '{print $4; exit}'
}

get_gw_v4() { ip -4 route show default 2>/dev/null | awk '{print $3; exit}'; }
get_gw_v6() { ip -6 route show default 2>/dev/null | awk '{print $3; exit}'; }

get_resolvers() {
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        awk '/^nameserver/ {print $2}' /run/systemd/resolve/resolv.conf | paste -sd ',' -
    elif [[ -f /etc/resolv.conf ]]; then
        awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd ',' -
    fi
}

check_icmpv6() {
    if ping6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; then
        echo "yes"
    elif ping -6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; then
        echo "yes"
    else
        echo "no"
    fi
}

get_cpu_model() {
    lscpu | awk -F: '/^Model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}'
}

get_cpu_mhz() {
    lscpu | awk -F: '/CPU max MHz|CPU MHz/ {sub(/^[ \t]+/, "", $2); print int($2); exit}'
}

get_ram_total_mb() { awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo; }
get_ram_avail_mb() { awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }

get_disk_root_total() { df -BG / | awk 'NR==2 {gsub(/G$/,"",$2); print $2" GB"}'; }
get_disk_root_free()  { df -BG / | awk 'NR==2 {gsub(/G$/,"",$4); print $4" GB"}'; }

get_virtualization() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt 2>/dev/null || echo "none"
    else
        echo "unknown"
    fi
}

get_kernel() { uname -r; }

get_uptime() {
    awk '{
        mins = int($1/60); h = int(mins/60); d = int(h/24);
        if (d > 0)       printf "%dd %dh", d, h%24;
        else if (h > 0)  printf "%dh %dm", h, mins%60;
        else             printf "%d min", mins;
    }' /proc/uptime
}

get_distro() {
    awk -F= '/^PRETTY_NAME/ {gsub(/"/, "", $2); print $2}' /etc/os-release
}

get_chrony_synced() {
    if ! command -v chronyc >/dev/null 2>&1; then echo "chrony not installed"; return; fi
    local out
    out=$(chronyc tracking 2>/dev/null || true)
    local offset
    offset=$(echo "$out" | awk '/System time/ {print $4" "$5}')
    local leap
    leap=$(echo "$out" | awk -F: '/Leap status/ {gsub(/^[ \t]+/, "", $2); print $2}')
    if echo "$leap" | grep -qi "Normal"; then
        echo "yes (offset: ${offset:-?})"
    else
        echo "no (leap: ${leap:-?})"
    fi
}

get_fpr() {
    local keyfile="$1"
    [[ -f "$keyfile" ]] && ssh-keygen -lf "$keyfile" 2>/dev/null | awk '{print $2}' || echo "n/a"
}

get_ipv6_forwarding() {
    sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "?"
}

get_fail2ban_banned() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client status sshd 2>/dev/null \
            | awk -F: '/Currently banned/ {gsub(/^[ \t]+/, "", $2); print $2}' \
            || echo "0"
    else
        echo "n/a"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Step 11 — Generate report
# ══════════════════════════════════════════════════════════════════════════════

generate_report() {
    log "Step 11/11: Generate report"

    local iface; iface=$(get_primary_iface)
    local ipv4;  ipv4=$(get_ipv4_addr "$iface")
    local ipv6;  ipv6=$(get_ipv6_addr "$iface")
    local ipv6_prefix; ipv6_prefix="$(echo "$ipv6" | sed -E 's|::[0-9a-f:]*/|::/|')"
    local first_ts; first_ts=$(cat "$FIRST_RUN_TS_FILE" 2>/dev/null || echo "n/a")
    local run_count; run_count=$(cat "$RUN_COUNT_FILE" 2>/dev/null || echo 1)
    local claude_pub_line; claude_pub_line="$GENERATED_CLAUDE_PUBKEY"
    local claude_fpr="n/a"
    if [[ -f /home/claude/.ssh/id_ed25519.pub ]]; then
        claude_fpr=$(get_fpr /home/claude/.ssh/id_ed25519.pub)
    elif [[ -f /home/claude/.ssh/authorized_keys ]]; then
        claude_fpr=$(get_fpr /home/claude/.ssh/authorized_keys)
    fi

    local ssh_whitelist_display
    if [[ -z "$OFFICE_IPS" ]]; then
        ssh_whitelist_display="0.0.0.0/0, ::/0  ⚠️  SSH OPEN TO ANY IP (no --office-ips was provided; narrow after prep!)"
    else
        ssh_whitelist_display="$OFFICE_IPS"
    fi

    local claude_source
    if [[ -n "$CLAUDE_PUBKEY" ]]; then
        claude_source="provided via --claude-pubkey"
    elif [[ -n "$GENERATED_CLAUDE_PRIVKEY" ]]; then
        claude_source="generated on node (this run; privkey shown below — ONCE)"
    else
        claude_source="pre-existing on node (from earlier run; privkey NOT shown)"
    fi

    # ── Build report
    {
        cat <<EOF
═══════════════════════════════════════════════════════════════════
  NODE PREPARATION REPORT  (remnawave-edge-stack / $SCRIPT_NAME)
  Generated:        $(_ts)
  Script version:   $SCRIPT_VERSION
  Run count:        $run_count
  First prepared:   $first_ts
═══════════════════════════════════════════════════════════════════

[ROLE & IDENTITY]
  role              = $ROLE
  hostname          = $(hostname)
  fqdn              = $(hostname -f 2>/dev/null || hostname)
  dry_run           = $DRY_RUN

[NETWORK]
  primary_iface     = ${iface:-n/a}
  public_ipv4       = ${ipv4:-n/a}
  public_ipv6       = ${ipv6:-n/a}
  ipv6_prefix       = ${ipv6_prefix:-n/a}
  gateway_v4        = $(get_gw_v4 || echo n/a)
  gateway_v6        = $(get_gw_v6 || echo n/a)
  resolvers         = $(get_resolvers || echo n/a)
  icmpv6_ok         = $(check_icmpv6)
  ipv6_forwarding   = $(get_ipv6_forwarding)  (install.sh may change this)

[HARDWARE]
  cpu_model         = $(get_cpu_model)
  cpu_cores         = $(nproc)
  cpu_mhz           = $(get_cpu_mhz)
  ram_total_mb      = $(get_ram_total_mb)
  ram_available_mb  = $(get_ram_avail_mb)
  disk_root_total   = $(get_disk_root_total)
  disk_root_free    = $(get_disk_root_free)
  arch              = $(uname -m)
  virtualization    = $(get_virtualization)

[OS]
  distribution      = $(get_distro)
  kernel            = $(get_kernel)
  uptime            = $(get_uptime)
  timezone          = $(timedatectl 2>/dev/null | awk -F: '/Time zone/ {gsub(/^[ \t]+/, "", $2); print $2}' | head -c 40)
  chrony_synced     = $(get_chrony_synced)

[SOFTWARE — INSTALLED]
EOF

        # Installed OK packages
        for entry in "${INSTALLED_OK[@]}"; do
            IFS='|' read -r pkg ver <<< "$entry"
            printf '  %-24s %-30s ✓\n' "$pkg" "$ver"
        done

        # Failed packages
        echo ""
        echo "[SOFTWARE — FAILED]"
        if [[ ${#INSTALLED_FAIL[@]} -eq 0 ]]; then
            echo "  (none)"
        else
            for entry in "${INSTALLED_FAIL[@]}"; do
                IFS='|' read -r pkg reason <<< "$entry"
                printf '  %-24s %-30s ✗ (%s)\n' "$pkg" "" "$reason"
            done
        fi

        cat <<EOF

[USERS]
  admin:
    uid             = $(id -u admin 2>/dev/null || echo n/a)
    groups          = $(id -Gn admin 2>/dev/null || echo n/a)
    shell           = $(getent passwd admin | cut -d: -f7 || echo n/a)
    password        = ${ADMIN_PASSWORD_NEW:-n/a}   ← SAVE to vault (not stored except $ADMIN_PASSWORD_FILE)
    pubkey          = $(if [[ -n "$ADMIN_PUBKEY" ]]; then echo "configured"; else echo "(none — password auth only)"; fi)
    sudo            = ALL (password required)
    ssh             = $(if [[ -n "$ADMIN_PUBKEY" ]]; then echo "publickey password"; else echo "password only"; fi)

  claude:
    uid             = $(id -u claude 2>/dev/null || echo n/a)
    groups          = $(id -Gn claude 2>/dev/null || echo n/a)
    shell           = $(getent passwd claude | cut -d: -f7 || echo n/a)
    password        = (locked: passwd -l claude)
    pubkey_source   = $claude_source
    pubkey          = $claude_pub_line
    pubkey_fpr      = $claude_fpr
    sudo            = ALL (NOPASSWD)
    ssh             = publickey only

  root:
    password        = (locked: passwd -l root)
    ssh             = DISABLED (PermitRootLogin no)
EOF

        # Claude private key — shown only on first generation
        if [[ -n "$GENERATED_CLAUDE_PRIVKEY" ]]; then
            cat <<'PRIVKEY_BANNER'

[CLAUDE SSH PRIVATE KEY]
  ⚠️  This key was GENERATED on the node. It is shown ONLY ONCE.
  ⚠️  Save to your local ~/.ssh/id_claude_<hostname> (mode 600 / NTFS owner-only).
  ⚠️  After saving, clear terminal buffer; do NOT paste in public places.
  ⚠️  If re-prep is needed later, use --claude-pubkey to avoid showing privkey again.

PRIVKEY_BANNER
            echo "$GENERATED_CLAUDE_PRIVKEY"
        fi

        cat <<EOF

[SSH SERVER CONFIG]
  Port                    = 22
  ListenAddress           = 0.0.0.0, ::
  PermitRootLogin         = no
  PasswordAuthentication  = yes  (for admin; claude overridden to no)
  PubkeyAuthentication    = yes
  MaxAuthTries            = 3
  LoginGraceTime          = 30s
  Claude override         = Match User claude → publickey only

[FIREWALL — nftables]
  policy_input            = drop
  policy_forward          = drop
  policy_output           = accept
  ssh_whitelist           = $ssh_whitelist_display
  icmp/icmpv6             = allowed (echo + ND + PTB)

[FAIL2BAN]
  status                  = $(systemctl is-active fail2ban 2>/dev/null || echo unknown)
  jail sshd               = enabled (maxretry=5, bantime=1h, findtime=10m)
  currently_banned        = $(get_fail2ban_banned)

[CONNECTION INFO FOR CLAUDE]
  # Via IPv4:
  ssh -i ~/.ssh/id_claude_$(hostname) claude@${ipv4%/*}
EOF
        if [[ -n "$ipv6" && "$ipv6" != "n/a" ]]; then
            echo "  # Via IPv6:"
            echo "  ssh -i ~/.ssh/id_claude_$(hostname) claude@[${ipv6%/*}]"
        fi

        cat <<EOF

[NEXT STEPS]
  1. Copy this whole report to Claude chat.
  2. Save [USERS].admin.password to your vault (1Password / bitwarden).
  3. Save [CLAUDE SSH PRIVATE KEY] block (if present) to ~/.ssh/id_claude_$(hostname) (chmod 600).
  4. Claude will SSH as claude@<ip>, run install.sh (Build phase of the stack).
  5. After install.sh completes, add this node in Remnawave Panel Web UI —
     Panel will deploy the Remnawave Node container automatically.

═══════════════════════════════════════════════════════════════════
  END OF REPORT
═══════════════════════════════════════════════════════════════════
EOF
    } | tee "$REPORT_FILE"

    if [[ "$DRY_RUN" == "false" ]]; then
        chmod 600 "$REPORT_FILE"
    fi
    ok "Report generated: $REPORT_FILE"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"

    log "═══════════════════════════════════════════════════════════════"
    log " prepare-node.sh v${SCRIPT_VERSION}"
    log " role=${ROLE} hostname=${HOSTNAME_NEW:-<unchanged>} dry_run=${DRY_RUN}"
    log "═══════════════════════════════════════════════════════════════"

    pre_checks
    set_hostname
    apt_update_security
    install_base_software
    setup_chrony
    setup_nftables
    setup_fail2ban
    create_user_admin
    create_user_claude
    harden_ssh
    generate_report

    log ""
    log "DONE. Report also saved to: $REPORT_FILE"
    log "Next: copy report to Claude chat. See [NEXT STEPS] in the report."
}

main "$@"
