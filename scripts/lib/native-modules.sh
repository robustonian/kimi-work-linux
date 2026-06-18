#!/usr/bin/env bash
# native-modules.sh — resolve Linux native modules via prebuild swap (no rebuild).
# Sourced by install.sh (do not execute directly).
#
# Kimi Work has TWO node_modules trees with darwin native binaries:
#
#  (1) the main app.asar tree — extracted to $ASAR_EXTRACTED_DIR by asar_extract:
#        @minify-html/node-darwin-arm64  → @minify-html/node-linux-<arch>
#        @napi-rs/canvas-darwin-arm64    → @napi-rs/canvas-linux-<arch>-<libc>
#        fsevents                        → (deleted; chokidar falls back)
#      These are repacked into app.asar; .node binaries go to app.asar.unpacked.
#
#  (2) the gateway tree — a standalone node_modules shipped OUTSIDE the asar at
#      Contents/Resources/resources/gateway/node_modules (openclaw + clawhub, the
#      agent execution environment). Its darwin natives:
#        @mariozechner/clipboard-darwin-arm64 → @mariozechner/clipboard-linux-<arch>-<libc>
#        @snazzah/davey-darwin-arm64          → @snazzah/davey-linux-<arch>-<libc>
#        @napi-rs/canvas-darwin-arm64         → @napi-rs/canvas-linux-<arch>-<libc>
#        @lydell/node-pty-darwin-arm64        → @lydell/node-pty-linux-<arch>
#        @img/sharp-darwin-arm64              → @img/sharp-linux-<arch>
#        koffi (ships only darwin_arm64 build → fetch full koffi pkg for linux_x64)
#      The gateway tree is processed in place (not in the asar) and copied by
#      assemble_app alongside app.asar.
#
# All target packages are N-API based → ABI-agnostic, so their prebuilt .node
# runs under Electron/Node without @electron/rebuild. They are distributed as
# optionalDependencies sibling packages; on macOS only the darwin sibling is
# installed. We fetch the matching linux sibling from npm and drop it in.

NATIVE_BUILD_DIR="${KIMI_NATIVE_BUILD_DIR:-$SCRIPT_DIR/.cache/native-build}"

# Map our arch to the npm suffix conventions. @minify-html/node and
# @lydell/node-pty use <plat>-<arch>; @napi-rs/canvas / @snazzah/davey /
# @mariozechner/clipboard use <plat>-<arch>-<libc>.
_npm_arch_suffix() {
	case "${1:-$(detect_arch)}" in
		x64)   echo "x64" ;;
		arm64) echo "arm64" ;;
		*) die "no npm prebuild arch for $(detect_arch)" ;;
	esac
}

# Detect libc flavor (gnu for most distros, musl for Alpine).
_npm_libc() {
	if [ -f /etc/alpine-release ] 2>/dev/null; then echo "musl"; else echo "gnu"; fi
}

# Fetch a single npm package into the staging dir. Prints installed path.
# Usage: _npm_fetch <pkg-spec>
_npm_fetch() {
	local spec="$1"
	rm -rf "$NATIVE_BUILD_DIR"
	mkdir -p "$NATIVE_BUILD_DIR"
	( cd "$NATIVE_BUILD_DIR" \
		&& npm init -y >/dev/null 2>&1 \
		&& npm install "$spec" --no-save --ignore-scripts --foreground-scripts >/dev/null 2>&1 ) \
		|| die "npm install $spec failed"
	local pkg="${spec%%@*}"  # strip @version if present (keep @scope/name)
	[ -d "$NATIVE_BUILD_DIR/node_modules/$pkg" ] \
		|| die "$pkg did not install"
	echo "$NATIVE_BUILD_DIR/node_modules/$pkg"
}

# Assert a file is a Linux ELF (catches stray darwin/win binaries early).
_verify_elf() {
	local f="$1" label="$2"
	local ftype; ftype="$(file "$f")"
	case "$ftype" in
		*ELF*) info "  prebuild is ELF ✓ ($label)" ;;
		*) die "prebuild is NOT ELF ($label): $ftype" ;;
	esac
}

# Drop an npm-fetched sibling package into a target node_modules dir.
# Usage: _place_sibling <dest-node_modules> <pkg-name> <spec>
_place_sibling() {
	local dest_nm="$1" pkg="$2" spec="$3"
	info "fetching $spec..."
	local staged; staged="$(_npm_fetch "$spec")"
	local node_file; node_file="$(find "$staged" -name '*.node' | head -n1)"
	[ -n "$node_file" ] || die "no .node in $spec"
	_verify_elf "$node_file" "$spec"
	rm -rf "$dest_nm/$pkg" && mkdir -p "$dest_nm/$pkg"
	cp -a "$staged/." "$dest_nm/$pkg/"
	info "  placed $pkg ✓"
}

