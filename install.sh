#!/usr/bin/env bash
# xaosControl installer for a clean Ubuntu 24.04 server.
#
#   From a release archive:  tar xzf xaoscc_*.tar.gz && sudo ./xaoscc_*/install.sh
#   One-liner, which downloads the latest release and checks its signature:
#       curl -fsSL https://get.xaos.cc/install.sh | sudo bash
#
# Running it again upgrades the binaries and leaves config, keys and data alone.
#
# On a server that runs aaPanel, --beside-aapanel installs the panel next to it: aaPanel
# goes on serving the sites, and the panel moves them over when a person says so.
set -euo pipefail

# Where a release comes from. get.xaos.cc holds this installer and the number of the
# latest version; the archives and their signatures are release assets of the public
# repository on GitHub.
SITE_URL="https://get.xaos.cc"
RELEASES_URL="https://github.com/whoamnesia/xaoscc-releases/releases/download"
# minisign public key that release archives are signed with (key id 5357BA8306410571).
# The secret half belongs to the owner and lives outside this repository and outside any
# server. A downloaded archive that this key does not vouch for is not installed.
RELEASE_PUBKEY="RWRxBUEGg7pXUzp95Z1flPPOdPtt1cX9Kq7fc9rjF4nP+8KlBqJGb3gw"

PORT=8743
HOST=""
EMAIL=""
ALLOW=""
ACCESS=""
FIREWALL=yes
FORCE=no
ASSUME_YES=no
BESIDE=no

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

  --host <domain|ip>   address the panel will be opened by
  --email <email>      email of the first owner
  --port <n>           panel port (default 8743)
  --allow <list>       comma-separated IPs or CIDR networks allowed to open the panel
  --tailscale          allow the Tailscale address ranges only
  --open               allow any address (not recommended)
  --no-firewall        do not touch ufw
  --beside-aapanel     install next to aaPanel, which keeps ports 80, 443 and 3306
                       until its sites are switched over in the panel
  --force              continue even if ports 80/443 are taken or another panel is found
  --yes                never ask; fail if a required answer is missing
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --allow) ALLOW="$2"; ACCESS=allow; shift 2 ;;
    --tailscale) ACCESS=tailscale; shift ;;
    --open) ACCESS=open; shift ;;
    --no-firewall) FIREWALL=no; shift ;;
    --force) FORCE=yes; shift ;;
    --beside-aapanel) BESIDE=yes; shift ;;
    --yes) ASSUME_YES=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

ask() { # ask <variable> <prompt> [default]
  local var="$1" prompt="$2" default="${3:-}" answer=""
  [[ -n "${!var}" ]] && return 0
  if [[ $ASSUME_YES == yes || ! -r /dev/tty ]]; then
    [[ -n "$default" ]] || die "$prompt: pass it as an option when running without a terminal"
    printf -v "$var" '%s' "$default"
    return 0
  fi
  read -r -p "$prompt${default:+ [$default]}: " answer </dev/tty
  printf -v "$var" '%s' "${answer:-$default}"
  [[ -n "${!var}" ]] || die "$prompt is required"
}

port_in_use() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

# ---------------------------------------------------------------- preflight

[[ $EUID -eq 0 ]] || die "run the installer as root (sudo)"

. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] \
  || die "xaosControl supports Ubuntu 24.04 only; this is ${PRETTY_NAME:-an unknown system}"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

[[ -d /run/systemd/system ]] || die "systemd is not running on this machine"

free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
(( free_mb >= 1024 )) || die "at least 1 GB of free space is needed on /, found ${free_mb} MB"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "invalid port: $PORT"

UPGRADE=no
[[ -f /etc/xaoscc/xaoscc.toml ]] && UPGRADE=yes

# A panel that was installed next to aaPanel stays there on every later run, until the
# sites are switched over: the agent keeps the mark.
AAPANEL=/www/server/panel
[[ -f /var/lib/xaoscc-agent/beside.json ]] && BESIDE=yes
if [[ $BESIDE == yes ]]; then
  [[ -d $AAPANEL || $UPGRADE == yes ]] || die "--beside-aapanel: aaPanel was not found in $AAPANEL"
elif [[ $UPGRADE == no && -e $AAPANEL ]]; then
  # Not something --force may wave through: a second nginx on the ports of aaPanel
  # takes its sites down.
  die "aaPanel is installed on this server ($AAPANEL). Rerun with --beside-aapanel: the panel is then installed next to it and moves the sites when you say so"
