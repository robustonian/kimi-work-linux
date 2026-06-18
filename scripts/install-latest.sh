#!/usr/bin/env bash
# install-latest.sh — one-command install / update of Kimi Work on Linux.
#
#   1. Ensures host build deps (+ modern 7zz)
#   2. Detects the latest upstream Kimi Work version (via Moonshot's redirect)
#   3. Compares against the installed version (skip if up-to-date, unless --force)
#   4. Rebuilds kimi-app from the latest DMG (always --fresh)
#   5. Builds the native package for this distro (.deb on Debian/Ubuntu)
#   6. Installs it (may prompt for sudo)
#   7. Prints latest / installed-before / installed-now versions
#
# Usage: bash scripts/install-latest.sh [--force]
# Env:   PKG_ONLY=deb   force .deb packaging
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/install-helpers.sh"

PACKAGE_NAME="${PACKAGE_NAME:-kimi-work}"
SYSTEM_APP_ASAR="/opt/$PACKAGE_NAME/electron/resources/app.asar"

FORCE=0
for a in "$@"; do
	case "$a" in
		--force|-f) FORCE=1 ;;
		-h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown arg: $a (try --help)" >&2; exit 2 ;;
	esac
done

info() { printf '\033[1;34m[kimi-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kimi-install]\033[0m %s\n' "$*"; }

print_kv() { printf '  %-26s %s\n' "$1" "$2"; }

# --- version detection -------------------------------------------------------

# Latest published version. Moonshot's redirect endpoint
# (appsupport.moonshot.cn/api/app/pkg/latest/macos/download) 302s to
# https://kimi-img.moonshot.cn/app/download/mac/kimi_<ver>.dmg — we parse the
# version out of the Location header. The endpoint rejects HEAD (400), so we
# GET-without-follow and discard the body.
detect_latest_upstream_version() {
	if [ -n "${KIMI_VERSION:-}" ]; then
		echo "$KIMI_VERSION"; return 0
	fi
	local redirect_url="${KIMI_UPSTREAM_DOWNLOAD_URL:-https://appsupport.moonshot.cn/api/app/pkg/latest/macos/download}"
	local loc
	loc="$(curl -fsS --max-time 20 --connect-timeout 8 -o /dev/null -D - -- "$redirect_url" 2>/dev/null \
		| awk -F': ' 'tolower($1)=="location"{gsub(/\r/,"",$2);print $2;exit}')"
	[ -n "$loc" ] || { echo "${KIMI_KNOWN_VERSION:-3.0.22}"; return 0; }
	# kimi_<ver>.dmg → <ver>
	local fn; fn="$(basename "$loc")"
	sed -nE 's/^[Kk]imi[_-]([0-9][0-9.a-zA-Z_-]*)\.(dmg|exe|zip|pkg)$/\1/p' <<<"$fn" \
		|| echo "${KIMI_KNOWN_VERSION:-3.0.22}"
}

# Currently installed version (dpkg, else the installed app.asar's package.json).
installed_version() {
	if command -v dpkg-query >/dev/null 2>&1 \
		&& dpkg-query -W -f='${Version}' "$PACKAGE_NAME" >/dev/null 2>&1; then
		dpkg-query -W -f='${Version}' "$PACKAGE_NAME" | sed 's/-klinux[0-9]*//'
		return
	fi
	local asar="$SYSTEM_APP_ASAR"
	if [ -f "$asar" ] && command -v npx >/dev/null 2>&1; then
		npx --yes asar extract-file "$asar" package.json 2>/dev/null \
			| python3 -c "import json,sys;print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true
	fi
}

# --- main --------------------------------------------------------------------

main() {
	info "ensuring host dependencies..."
	( cd "$REPO_DIR" && make install-deps ) || warn "install-deps reported an issue; continuing"

	local latest installed
	latest="$(detect_latest_upstream_version || true)"
	installed="$(installed_version || true)"
	info "latest upstream: ${latest:-<unknown>}"
	info "installed:       ${installed:-<none>}"

	if [ "$FORCE" != 1 ] && [ -n "$latest" ] && [ -n "$installed" ] && [ "$latest" = "$installed" ]; then
		info "already up-to-date ($installed). Re-run with --force to rebuild."
		return 0
	fi

	info "rebuilding from the latest DMG (--fresh)..."
	( cd "$REPO_DIR" && ./install.sh --fresh ) || { warn "build failed"; return 1; }

	info "building native package..."
	local artifact=""
	if command -v dpkg-deb >/dev/null 2>&1; then
		( cd "$REPO_DIR" && bash scripts/build-deb.sh ) || { warn ".deb build failed"; return 1; }
		artifact="$(ls -t "$REPO_DIR"/dist/*.deb 2>/dev/null | head -n1)"
	fi

	if [ -n "$artifact" ]; then
		info "installing $(basename "$artifact") (sudo)..."
		sudo dpkg -i "$artifact" || sudo apt-get -f install -y
	else
		warn "no native package produced for this distro."
		info "run the app directly: $REPO_DIR/kimi-app/start.sh"
	fi

	local now; now="$(installed_version || true)"
	info "result: latest=${latest:-?}  before=${installed:-none}  now=${now:-none}"
}

main "$@"
