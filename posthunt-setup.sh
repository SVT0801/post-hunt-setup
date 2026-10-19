#!/usr/bin/env bash
# posthunt-setup.sh - installer for POST_HUNT (self-contained, public).
#
#   sudo bash posthunt-setup.sh prepare <pubkey-file>     prepare a Debian 13 server (root)
#   bash posthunt-setup.sh install --domain D --version vX.Y.Z [--tls self-signed|letsencrypt] [--email E]
#   bash posthunt-setup.sh check [--phase pre|post] [--domain D]
#   bash posthunt-setup.sh report
#   bash posthunt-setup.sh version | --help
#
# Environment:
#   POSTHUNT_BASE           install root (default: $HOME/post-hunt)
#   POSTHUNT_CATALOG        release catalog "owner/repo" (default: SVT0801/post-hunt-releases)
#   POSTHUNT_CATALOG_TOKEN  read-only token of the catalog (otherwise asked, input hidden)
#   POSTHUNT_CATALOG_DIR    local folder with release assets instead of GitHub (tests)
set -euo pipefail

PROTOCOL=1
DEFAULT_CATALOG="SVT0801/post-hunt-releases"
KEEP_RELEASES=3

BASE="${POSTHUNT_BASE:-${HOME:-/root}/post-hunt}"
TMP=""

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

cleanup() {
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# EUID with a test override (the installer must refuse to run as root).
current_euid() { echo "${POSTHUNT_TEST_EUID:-$EUID}"; }

usage() {
  cat <<'EOF'
posthunt-setup.sh - POST_HUNT installer (protocol 1)

Usage:
  sudo bash posthunt-setup.sh prepare <pubkey-file>
      Prepare a Debian 13 server (user posthunt, Docker, firewall, SSH hardening). Root only.
  bash posthunt-setup.sh install --domain D --version vX.Y.Z [--tls self-signed|letsencrypt] [--email E]
      Download a release from the catalog, verify it, unpack and run its install.sh.
      Run as the posthunt user (not root, member of group docker).
      Token: POSTHUNT_CATALOG_TOKEN or an interactive hidden prompt.
  bash posthunt-setup.sh check [--phase pre|post] [--domain D]
      Read-only checks, no sudo. Lines: PASS|WARN|FAIL <id> <text>. Exit 1 on FAIL.
      Default phase: post if $BASE/current exists, otherwise pre.
  bash posthunt-setup.sh report
      "check --phase post" plus versions; secret-like strings are masked. Exit 0.
  bash posthunt-setup.sh version
      Print the installer protocol number.

Environment: POSTHUNT_BASE, POSTHUNT_CATALOG, POSTHUNT_CATALOG_TOKEN, POSTHUNT_CATALOG_DIR
EOF
}

# ---------------------------------------------------------------- helpers

# json_get <file> <dotted.path> : prints a scalar value or nothing.
json_get() {
  local f="$1" p="$2" v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r ".${p} // empty" "$f" 2>/dev/null)" || v=""
  elif command -v python3 >/dev/null 2>&1; then
    v="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split("."):
        d = d[k]
    print(d if not isinstance(d, (dict, list)) else "")
except Exception:
    pass
' "$f" "$p" 2>/dev/null)" || v=""
  else
    local key="${p##*.}"
    v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$f" | head -1)" || v=""
  fi
  printf '%s' "$v"
}

# asset_id_from_release <release.json> <asset name>
asset_id_from_release() {
  local f="$1" n="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg n "$n" '.assets[]? | select(.name == $n) | .id' "$f" 2>/dev/null | head -1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for a in d.get("assets", []):
    if a.get("name") == sys.argv[2]:
        print(a["id"])
        break
' "$f" "$n" 2>/dev/null
  else
    die "jq or python3 is required to read the catalog response"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- prepare

cmd_prepare() {
  [[ "$(current_euid)" -eq 0 ]] || die "prepare must run as root (sudo bash $0 prepare <pubkey-file>)"
  [[ -r "${1:-}" ]] || die "usage: sudo bash $0 prepare <public key file for user posthunt>"
  local PUBKEY LOG=/var/log/posthunt-prep.log
  PUBKEY="$(head -1 "$1")"
  [[ "$PUBKEY" == ssh-* ]] || die "not an SSH public key: $1"

  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  exec > >(tee -a "$LOG") 2>&1
  chmod 644 "$LOG"
  pstep() { echo; echo "=== $(date -u +%FT%TZ) $*"; }

  pstep "apt update + full-upgrade"
  apt-get update
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
  apt-get -y autoremove

  pstep "base packages"
  apt-get install -y ca-certificates curl tar rsync gnupg jq python3 python3-venv python3-pip \
    ufw fail2ban python3-systemd unattended-upgrades apt-listchanges needrestart

  pstep "Docker (official repo, Debian trixie)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" }, "live-restore": true }