fi

if [[ $UPGRADE == no && $FORCE == no ]]; then
  for dir in /usr/local/cpanel /usr/local/hestia /usr/local/vesta /usr/local/CyberCP; do
    [[ -e $dir ]] && die "another control panel is installed ($dir). Move the sites first or rerun with --force"
  done
  if [[ $BESIDE == no ]]; then
    for p in 80 443; do
      if port_in_use "$p" && ! systemctl is-active --quiet nginx; then
        die "port $p is already in use by another program. Free it or rerun with --force"
      fi
    done
  fi
  port_in_use "$PORT" && die "port $PORT is already in use, choose another with --port"
fi

# ---------------------------------------------------------------- release files

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if [[ -z "$SRC" || ! -x "$SRC/xaosccd" ]]; then
  say "Downloading the latest release"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates minisign >/dev/null
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  version=$(curl -fsSL "$SITE_URL/latest.txt") \
    || die "no release list at $SITE_URL. Download a release archive and run install.sh from inside it"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected version string from $SITE_URL"
  archive="xaoscc_${version}_linux_${ARCH}.tar.gz"
  curl -fsSL -o "$TMP/$archive" "$RELEASES_URL/$version/$archive" \
    && curl -fsSL -o "$TMP/$archive.minisig" "$RELEASES_URL/$version/$archive.minisig" \
    || die "release $version for $ARCH or its signature is not at $RELEASES_URL"
  minisign -Vm "$TMP/$archive" -P "$RELEASE_PUBKEY" >/dev/null \
    || die "the release signature does not verify; nothing was installed"
  tar -xzf "$TMP/$archive" -C "$TMP"
  SRC="$TMP/${archive%.tar.gz}"
fi

for f in xaosccd xaoscc-agent xaoscc systemd/xaosccd.service systemd/xaoscc-agent.service \
  fail2ban/filter.conf fail2ban/jail.conf ssh/60-xaoscc-sftp.conf logrotate/xaoscc-sites; do
  [[ -f "$SRC/$f" ]] || die "release is incomplete: $f is missing"
done

# ---------------------------------------------------------------- questions

if [[ $UPGRADE == no ]]; then
  default_host=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n1)
  ask HOST "Domain or IP the panel will be opened by" "$default_host"
  ask EMAIL "Email of the first owner"

  if [[ -z "$ACCESS" ]]; then
    ssh_ip="${SSH_CONNECTION%% *}"
    if [[ $ASSUME_YES == yes || ! -r /dev/tty ]]; then
      die "choose who may open the panel: --allow <ips>, --tailscale or --open"
    fi
    cat <<CHOICES

Who may open the panel?
  1) Only listed IP addresses${ssh_ip:+ (your address is $ssh_ip)}
  2) Only Tailscale (recommended if the team already uses it)
  3) Anyone who knows the address (not recommended)
CHOICES
    choice=""
    read -r -p "Choice [1]: " choice </dev/tty
    case "${choice:-1}" in
      1) ACCESS=allow; ask ALLOW "Allowed IPs or networks, comma-separated" "$ssh_ip" ;;
      2) ACCESS=tailscale ;;
      3) ACCESS=open ;;
      *) die "unknown choice" ;;
    esac
  fi
  case "$ACCESS" in
    allow) [[ -n "$ALLOW" ]] || die "--allow needs at least one address" ;;
    tailscale) ALLOW="100.64.0.0/10,fd7a:115c:a1e0::/48" ;;
    open) ALLOW=""; warn "the panel will accept connections from any address" ;;
  esac
fi

# ---------------------------------------------------------------- packages

say "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg ufw fail2ban restic logrotate software-properties-common \
  git openssh-client rsync >/dev/null

# PHP versions come from ppa:ondrej/php (FR-PHP-1). The repository is added here, where a
# person sees the output; the panel installs the packages later, when a version is asked for.
if ! compgen -G '/etc/apt/sources.list.d/ondrej-ubuntu-php-*' >/dev/null; then
  add-apt-repository --yes --no-update ppa:ondrej/php >/dev/null 2>&1 \
    || warn "could not add ppa:ondrej/php; the panel will try again when a PHP version is installed"
fi

