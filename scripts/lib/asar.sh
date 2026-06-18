#!/usr/bin/env bash
# asar.sh — extract app.asar, strip macOS-only pieces, repack deterministically.
# Sourced by install.sh (do not execute directly).

# Extract app.asar into a directory. Sets ASAR_EXTRACTED_DIR.
asar_extract() {
	local asar="${1:-}"
	local dest="${2:-$SCRIPT_DIR/app-extracted}"
	[ -n "$asar" ] && [ -f "$asar" ] || die "no app.asar to extract"
	rm -rf "$dest"
	mkdir -p "$dest"
	info "extracting app.asar → $dest"
	npx --yes asar extract "$asar" "$dest" >/dev/null
	ASAR_EXTRACTED_DIR="$dest"
	export ASAR_EXTRACTED_DIR
}

# Remove non-Linux native artifacts that cannot run on Linux.
# Verified against Kimi Work 3.0.22:
#   @minify-html/node-darwin-arm64  → swapped (native-modules.sh installs linux)
#   @napi-rs/canvas-darwin-arm64    → swapped (native-modules.sh installs linux)
#   fsevents                        → deleted (macOS-only; chokidar falls back)
#   @esbuild/darwin-*               → deleted (build-time only, unused at runtime)
#   @sentry/cli-darwin              → deleted (optional sentry CLI binary)
#   node-mac-permissions / sparkle  → deleted if present
#
# We delete the darwin sibling packages AFTER install_linux_prebuilds() has
# added the linux ones, so the optionalDependencies loader picks the linux
# package at runtime. (Order: install_linux_prebuilds runs first in install.sh,
# then strip_non_linux_natives is a no-op for these; but we also call strip
# defensively from the standalone pipeline. Both are safe because the linux
# packages use distinct names.)
strip_non_linux_natives() {
	local dir="${1:-$ASAR_EXTRACTED_DIR}"
	[ -d "$dir" ] || die "no extracted dir to strip"
	info "stripping non-Linux native artifacts..."

	# ── (1) main asar tree ──────────────────────────────────────────────────
	# Darwin sibling packages that have Linux equivalents installed elsewhere.
	# Keep this a glob so future arch suffixes are covered.
	rm -rf "$dir/node_modules/@minify-html/node-darwin-"* 2>/dev/null || true
	rm -rf "$dir/node_modules/@napi-rs/canvas-darwin-"* 2>/dev/null || true
	rm -rf "$dir/node_modules/@minify-html/node-win32-"* 2>/dev/null || true
	rm -rf "$dir/node_modules/@napi-rs/canvas-win32-"* 2>/dev/null || true

	# fsevents — macOS-only FS watcher. chokidar auto-detects its absence and
	# falls back to recursive directory polling on Linux.
	rm -rf "$dir/node_modules/fsevents" 2>/dev/null || true
	find "$dir" -path "*/fsevents/*.node" -delete 2>/dev/null || true

	# esbuild darwin/win32 binaries (build-time only, not needed at runtime)
	rm -rf "$dir/node_modules/@esbuild/darwin-"* 2>/dev/null || true
	rm -rf "$dir/node_modules/@esbuild/win32-"* 2>/dev/null || true

	# @sentry/cli platform binaries (optional; the JS SDK works without them)
	rm -rf "$dir/node_modules/@sentry/cli-darwin" \
	       "$dir/node_modules/@sentry/cli-win32"* 2>/dev/null || true

	# Sparkle (macOS auto-updater) + node-mac-permissions if present
	rm -rf "$dir/node_modules/sparkle-darwin" \
	       "$dir/node_modules/node-mac-permissions" 2>/dev/null || true
	find "$dir" -name "sparkle.node" -delete 2>/dev/null || true

	# ── (2) gateway tree (outside the asar, processed in place) ─────────────
	# The gateway node_modules lives at Contents/Resources/resources/gateway/.
	# It was populated with linux siblings by install_linux_prebuilds; now drop
	# the darwin leftovers so the loader picks the linux ones.
	local gw_nm="${APP_BUNDLE_DIR:-}/Contents/Resources/resources/gateway/node_modules"
	if [ -d "$gw_nm" ]; then
		info "stripping darwin natives from gateway tree..."
		# darwin sibling packages (now superseded by their linux counterparts)
		rm -rf "$gw_nm/@mariozechner/clipboard-darwin-"* 2>/dev/null || true
		rm -rf "$gw_nm/@snazzah/davey-darwin-"* 2>/dev/null || true
		rm -rf "$gw_nm/@napi-rs/canvas-darwin-"* 2>/dev/null || true
		rm -rf "$gw_nm/@lydell/node-pty-darwin-"* 2>/dev/null || true
		rm -rf "$gw_nm/@img/sharp-darwin-"* 2>/dev/null || true
		rm -rf "$gw_nm/sharp-darwin-"* 2>/dev/null || true
		# sqlite-vec darwin sibling (superseded by sqlite-vec-linux-<arch>)
		rm -rf "$gw_nm/sqlite-vec-darwin-"* 2>/dev/null || true
		# node-pty spawn-helper is a conpty fallback helper (win/mac only);
		# Linux uses pty.node's forkpty() directly, so drop any stray helper.
		find "$gw_nm/@lydell/node-pty-"* -name "spawn-helper" -delete 2>/dev/null || true
		# koffi: keep only the linux_<arch> build dir, drop the others
		if [ -d "$gw_nm/koffi/build/koffi" ]; then
			find "$gw_nm/koffi/build/koffi" -maxdepth 1 -type d \
				! -name "koffi" \
				! -name "linux_$(detect_arch)" \
				-exec rm -rf {} + 2>/dev/null || true
		fi
		# win32 siblings if present
		rm -rf "$gw_nm/@mariozechner/clipboard-win32-"* 2>/dev/null || true
		rm -rf "$gw_nm/@snazzah/davey-win32-"* 2>/dev/null || true
		rm -rf "$gw_nm/@napi-rs/canvas-win32-"* 2>/dev/null || true
		rm -rf "$gw_nm/@img/sharp-win32-"* 2>/dev/null || true
		# fsevents in gateway if present
		rm -rf "$gw_nm/fsevents" 2>/dev/null || true
		find "$gw_nm" -path "*/fsevents/*.node" -delete 2>/dev/null || true
	fi

	# Legacy node-pty cleanup (defensive; not in Kimi's main tree).
	rm -rf "$dir/node_modules/node-pty/prebuilds/darwin-"* \
	       "$dir/node_modules/node-pty/prebuilds/win32-"* \
	       "$dir/node_modules/node-pty/bin" \
	       "$dir/node_modules/node-pty/build" 2>/dev/null || true
	rm -rf "$dir/node_modules/@lydell/node-pty-darwin-"* 2>/dev/null || true
}

# Deterministic repack: stable file order (LC_ALL=C sort) with native
# binaries unpacked beside the asar (Electron cannot require() from inside).
asar_pack() {
	local src="${1:-$ASAR_EXTRACTED_DIR}"
	local out="${2:-$SCRIPT_DIR/app.asar}"
	[ -d "$src" ] || die "no extracted dir to pack"

	info "repacking app.asar (deterministic order, natives unpacked)..."
	local ordering="$SCRIPT_DIR/app.asar.ordering"
	( cd "$src" && find . -type f | LC_ALL=C sort | sed 's#^\./##' ) > "$ordering"

	# Clear any stale asar + unpacked tree so only current contents remain.
	rm -rf "$out" "$out.unpacked"
	npx --yes asar pack "$src" "$out" \
		--ordering "$ordering" \
		--unpack "{*.node,*.so,*.dylib}" >/dev/null
	rm -f "$ordering"

	REPACKED_ASAR="$out"
	info "repacked: $out ($(du -h "$out" | cut -f1))"
	export REPACKED_ASAR
}