JSON
  systemctl enable docker containerd
  systemctl restart docker
  docker run --rm hello-world | head -2
  docker image rm hello-world >/dev/null 2>&1 || true

  pstep "user posthunt"
  id posthunt >/dev/null 2>&1 || adduser --disabled-password --gecos "POST_HUNT" posthunt
  usermod -aG docker posthunt
  install -d -m 700 -o posthunt -g posthunt /home/posthunt/.ssh
  grep -qxF "$PUBKEY" /home/posthunt/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> /home/posthunt/.ssh/authorized_keys
  chown posthunt:posthunt /home/posthunt/.ssh/authorized_keys
  chmod 600 /home/posthunt/.ssh/authorized_keys
  install -d -m 755 -o posthunt -g posthunt /home/posthunt/post-hunt
  if [[ -n "${SUDO_USER:-}" ]]; then chsh -s /bin/bash "$SUDO_USER"; fi

  pstep "swap (2 GB when RAM < 8 GB and no swap)"
  local mem_kb
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  if [[ "$mem_kb" -lt 8388608 ]] && ! swapon --show=NAME --noheadings | grep -q .; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    echo "swap: not needed or already present"
  fi
  swapon --show

  pstep "sysctl"
  echo "vm.swappiness=10" > /etc/sysctl.d/99-posthunt.conf
  sysctl --system >/dev/null

  pstep "SSH hardening"
  cat > /etc/ssh/sshd_config.d/99-posthunt.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
CONF
  sshd -t
  systemctl reload ssh

  pstep "UFW"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  systemctl enable ufw

  pstep "fail2ban"
  cat > /etc/fail2ban/jail.d/sshd.local <<'CONF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
bantime = 1h
CONF
  systemctl enable fail2ban
  systemctl restart fail2ban

  pstep "unattended-upgrades (security only, no auto reboot)"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
  cat > /etc/apt/apt.conf.d/52posthunt-unattended <<'CONF'
Unattended-Upgrade::Automatic-Reboot "false";
CONF
  systemctl enable --now unattended-upgrades

  pstep "journald"
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=1G\n' > /etc/systemd/journald.conf.d/99-posthunt.conf
  systemctl restart systemd-journald

  pstep "DNS fallback resolver"
  if [[ ! -L /etc/resolv.conf ]] && ! grep -q '^nameserver 9.9.9.9' /etc/resolv.conf; then
    echo "nameserver 9.9.9.9" >> /etc/resolv.conf
  fi

  pstep "SUMMARY"
  docker --version
  docker compose version
  python3 --version
  ufw status verbose
  fail2ban-client status sshd | head -4
  sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding) '
  id posthunt
  apt list --upgradable 2>/dev/null | tail -n +2 | wc -l
  if [[ -f /var/run/reboot-required ]]; then
    echo "REBOOT REQUIRED: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)"
    local a
    read -r -p "Reboot the server now? [y/N] " a </dev/tty || a=n
    if [[ "$a" == y || "$a" == Y ]]; then echo "reboot in 1 min"; shutdown -r +1; fi
  else
    echo "reboot not required"
  fi
  echo "DONE - log: $LOG"
}

# ---------------------------------------------------------------- install

