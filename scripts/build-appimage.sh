#!/usr/bin/env bash
# build-appimage.sh — package the built kimi-app into a self-contained AppImage.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info() { printf '\033[1;34m[build-appimage]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build-appimage error]\033[0m %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib/install-helpers.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/lib/package-common.sh"

resolve_package_version

case "$(detect_arch)" in
	x64)   ai_arch="x86_64" ;;
	arm64) ai_arch="aarch64" ;;
	*)     die "no AppImage arch for $(detect_arch)" ;;
esac

DIST_DIR="$SCRIPT_DIR/dist"
APPDIR="$DIST_DIR/kimi-work.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"

info "staging AppDir (version=$PACKAGE_VERSION, arch=$ai_arch)..."
stage_common_package_files "$APPDIR"

# AppImage root pieces: AppRun, desktop entry, root icon.
cp "$SCRIPT_DIR/packaging/appimage/AppRun" "$APPDIR/AppRun"
chmod 0755 "$APPDIR/AppRun"
cp "$SCRIPT_DIR/packaging/linux/kimi-work.desktop" "$APPDIR/kimi-work.desktop"
if [ -f "$APPDIR/opt/kimi-work/icon.png" ]; then
	cp "$APPDIR/opt/kimi-work/icon.png" "$APPDIR/kimi-work.png"
fi

# Acquire appimagetool (cached under .cache/), unless APPIMAGETOOL is set.
AT_CACHE="$SCRIPT_DIR/.cache/appimagetool"
APPIMAGETOOL="${APPIMAGETOOL:-}"
if [ -z "$APPIMAGETOOL" ]; then
	APPIMAGETOOL="$AT_CACHE/appimagetool-${ai_arch}.AppImage"
	if [ ! -f "$APPIMAGETOOL" ]; then
		mkdir -p "$AT_CACHE"
		info "downloading appimagetool (${ai_arch})..."
		curl -fL "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${ai_arch}.AppImage" -o "$APPIMAGETOOL"
		chmod +x "$APPIMAGETOOL"
	fi
fi

OUT="$DIST_DIR/KimiWork-${PACKAGE_VERSION}-${ai_arch}.AppImage"
info "building AppImage..."
# Run appimagetool directly when FUSE works; fall back to extract-and-run
# for environments without /dev/fuse (containers, restricted CI).
if "$APPIMAGETOOL" --appimage-version >/dev/null 2>&1; then
	ARCH="$ai_arch" VERSION="$PACKAGE_VERSION" "$APPIMAGETOOL" --no-appstream "$APPDIR" "$OUT"
else
	info "appimagetool cannot run directly (no FUSE?); using --appimage-extract-and-run"
	ARCH="$ai_arch" VERSION="$PACKAGE_VERSION" "$APPIMAGETOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUT"
fi
chmod +x "$OUT"
info "built $OUT ($(du -h "$OUT" | cut -f1))"
