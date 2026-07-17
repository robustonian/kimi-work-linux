#!/usr/bin/env bash
# package-common.sh — shared staging logic for native packages (.deb / AppImage).
# Sourced by scripts/build-deb.sh and scripts/build-appimage.sh.
# Expects info()/die() and detect_arch() to be defined by the caller.

PACKAGE_NAME="${PACKAGE_NAME:-kimi-work}"

# Resolve a package version: explicit env > inspect-report.json > KIMI_VERSION > fallback.
resolve_package_version() {
	if [ -n "${PACKAGE_VERSION:-}" ]; then return; fi
	local report="$SCRIPT_DIR/inspect-report.json"
	if [ -f "$report" ]; then
		local v
		v="$(python3 -c "import json;print(json.load(open('$report'))['package_json']['version'])" 2>/dev/null || true)"
		PACKAGE_VERSION="${v:+${v}-klinux1}"
	fi
	if [ -z "${PACKAGE_VERSION:-}" ] && [ -n "${KIMI_VERSION:-}" ]; then
		PACKAGE_VERSION="${KIMI_VERSION}-klinux1"
	fi
	if [ -z "${PACKAGE_VERSION:-}" ]; then
		PACKAGE_VERSION="0.0.0-klinux1"
	fi
}

# Map our arch to the target package arch suffix.
pkg_arch() {
	case "$(detect_arch)" in
		x64)   echo amd64 ;;
		arm64) echo arm64 ;;
		*)     die "no package arch for $(detect_arch)" ;;
	esac
}

# Stage the common install tree into <root>: opt/<pkg>/, usr/bin/, usr/share/...
stage_common_package_files() {
	local root="$1"
	local app_dir="${2:-$SCRIPT_DIR/kimi-app}"
	[ -d "$app_dir" ] || die "kimi-app not built: $app_dir (run: make build-app)"

	# opt/<pkg>/ = the runnable app
	local opt_root="$root/opt/$PACKAGE_NAME"
	mkdir -p "$opt_root"
	cp -a "$app_dir/." "$opt_root/"

	# Remove macOS extended-attribute files (names contain a colon, e.g.
	# "filename:com.apple.provenance"). These are illegal in CI artifact
	# uploads and serve no purpose on Linux.
	find "$opt_root" -type f -name '*:*' -delete 2>/dev/null || true

	# Remove AppleDouble resource-fork shadow files (._*).
	find "$opt_root" -type f -name '._*' -delete 2>/dev/null || true

	# /usr/bin launcher shim
	mkdir -p "$root/usr/bin"
	cat > "$root/usr/bin/$PACKAGE_NAME" <<EOF
#!/bin/sh
exec /opt/$PACKAGE_NAME/start.sh "\$@"
EOF
	chmod 0755 "$root/usr/bin/$PACKAGE_NAME"

	# desktop entry + icon
	local pkg_dir="$SCRIPT_DIR/packaging/linux"
	mkdir -p "$root/usr/share/applications"
	cp "$pkg_dir/$PACKAGE_NAME.desktop" "$root/usr/share/applications/"

	if [ -f "$opt_root/icon.png" ]; then
		mkdir -p "$root/usr/share/icons/hicolor/256x256/apps"
		cp "$opt_root/icon.png" "$root/usr/share/icons/hicolor/256x256/apps/$PACKAGE_NAME.png"
	fi

	# Normalize permissions, but preserve exec bits inside the Electron
	# runtime tree. chrome_crashpad_handler MUST stay executable or the app
	# traps (SIGTRAP / core dump) on startup.
	find "$root" -type d -exec chmod 0755 {} \; 2>/dev/null || true
	find "$root" -type f ! -path "$opt_root/electron/*" -exec chmod 0644 {} \; 2>/dev/null || true
	chmod 0755 "$root/usr/bin/$PACKAGE_NAME" "$opt_root/start.sh" 2>/dev/null || true
	chmod 0755 "$opt_root/electron/electron" \
	           "$opt_root/electron/chrome_crashpad_handler" \
	           "$opt_root/electron/chrome-sandbox" 2>/dev/null || true
	find "$opt_root/electron" -type f \( -name "*.so" -o -name "*.so.*" \) \
		-exec chmod 0755 {} \; 2>/dev/null || true
}