# Fetch one asset <name> into <dest>. Uses TOKEN_CFG (curl config, mode 600) for GitHub.
RELEASE_JSON=""
fetch_asset() {
  local name="$1" dest="$2" id
  if [[ -n "${POSTHUNT_CATALOG_DIR:-}" ]]; then
    [[ -f "$POSTHUNT_CATALOG_DIR/$name" ]] || die "asset not found in catalog dir: $name"
    cp "$POSTHUNT_CATALOG_DIR/$name" "$dest"
    return 0
  fi
  id="$(asset_id_from_release "$RELEASE_JSON" "$name")"
  [[ -n "$id" ]] || die "asset not found in release: $name"
  # The token travels only in the curl config file, never in argv. curl drops the
  # Authorization header when a redirect leaves the host (storage redirect).
  curl -fsSL --proto '=https' --proto-redir '=https' -K "$TOKEN_CFG" \
    -H "Accept: application/octet-stream" \
    -o "$dest" "https://api.github.com/repos/${POSTHUNT_CATALOG:-$DEFAULT_CATALOG}/releases/assets/$id" \
    || die "download failed: $name"
}

# expected_sum <SHA256SUMS> <file name> : prints the hash for the name
expected_sum() { awk -v n="$2" '$2 == n || $2 == "*" n { print tolower($1); exit }' "$1"; }

rotate_releases() {
  local keep_extra="$1" cur="" d n=0 list
  if [[ -L "$BASE/current" ]]; then cur="$(basename "$(readlink "$BASE/current")")"; fi
  # newest first; a final release sorts above its own -rcN
  list="$(ls -1 "$BASE/releases" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
    | awk '{ n = $0; i = index(n, "-"); v = (i ? substr(n, 1, i - 1) : n); s = (i ? substr(n, i + 1) : "");
             split(v, a, "."); print a[1], a[2], a[3], (i ? 0 : 1), s, n }' \
    | sort -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k5,5r | awk '{ print $NF }' || true)"
  for d in $list; do
    n=$((n + 1))
    if [[ $n -le $KEEP_RELEASES || "$d" == "$cur" || "$d" == "$keep_extra" ]]; then continue; fi
    rm -rf "${BASE:?}/releases/$d"
    log "removed old release $d"
  done
}

