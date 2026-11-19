#!/usr/bin/env bash
# Publishes the releases of xaosControl on a web server of your own, a mirror, for
# servers that cannot reach get.xaos.cc or GitHub (docs/adr/027-network.md).
#
# On the mirror server, to copy the newest release from get.xaos.cc and GitHub:
#     curl -fsSL https://get.xaos.cc/mirror.sh | sudo bash -s -- \
#         --dir /var/www/mirror.example.ru/public --url https://mirror.example.ru
# Run it again after each release, or from cron: it does nothing when the mirror is up
# to date.
#
# From a checkout that has built and signed archives in dist/:
#     deploy/mirror.sh --dist dist --version v1.0.5 --dir /srv/mirror --url https://mirror.example.ru
# and then copy /srv/mirror to the web server as it is.
#
# What a mirror holds, all of it plain files:
#     latest.txt  CHANGELOG.md  install.sh  mirror.sh
#     releases/<version>/xaoscc_<version>_linux_<arch>.tar.gz and .minisig
# latest.txt is written last, so a panel never sees a version whose files are not there.
# The mirror needs no secret: panels and the installer check the signature of what it
# hands over against the release keys they carry.
set -euo pipefail

SITE_URL="https://get.xaos.cc"
RELEASES_URL="https://github.com/whoamnesia/xaoscc-releases/releases/download"
ARCHES="amd64 arm64"

DIR=""
URL=""
DIST=""
VERSION=""
KEEP=3

usage() {
  cat <<'USAGE'
Usage: mirror.sh --dir <directory> --url <https address of the mirror> [options]

  --dir <directory>    where the web server serves the mirror from
  --url <address>      the address the mirror answers at, https://host[/path]
  --dist <directory>   take the archives and signatures from this directory instead of
                       downloading them; needs --version
  --version <vX.Y.Z>   the release to publish (default: the newest one on get.xaos.cc)
  --from <address>     copy from another mirror instead of get.xaos.cc and GitHub
  --keep <n>           how many releases to keep on the mirror (default 3)
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

FROM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --url) URL="${2%/}"; shift 2 ;;
    --dist) DIST="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --from) FROM="${2%/}"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$DIR" ]] || die "--dir is required"
[[ "$URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] || die "--url must be an https address, such as https://mirror.example.ru"
[[ "$KEEP" =~ ^[1-9][0-9]?$ ]] || die "--keep takes a number from 1 to 99"
[[ -z "$DIST" || -n "$VERSION" ]] || die "--dist needs --version"
[[ -z "$VERSION" || "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version looks like v1.0.5"
command -v minisign >/dev/null || die "minisign is not installed (apt-get install minisign)"
command -v curl >/dev/null || [[ -n "$DIST" ]] || die "curl is not installed"

if [[ -n "$FROM" ]]; then
  SITE_URL="$FROM"
  RELEASES_URL="$FROM/releases"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
get() { curl -fsSL --connect-timeout 15 --speed-limit 2048 --speed-time 45 -o "$2" "$1"; }

# The installer and the change log: from the checkout next to this script, or from
# where the release is copied from.
if [[ -n "$DIST" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp "$here/install.sh" "$TMP/install.sh"
  cp "$here/mirror.sh" "$TMP/mirror.sh"
  cp "$here/../CHANGELOG.md" "$TMP/CHANGELOG.md"
else
  if [[ -z "$VERSION" ]]; then
    get "$SITE_URL/latest.txt" "$TMP/latest.txt" || die "$SITE_URL/latest.txt does not answer"
    VERSION=$(tr -d '[:space:]' < "$TMP/latest.txt")
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$SITE_URL/latest.txt does not hold a version"
  fi
  get "$SITE_URL/install.sh" "$TMP/install.sh" || die "$SITE_URL/install.sh does not answer"
  get "$SITE_URL/CHANGELOG.md" "$TMP/CHANGELOG.md" || : > "$TMP/CHANGELOG.md"
  get "$SITE_URL/mirror.sh" "$TMP/mirror.sh" || rm -f "$TMP/mirror.sh"
fi

if [[ -f "$DIR/latest.txt" && "$(tr -d '[:space:]' < "$DIR/latest.txt")" == "$VERSION" && -z "$DIST" ]]; then
  echo "The mirror already has $VERSION."
  exit 0
fi

# The keys are the installer's: a mirror publishes only what installers will accept.
KEYS=$(sed -n 's/^RELEASE_PUBKEYS="\(.*\)"$/\1/p' "$TMP/install.sh")
[[ -n "$KEYS" ]] || die "the installer names no release keys"

mkdir -p "$TMP/rel"
for arch in $ARCHES; do
  archive="xaoscc_${VERSION}_linux_${arch}.tar.gz"
  if [[ -n "$DIST" ]]; then
    cp "$DIST/$archive" "$DIST/$archive.minisig" "$TMP/rel/" || die "$DIST has no $archive with its signature"
  else
    get "$RELEASES_URL/$VERSION/$archive" "$TMP/rel/$archive" \
      && get "$RELEASES_URL/$VERSION/$archive.minisig" "$TMP/rel/$archive.minisig" \
      || die "$archive or its signature is not at $RELEASES_URL/$VERSION"
  fi
  ok=no
  for key in $KEYS; do
    if minisign -Vm "$TMP/rel/$archive" -P "$key" >/dev/null 2>&1; then
      ok=yes
      break
    fi
  done
  [[ $ok == yes ]] || die "the signature of $archive does not verify; nothing was published"
done

# The copy of the installer on the mirror asks the mirror first.
grep -q '^SELF_URL=' "$TMP/install.sh" || die "this installer is older than mirrors; publish a newer release"
sed -i "s#^SELF_URL=.*#SELF_URL=\"$URL\"#" "$TMP/install.sh"

mkdir -p "$DIR/releases/$VERSION"
for f in "$TMP"/rel/*; do
  install -m 0644 "$f" "$DIR/releases/$VERSION/.$(basename "$f").part"
  mv -f "$DIR/releases/$VERSION/.$(basename "$f").part" "$DIR/releases/$VERSION/$(basename "$f")"
done
for f in install.sh CHANGELOG.md mirror.sh; do
  [[ -f "$TMP/$f" ]] || continue
  install -m 0644 "$TMP/$f" "$DIR/.$f.part"
  mv -f "$DIR/.$f.part" "$DIR/$f"
done
printf '%s\n' "$VERSION" > "$DIR/.latest.txt.part"
chmod 0644 "$DIR/.latest.txt.part"
mv -f "$DIR/.latest.txt.part" "$DIR/latest.txt"

# Older releases make way; the newest ones stay for panels that are in the middle of an update.
mapfile -t old < <(cd "$DIR/releases" && ls -1d v*.*.* 2>/dev/null | sort -V | head -n -"$KEEP")
for v in "${old[@]}"; do
  [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$v" != "$VERSION" ]] && rm -rf "${DIR:?}/releases/$v"
done

echo "Published $VERSION at $URL"
echo "Install from this mirror:  curl -fsSL $URL/install.sh | sudo bash"
echo "Add it to a panel:         Settings, Network, Update sources: $URL"