# Swap darwin native prebuilds for Linux equivalents in BOTH node_modules trees.
install_linux_prebuilds() {
	local main_nm="${1:-$ASAR_EXTRACTED_DIR}/node_modules"
	local arch; arch="${2:-$(detect_arch)}"
	local arch_s; arch_s="$(_npm_arch_suffix "$arch")"
	local libc; libc="$(_npm_libc)"

	info "installing Linux native prebuilds (arch=$arch_s, libc=$libc)..."

	# ── (1) main app.asar tree ──────────────────────────────────────────────
	if [ -d "$main_nm/@minify-html/node" ]; then
		_place_sibling "$main_nm" "@minify-html/node-linux-${arch_s}" \
			"@minify-html/node-linux-${arch_s}"
	else
		warn "@minify-html/node not in asar; skipping"
	fi

	if [ -d "$main_nm/@napi-rs/canvas" ]; then
		_place_sibling "$main_nm" "@napi-rs/canvas-linux-${arch_s}-${libc}" \
			"@napi-rs/canvas-linux-${arch_s}-${libc}"
	else
		warn "@napi-rs/canvas not in asar; skipping"
	fi

	# ── (2) gateway tree (Contents/Resources/resources/gateway/node_modules) ─
	local gw_nm="${APP_BUNDLE_DIR:-}/Contents/Resources/resources/gateway/node_modules"
	if [ -d "$gw_nm" ]; then
		info "processing gateway node_modules tree: $gw_nm"

		if [ -d "$gw_nm/@mariozechner/clipboard" ]; then
			_place_sibling "$gw_nm" "@mariozechner/clipboard-linux-${arch_s}-${libc}" \
				"@mariozechner/clipboard-linux-${arch_s}-${libc}"
		fi
		if [ -d "$gw_nm/@snazzah/davey" ]; then
			_place_sibling "$gw_nm" "@snazzah/davey-linux-${arch_s}-${libc}" \
				"@snazzah/davey-linux-${arch_s}-${libc}"
		fi
		if [ -d "$gw_nm/@napi-rs/canvas" ]; then
			_place_sibling "$gw_nm" "@napi-rs/canvas-linux-${arch_s}-${libc}" \
				"@napi-rs/canvas-linux-${arch_s}-${libc}"
		fi
		if [ -d "$gw_nm/@lydell/node-pty" ] || [ -d "$gw_nm/node-pty" ]; then
			_place_sibling "$gw_nm" "@lydell/node-pty-linux-${arch_s}" \
				"@lydell/node-pty-linux-${arch_s}"
		fi
		if [ -d "$gw_nm/@img/sharp" ] || [ -d "$gw_nm/sharp" ]; then
			_place_sibling "$gw_nm" "@img/sharp-linux-${arch_s}" \
				"@img/sharp-linux-${arch_s}"
		fi
		# sqlite-vec: vector-search SQLite extension used by the agent memory.
		if [ -d "$gw_nm/sqlite-vec" ]; then
			_place_sibling "$gw_nm" "sqlite-vec-linux-${arch_s}" \
				"sqlite-vec-linux-${arch_s}"
		fi
		# koffi: the darwin build ships only darwin_arm64/koffi.node under
		# build/koffi/. The npm package bundles EVERY platform, so re-fetch the
		# whole koffi package and merge build/koffi/linux_<arch>/ into it.
		if [ -d "$gw_nm/koffi" ]; then
			info "fetching koffi (multi-platform, for linux_${arch_s}/koffi.node)..."
			local koffi_ver; koffi_ver="$(python3 -c "import json;print(json.load(open('$gw_nm/koffi/package.json'))['version'])" 2>/dev/null || echo 2.16.2)"
			local staged; staged="$(_npm_fetch "koffi@${koffi_ver}")"
			local linux_node="$staged/build/koffi/linux_${arch_s}/koffi.node"
			if [ -f "$linux_node" ]; then
				_verify_elf "$linux_node" "koffi linux_${arch_s}"
				mkdir -p "$gw_nm/koffi/build/koffi/linux_${arch_s}"
				cp "$linux_node" "$gw_nm/koffi/build/koffi/linux_${arch_s}/koffi.node"
				info "  placed koffi build/koffi/linux_${arch_s}/koffi.node ✓"
			else
				warn "koffi linux_${arch_s} build not found in npm package; FFI features may fail"
			fi
		fi
		else
			warn "gateway node_modules not found; agent features will be unavailable"
		fi

	# ── (3) daimon-bundle tree ──────────────────────────────────────────────
	# @kimi/daimon is the CLI/agent bundle at Contents/Resources/resources/
	# daimon-bundle/app/daimon/. Its only native dep is better-sqlite3, which
	# resolves its binary via prebuild-install (a postinstall script), NOT an
	# optionalDependencies sibling — so _place_sibling does not apply. We
	# install better-sqlite3 fresh (letting prebuild-install fetch the linux
	# prebuild) and copy build/Release/better_sqlite3.node into place.
	local daimon_nm="${APP_BUNDLE_DIR:-}/Contents/Resources/resources/daimon-bundle/app/daimon/node_modules"
	if [ -d "$daimon_nm/better-sqlite3" ]; then
		local bsq_ver
		bsq_ver="$(python3 -c "import json;print(json.load(open('$daimon_nm/better-sqlite3/package.json'))['version'])" 2>/dev/null || echo 12.11.1)"
		info "fetching better-sqlite3@${bsq_ver} (daimon) — prebuild-install runs..."
		rm -rf "$NATIVE_BUILD_DIR"
		mkdir -p "$NATIVE_BUILD_DIR"
		# scripts MUST run here so prebuild-install fetches the linux binary.
		( cd "$NATIVE_BUILD_DIR" \
			&& npm init -y >/dev/null 2>&1 \
			&& npm install "better-sqlite3@${bsq_ver}" --no-save --foreground-scripts >/dev/null 2>&1 ) \
			|| warn "better-sqlite3 install failed; daimon db features may fail"
		local bsq_node="$NATIVE_BUILD_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
		if [ -f "$bsq_node" ]; then
			_verify_elf "$bsq_node" "better-sqlite3 (daimon)"
			mkdir -p "$daimon_nm/better-sqlite3/build/Release"
			cp "$bsq_node" "$daimon_nm/better-sqlite3/build/Release/better_sqlite3.node"
			info "  placed daimon better-sqlite3 build/Release/better_sqlite3.node ✓"
		else
			warn "better-sqlite3 linux prebuild not produced; daimon db features may fail"
		fi
	fi
}