cmd_install() {
  local domain="" version="" tls="" email=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)  domain="${2:-}"; shift 2 ;;
      --version) version="${2:-}"; shift 2 ;;
      --tls)     tls="${2:-}"; shift 2 ;;
      --email)   email="${2:-}"; shift 2 ;;
      *) die "unknown option for install: $1" ;;
    esac
  done
  [[ "$(current_euid)" -ne 0 ]] || die "install must not run as root: use the posthunt user"
  [[ -n "$domain" && -n "$version" ]] || die "usage: install --domain D --version vX.Y.Z [--tls self-signed|letsencrypt] [--email E]"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "invalid domain"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] || die "version must look like vX.Y.Z or vX.Y.Z-rcN"
  if [[ -n "$tls" && "$tls" != self-signed && "$tls" != letsencrypt ]]; then die "--tls must be self-signed or letsencrypt"; fi
  if [[ "$tls" == letsencrypt && -z "$email" ]]; then die "--tls letsencrypt requires --email"; fi
  if [[ -n "$email" && ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then die "invalid --email"; fi

  local tag="$version" rel="${version#v}"
  command -v docker >/dev/null 2>&1 || die "docker is not installed (run prepare first)"
  docker compose version >/dev/null 2>&1 || die "docker compose plugin is not available"
  id -nG | tr ' ' '\n' | grep -qx docker || die "current user is not in the docker group"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  if [[ -z "${POSTHUNT_CATALOG_DIR:-}" ]]; then command -v curl >/dev/null 2>&1 || die "curl is required"; fi

  # Token: environment or hidden prompt. Never printed, never put into argv.
  local token="${POSTHUNT_CATALOG_TOKEN:-}"
  unset POSTHUNT_CATALOG_TOKEN
  if [[ -z "$token" ]]; then
    if [[ -t 0 ]]; then
      printf 'Catalog token (input hidden): ' >&2
      read -rs token || true
      echo >&2
    else
      read -r token || true
    fi
  fi
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  [[ -n "$token" ]] || die "catalog token is empty (set POSTHUNT_CATALOG_TOKEN)"
  [[ "$token" =~ ^[A-Za-z0-9_.~+/=-]+$ ]] || die "catalog token has unexpected characters"

  umask 077
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/posthunt-setup.XXXXXX")"
  TOKEN_CFG="$TMP/curl.cfg"
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$TOKEN_CFG"
  chmod 600 "$TOKEN_CFG"

  if [[ -z "${POSTHUNT_CATALOG_DIR:-}" ]]; then
    log "reading release $tag from ${POSTHUNT_CATALOG:-$DEFAULT_CATALOG}"
    RELEASE_JSON="$TMP/release.json"
    curl -fsSL --proto '=https' --proto-redir '=https' -K "$TOKEN_CFG" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      -o "$RELEASE_JSON" "https://api.github.com/repos/${POSTHUNT_CATALOG:-$DEFAULT_CATALOG}/releases/tags/$tag" \
      || die "cannot read release $tag (check the version and the token)"
  fi

  local dl="$TMP/dl"
  mkdir -p "$dl"
  fetch_asset SHA256SUMS "$dl/SHA256SUMS"
  fetch_asset manifest.json "$dl/manifest.json"

  # manifest.json: hash from SHA256SUMS, tag, installer protocol
  local want got
  want="$(expected_sum "$dl/SHA256SUMS" manifest.json)"
  [[ -n "$want" ]] || die "SHA256SUMS has no entry for manifest.json"
  got="$(sha256_of "$dl/manifest.json")"
  [[ "$want" == "$got" ]] || die "manifest.json checksum mismatch"

  local m_tag m_min bundle_name bundle_sha
  m_tag="$(json_get "$dl/manifest.json" tag)"
  [[ "$m_tag" == "$tag" ]] || die "manifest tag '$m_tag' does not match requested $tag"
  m_min="$(json_get "$dl/manifest.json" installer_min)"
  [[ "$m_min" =~ ^[0-9]+$ ]] || die "manifest has no valid installer_min"
  if [[ "$m_min" -gt "$PROTOCOL" ]]; then
    die "release needs installer protocol >= $m_min (this installer: $PROTOCOL): download a newer posthunt-setup.sh"
  fi
  bundle_name="$(json_get "$dl/manifest.json" bundle.name)"
  [[ "$bundle_name" == "posthunt-$tag.tar.gz" ]] || die "unexpected bundle name in manifest"
  bundle_sha="$(json_get "$dl/manifest.json" bundle.sha256 | tr 'A-F' 'a-f')"
  [[ "$bundle_sha" =~ ^[0-9a-f]{64}$ ]] || die "manifest has no valid bundle sha256"

  log "downloading $bundle_name"
  fetch_asset "$bundle_name" "$dl/$bundle_name"
  want="$(expected_sum "$dl/SHA256SUMS" "$bundle_name")"
  got="$(sha256_of "$dl/$bundle_name")"
  [[ -n "$want" ]] || die "SHA256SUMS has no entry for $bundle_name"
  [[ "$want" == "$got" ]] || die "bundle checksum mismatch (SHA256SUMS)"
  [[ "$bundle_sha" == "$got" ]] || die "bundle checksum mismatch (manifest.json)"
  log "checksums ok"

  # Unpack into a staging dir, strip the posthunt-<tag>/ root.
  local bad
  bad="$(tar -tzf "$dl/$bundle_name" | grep -Ev "^posthunt-${tag}(/|$)" || true)"
  [[ -z "$bad" ]] || die "bundle has entries outside posthunt-$tag/"
  if tar -tzf "$dl/$bundle_name" | grep -Eq '(^|/)\.\.(/|$)'; then die "bundle has unsafe paths"; fi

  umask 022
  install -d -m 755 "$BASE" "$BASE/releases"
  install -d -m 700 "$BASE/env"
  chmod 700 "$BASE/env"
  local stage="$BASE/.stage.$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  tar -xzf "$dl/$bundle_name" -C "$stage" --strip-components=1 || { rm -rf "$stage"; die "cannot unpack bundle"; }
  if [[ ! -f "$stage/backend/deploy/install.sh" ]]; then rm -rf "$stage"; die "bundle has no backend/deploy/install.sh"; fi
  # release dir = tag without "v"; VERSION holds only X.Y.Z (no -rcN)
  if [[ -f "$stage/VERSION" && "$(tr -d '[:space:]' < "$stage/VERSION")" != "${rel%%-*}" ]]; then
    rm -rf "$stage"; die "bundle VERSION does not match ${rel%%-*}"
  fi

  local dest="$BASE/releases/$rel"
  if [[ -e "$dest" ]]; then rm -rf "$dest.old"; mv "$dest" "$dest.old"; fi
  mv "$stage" "$dest"
  rm -rf "$dest.old"
  log "unpacked to $dest"

  # Token for later updates: env/catalog.token, mode 600.
  ( umask 077; printf '%s\n' "$token" > "$BASE/env/catalog.token" )
  chmod 600 "$BASE/env/catalog.token"

  local args=(--base "$BASE" --domain "$domain" --release "$rel" --sha256 "$got")
  if [[ -n "$tls" ]]; then args+=(--tls "$tls"); fi
  if [[ -n "$email" ]]; then args+=(--email "$email"); fi
  log "running install.sh for $rel"
  bash "$dest/backend/deploy/install.sh" "${args[@]}"

  rotate_releases "$rel"
  log "install finished: $rel"
}

# ---------------------------------------------------------------- check

FAILS=0
PASS_N=0
WARN_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS $1 $2"; }
warn() { WARN_N=$((WARN_N + 1)); echo "WARN $1 $2"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL $1 $2"; }

http_code() {
  local c
  c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null)" || true
  echo "${c:-000}"
}

# port_state <port> : prints busy | free | unknown
port_state() {
  local p="$1" out
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltn 2>/dev/null | awk -v p="$p" 'NR > 1 { n = split($4, a, ":"); if (a[n] == p) f = 1 } END { print f ? "busy" : "free" }')"
    echo "${out:-unknown}"
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo busy; else echo free; fi
  else
    echo unknown
  fi
}