if [[ $BESIDE == yes ]]; then
  # Before the first package: the name nginx is pinned to the nginx of aaPanel and its
  # MySQL options are kept away from the MySQL of the panel. See internal/agent/beside.
  "$SRC/xaoscc-agent" -beside-aapanel
fi

if ! dpkg -s nginx >/dev/null 2>&1; then
  say "Installing nginx from nginx.org (stable)"
  keyring=/usr/share/keyrings/nginx-archive-keyring.gpg
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o "$keyring"
  gpg --show-keys --with-colons "$keyring" | grep -q '^fpr:.*:573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62:' \
    || { rm -f "$keyring"; die "the nginx.org signing key does not have the expected fingerprint"; }
  echo "deb [signed-by=$keyring] https://nginx.org/packages/ubuntu noble nginx" > /etc/apt/sources.list.d/nginx.list
  printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' > /etc/apt/preferences.d/99nginx
  apt-get update -qq
  if [[ $BESIDE == yes ]]; then
    # The package brings a start script of the same name as aaPanel's and would start
    # its nginx. aaPanel's script stays, and nothing is started.
    kept=$(mktemp)
    [[ -f /etc/init.d/nginx ]] && cp -a /etc/init.d/nginx "$kept"
    policy=no
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
      printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
      chmod 0755 /usr/sbin/policy-rc.d
      policy=yes
    fi
    apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold nginx >/dev/null \
      || { [[ $policy == no ]] || rm -f /usr/sbin/policy-rc.d; die "nginx could not be installed"; }
    [[ $policy == no ]] || rm -f /usr/sbin/policy-rc.d
    if [[ -s $kept ]] && ! cmp -s "$kept" /etc/init.d/nginx; then
      cp -a "$kept" /etc/init.d/nginx
    fi
    rm -f "$kept"
  else
    apt-get install -y -qq nginx >/dev/null
  fi
fi

# nginx.org ships conf.d only. The panel keeps the Debian layout the team is used to,
# and workers run as www-data so that site files can be shared through that group.
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
if [[ ! -f /etc/nginx/conf.d/xaoscc-sites.conf ]] && ! grep -qs 'sites-enabled' /etc/nginx/nginx.conf; then
  cat > /etc/nginx/conf.d/xaoscc-sites.conf <<'NGINX'
