#!/usr/bin/env bash
# build-deb.sh — package the built kimi-app into a .deb (dpkg-deb, no fpm).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info() { printf '\033[1;34m[build-deb]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build-deb error]\033[0m %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib/install-helpers.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib/package-common.sh"

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found (apt-get install dpkg-dev)"

resolve_package_version
local_arch="$(pkg_arch)"

DIST_DIR="$SCRIPT_DIR/dist"
STAGE="$DIST_DIR/deb-root"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST_DIR"

info "staging common files (version=$PACKAGE_VERSION, arch=$local_arch)..."
stage_common_package_files "$STAGE"

# DEBIAN/control from the template.
mkdir -p "$STAGE/DEBIAN"
sed -e "s/__PACKAGE__/$PACKAGE_NAME/g" \
	-e "s/__VERSION__/$PACKAGE_VERSION/g" \
	-e "s/__ARCH__/$local_arch/g" \
	"$SCRIPT_DIR/packaging/linux/control" > "$STAGE/DEBIAN/control"

OUT="$DIST_DIR/${PACKAGE_NAME}_${PACKAGE_VERSION}_${local_arch}.deb"
info "building .deb..."
dpkg-deb --root-owner-group --build "$STAGE" "$OUT"
info "built $OUT ($(du -h "$OUT" | cut -f1))"