check_pre() {
  local id_ver os_id
  if [[ -r /etc/os-release ]]; then
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    id_ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    if [[ "$os_id" == debian && "$id_ver" == 13 ]]; then pass os "Debian 13"; else fail os "need Debian 13, found ${os_id:-unknown} ${id_ver:-}"; fi
  else
    fail os "/etc/os-release not readable"
  fi

  if command -v docker >/dev/null 2>&1; then pass docker "$(docker --version 2>/dev/null | head -1)"; else fail docker "docker is not installed (run prepare)"; fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    pass compose "docker compose plugin available"
  else
    fail compose "docker compose plugin missing"
  fi

  if id posthunt >/dev/null 2>&1; then
    pass user "user posthunt exists"
    local groups
    groups="$(id -nG posthunt 2>/dev/null || true)"
    if printf '%s' "$groups" | tr ' ' '\n' | grep -qx docker; then pass user.docker "posthunt is in group docker"; else fail user.docker "posthunt is not in group docker"; fi
    if printf '%s' "$groups" | tr ' ' '\n' | grep -qx sudo; then fail user.sudo "posthunt must not be in group sudo"; else pass user.sudo "posthunt is not in group sudo"; fi
  else
    fail user "user posthunt missing (run prepare)"
  fi

  local p st
  for p in 80 443; do
    st="$(port_state "$p")"
    case "$st" in
      free) pass "port.$p" "port $p is free" ;;
      busy) fail "port.$p" "port $p is already in use" ;;
      *)    warn "port.$p" "cannot check port $p (no ss/lsof)" ;;
    esac
  done

  local svc state
  for svc in ufw fail2ban; do
    state=""
    if command -v systemctl >/dev/null 2>&1; then state="$(systemctl is-active "$svc" 2>/dev/null || true)"; fi
    case "$state" in
      active) pass "$svc" "$svc is active" ;;
      "")     warn "$svc" "cannot read $svc state without sudo" ;;
      *)      fail "$svc" "$svc is $state" ;;
    esac
  done

  local sshc=/etc/ssh/sshd_config.d/99-posthunt.conf
  if [[ -r "$sshc" ]]; then
    if grep -Eq '^PasswordAuthentication[[:space:]]+no' "$sshc" && grep -Eq '^PermitRootLogin[[:space:]]+prohibit-password' "$sshc"; then
      pass ssh "SSH hardening present"
    else
      fail ssh "SSH hardening incomplete in $sshc"
    fi
  elif [[ -e "$sshc" ]]; then
    warn ssh "cannot read $sshc without sudo"
  else
    warn ssh "no SSH hardening file (run prepare) or sshd not installed"
  fi

  local free_kb mem_kb
  free_kb="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
    if [[ "$free_kb" -lt 10485760 ]]; then fail disk "free disk $((free_kb / 1048576)) GB, need >= 10 GB"
    elif [[ "$free_kb" -lt 20971520 ]]; then warn disk "free disk $((free_kb / 1048576)) GB, recommended >= 20 GB"
    else pass disk "free disk $((free_kb / 1048576)) GB"; fi
  else
    warn disk "cannot read free disk"
  fi
  mem_kb="$(awk '/MemTotal/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    if [[ "$mem_kb" -lt 2097152 ]]; then fail ram "RAM $((mem_kb / 1024)) MB, need >= 2 GB"
    elif [[ "$mem_kb" -lt 3900000 ]]; then warn ram "RAM $((mem_kb / 1024)) MB, recommended >= 4 GB"
    else pass ram "RAM $((mem_kb / 1024)) MB"; fi
  else
    warn ram "cannot read RAM size"
  fi
}