# Managed by xaosCC. Manual changes will be overwritten.
include /etc/nginx/sites-enabled/*.conf;
NGINX
fi
sed -i 's/^user[[:space:]]\+nginx;/user www-data;/' /etc/nginx/nginx.conf
/usr/sbin/nginx -t -q || die "nginx configuration test failed; see the message above"

# ---------------------------------------------------------------- panel

say "Installing xaosControl"
id -u xaoscc >/dev/null 2>&1 \
  || useradd --system --user-group --home-dir /var/lib/xaoscc --no-create-home --shell /usr/sbin/nologin xaoscc

systemctl stop xaosccd.service xaoscc-agent.service 2>/dev/null || true
install -o root -g root -m 0755 "$SRC/xaosccd" "$SRC/xaoscc-agent" "$SRC/xaoscc" /usr/local/bin/
install -o root -g root -m 0644 "$SRC/systemd/xaosccd.service" "$SRC/systemd/xaoscc-agent.service" /etc/systemd/system/

# ---------------------------------------------------------------- sites

# Shared by every site. nginx and PHP workers pass through these directories, so they are
# open for traversal; what belongs to one site is closed below them by the agent.
install -d -o root -g root -m 0755 /var/www /var/log/xaoscc-sites /etc/ssh/xaoscc /etc/ssh/xaoscc/keys
install -d -o root -g root -m 0700 /var/backups/xaoscc /var/lib/xaoscc-agent

# HTTP-01 challenge files: written by the panel, read by nginx.
install -d -o root -g root -m 0755 /var/lib/xaoscc-acme /var/lib/xaoscc-acme/.well-known
install -d -o xaoscc -g xaoscc -m 0755 /var/lib/xaoscc-acme/.well-known/acme-challenge

install -o root -g root -m 0644 "$SRC/logrotate/xaoscc-sites" /etc/logrotate.d/xaoscc-sites

# Site users sign in with keys from the panel and get SFTP inside their site, nothing else (FR-USERS-6).
getent group xaoscc-sftp >/dev/null || groupadd --system xaoscc-sftp
if command -v sshd >/dev/null 2>&1 && [[ -d /etc/ssh/sshd_config.d ]]; then
  dropin=/etc/ssh/sshd_config.d/60-xaoscc-sftp.conf
  install -o root -g root -m 0644 "$SRC/ssh/60-xaoscc-sftp.conf" "$dropin"
  if sshd -t 2>/dev/null; then
    ! systemctl is-active --quiet ssh.service || systemctl reload ssh.service
  else
    rm -f "$dropin"
    warn "sshd rejected the SFTP rules, so they were not installed; SSH keys added in the panel will not work"
  fi
else
  warn "OpenSSH server is not installed; SSH keys added in the panel will not work until it is"
fi

LINK=""
if [[ $UPGRADE == no ]]; then
  LINK=$(xaoscc init --host "$HOST" --email "$EMAIL" --port "$PORT" --allow "$ALLOW")
else
  PORT=$(awk -F'[":]' '/^[[:space:]]*listen[[:space:]]*=/ {print $(NF-1)}' /etc/xaoscc/xaoscc.toml)
fi

install -o root -g root -m 0644 "$SRC/fail2ban/filter.conf" /etc/fail2ban/filter.d/xaoscc.conf
sed "s/@PORT@/$PORT/" "$SRC/fail2ban/jail.conf" > /etc/fail2ban/jail.d/xaoscc.conf

# ---------------------------------------------------------------- firewall

if [[ $FIREWALL == yes && $UPGRADE == no && $BESIDE == yes ]]; then
  # The firewall is aaPanel's to switch on: enabling it here would close the ports of
  # services it runs and this installer knows nothing of. Only the panel's port is added.
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    say "Opening the port of the panel in the firewall"
    if [[ -n "$ALLOW" ]]; then
      IFS=',' read -ra nets <<<"$ALLOW"
      for net in "${nets[@]}"; do
        ufw allow from "${net// /}" to any port "$PORT" proto tcp comment 'xaosControl' >/dev/null
      done
    else
      ufw allow "$PORT/tcp" comment 'xaosControl' >/dev/null
    fi
  else
    warn "the firewall is off and was left off; the panel on port $PORT is reachable from any address"
  fi
elif [[ $FIREWALL == yes && $UPGRADE == no ]]; then
  say "Configuring the firewall"
  # SSH first, on whatever ports sshd really listens, so enabling ufw cannot lock anyone out.
  # sshd -T fails where sshd is missing or has no host keys yet; port 22 is the fallback.
  ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true)
  for p in ${ssh_ports:-22}; do ufw allow "$p/tcp" comment 'SSH' >/dev/null; done
  ufw allow 80/tcp comment 'HTTP' >/dev/null
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
  if [[ -n "$ALLOW" ]]; then
    IFS=',' read -ra nets <<<"$ALLOW"
    for net in "${nets[@]}"; do
      ufw allow from "${net// /}" to any port "$PORT" proto tcp comment 'xaosControl' >/dev/null
    done
  else
    ufw allow "$PORT/tcp" comment 'xaosControl' >/dev/null
  fi
  ufw --force enable >/dev/null
fi

# ---------------------------------------------------------------- start

say "Starting services"
systemctl daemon-reload
# Next to aaPanel the name nginx is its nginx, and it is running.
[[ $BESIDE == yes ]] || systemctl enable --now nginx.service >/dev/null 2>&1
systemctl enable --now xaoscc-agent.service xaosccd.service >/dev/null 2>&1
systemctl enable fail2ban.service >/dev/null 2>&1
systemctl restart fail2ban.service

for _ in $(seq 1 30); do
  if curl -ksf --noproxy '*' -o /dev/null "https://127.0.0.1:$PORT/healthz"; then
    ready=yes
    break
  fi
  sleep 1
done
[[ "${ready:-no}" == yes ]] || die "the panel did not start. Check: journalctl -u xaosccd -u xaoscc-agent -n 50"

echo
echo "xaosControl $(xaoscc version) is running."
if [[ -n "$LINK" ]]; then
  echo "$LINK"
  echo
  echo "Open the link, set a password and connect an authenticator app."
  echo "The certificate is self-signed for now, so the browser will ask to confirm it."
  if [[ $BESIDE == yes ]]; then
    echo
    echo "aaPanel goes on serving the sites. To move them: Settings, Move from aaPanel."
  fi
else
  echo "Upgrade finished. Config, keys and data were not changed."
fi