check_post() {
  local domain="$1" cur_ver="" inst_rel=""
  if [[ -L "$BASE/current" && -d "$BASE/current/" ]]; then
    cur_ver="$(basename "$(readlink "$BASE/current")")"
    pass current "current -> $cur_ver"
  else
    fail current "$BASE/current is missing"
  fi
  if [[ -f "$BASE/state/installed.json" ]]; then
    inst_rel="$(json_get "$BASE/state/installed.json" release)"
    if [[ -n "$cur_ver" && "$inst_rel" == "$cur_ver" ]]; then pass installed "installed.json release $inst_rel = current"
    else fail installed "installed.json release '${inst_rel}' differs from current '${cur_ver}'"; fi
  else
    fail installed "state/installed.json is missing"
  fi

  local ps_out=""
  if command -v docker >/dev/null 2>&1 && ps_out="$(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null)"; then
    local names bad="" n
    names="$(printf '%s\n' "$ps_out" | awk -F'|' '$1 ~ /^posthunt-/ { print $1 }')"
    for n in posthunt-api posthunt-ui posthunt-proxy; do
      if printf '%s\n' "$names" | grep -qx "$n"; then pass "container.$n" "$n present"; else fail "container.$n" "$n not found"; fi
    done
    bad="$(printf '%s\n' "$ps_out" | awk -F'|' '$1 ~ /^posthunt-/ && ($2 !~ /^Up/ || $2 ~ /unhealthy/) { print $1 " (" $2 ")" }')"
    if [[ -z "$bad" ]]; then pass containers "all posthunt-* containers are up, none unhealthy"; else fail containers "not up or unhealthy: $(printf '%s' "$bad" | tr '\n' ' ')"; fi
  else
    fail containers "cannot read docker containers"
  fi

  local c
  c="$(http_code http://127.0.0.1/health)"
  if [[ "$c" == 200 ]]; then pass health.http "http://127.0.0.1/health = 200"; else fail health.http "http://127.0.0.1/health = $c"; fi
  c="$(http_code -k https://127.0.0.1/)"
  if [[ "$c" == 200 ]]; then pass ui.https "https://127.0.0.1/ = 200"; else fail ui.https "https://127.0.0.1/ = $c"; fi
  if [[ -n "$domain" ]]; then
    c="$(http_code "https://$domain/health")"
    if [[ "$c" == 200 ]]; then pass health.domain "https://<domain>/health = 200"; else fail health.domain "https://<domain>/health = $c"; fi
  fi

  if [[ -d "$BASE/releases" ]]; then
    local junk
    # Sprint/, docs/, node_modules — только в корне релиза (backend/docs — документация API, не процесс);
    # .git / .cursor / .claude / Client_* — на любой глубине до frontend/.output.
    junk="$( { find "$BASE/releases" -mindepth 2 -maxdepth 2 \( -name Sprint -o -name docs -o -name node_modules \) ;
               find "$BASE/releases" -maxdepth 4 \( -name .git -o -name .cursor -o -name .claude -o -name 'Client_*' \) ; } 2>/dev/null | head -5 | tr '\n' ' ')"
    if [[ -z "$junk" ]]; then pass clean "no process files in releases/*"; else fail clean "forbidden paths in releases: $junk"; fi
  else
    fail clean "$BASE/releases is missing"
  fi

  if [[ -d "$BASE/env" ]]; then
    local m badf badd
    m="$(mode_of "$BASE/env")"
    if [[ "$m" == 700 ]]; then pass env.dir "env/ mode 700"; else fail env.dir "env/ mode is $m, need 700"; fi
    # env/letsencrypt ведёт certbot (root, свои права) — проверяем всё, кроме него.
    badf="$(find "$BASE/env" -path "$BASE/env/letsencrypt" -prune -o -type f ! -perm 600 -print 2>/dev/null | head -5 | tr '\n' ' ')"
    badd="$(find "$BASE/env" -mindepth 1 -path "$BASE/env/letsencrypt" -prune -o -type d ! -perm 700 -print 2>/dev/null | head -5 | tr '\n' ' ')"
    if [[ -z "$badf" && -z "$badd" ]]; then pass env.files "env/ files 600, dirs 700"; else fail env.files "wrong modes: $badf$badd"; fi
  else
    fail env.dir "$BASE/env is missing"
  fi

  local crt="" f
  if [[ -d "$BASE/env/certs" ]]; then
    for f in "$BASE"/env/certs/*.crt "$BASE"/env/certs/*.pem; do
      [[ -f "$f" ]] || continue
      case "$f" in *key*) continue ;; esac
      crt="$f"; break
    done
  fi
  if [[ -z "$crt" ]]; then
    warn cert "no certificate file found in env/certs"
  elif ! command -v openssl >/dev/null 2>&1; then
    warn cert "openssl not available, certificate lifetime not checked"
  elif openssl x509 -checkend $((20 * 86400)) -noout -in "$crt" >/dev/null 2>&1; then
    pass cert "certificate valid for more than 20 days"
  else
    fail cert "certificate expires within 20 days or cannot be read"
  fi
}

cmd_check() {
  local phase="" domain=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)  phase="${2:-}"; shift 2 ;;
      --domain) domain="${2:-}"; shift 2 ;;
      *) die "unknown option for check: $1" ;;
    esac
  done
  if [[ -z "$phase" ]]; then
    if [[ -e "$BASE/current" ]]; then phase=post; else phase=pre; fi
  fi
  [[ "$phase" == pre || "$phase" == post ]] || die "--phase must be pre or post"
  if [[ -n "$domain" && ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then die "invalid domain"; fi

  FAILS=0
  if [[ "$phase" == pre ]]; then check_pre; else check_post "$domain"; fi
  if [[ "$FAILS" -eq 0 ]]; then
    echo "check: ok"
    return 0
  fi
  echo "check: FAIL ($FAILS)"
  return 1
}

# ---------------------------------------------------------------- report

mask_secrets() {
  sed -E \
    -e 's/eyJ[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*/***/g' \
    -e 's/github_pat_[A-Za-z0-9_]+/***/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]+/***/g' \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|PASSWORD)=[^[:space:]]+/\1=***/g' \
    -e 's/([Tt][Oo][Kk][Ee][Nn]|TOKEN)=[^[:space:]]+/\1=***/g'
}

report_body() {
  echo "## posthunt-setup protocol $PROTOCOL"
  echo "## check"
  cmd_check --phase post || true
  echo "## versions"
  if command -v docker >/dev/null 2>&1; then docker compose version 2>&1 | head -1 || true; else echo "docker: not installed"; fi
  if [[ -f "$BASE/state/installed.json" ]]; then
    echo "installed: $(json_get "$BASE/state/installed.json" version)"
  else
    echo "installed: none"
  fi
}

cmd_report() {
  report_body 2>&1 | mask_secrets
}

# ---------------------------------------------------------------- main

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    prepare)  cmd_prepare "$@" ;;
    install)  cmd_install "$@" ;;
    check)    cmd_check "$@" ;;
    report)   cmd_report ;;
    version)  echo "$PROTOCOL" ;;
    -h|--help|help) usage ;;
    "") usage >&2; exit 2 ;;
    *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
