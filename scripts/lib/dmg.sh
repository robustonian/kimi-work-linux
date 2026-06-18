#!/usr/bin/env bash
# dmg.sh — upstream Kimi Work DMG resolution, cached download, and extraction.
# Sourced by install.sh (do not execute directly).
#
# Moonshot exposes a stable redirect endpoint that points at the latest DMG:
#   GET https://appsupport.moonshot.cn/api/app/pkg/latest/macos/download
#     → 302 Location: https://kimi-img.moonshot.cn/app/download/mac/kimi_<ver>.dmg
# We GET-without-follow to read the Location header: that both gives us the
# concrete DMG URL and the version (parsed from the filename). The endpoint
# rejects HEAD (400), so we use GET -o /dev/null and capture headers only.

CACHE_DIR="${KIMI_CACHE_DIR:-$SCRIPT_DIR/.cache}"
CACHED_DMG_PATH="$SCRIPT_DIR/Kimi.dmg"
CACHED_DMG_META="$SCRIPT_DIR/Kimi.dmg.metadata"

# Follow the redirect endpoint (no body) and print the concrete DMG URL.
# Honors KIMI_UPSTREAM_DMG_URL (skip the redirect) and KIMI_VERSION (pin).
_resolve_redirect() {
	local redirect_url="${KIMI_UPSTREAM_DOWNLOAD_URL:-https://appsupport.moonshot.cn/api/app/pkg/latest/macos/download}"
	local headers
	# GET (not HEAD: the endpoint 400s on HEAD), discard body, capture headers,
	# do NOT follow — we want the Location header, not the 765MB DMG body.
	headers="$(curl -fsS --max-time 20 --connect-timeout 8 \
		-o /dev/null -D - -- "$redirect_url" 2>/dev/null || true)"
	awk -F': ' 'tolower($1)=="location"{gsub(/\r/,"",$2);print $2;exit}' <<<"$headers"
}

# Extract the version from a kimi_<ver>.dmg URL (or bare filename).
_version_from_url() {
	local url="$1"
	local fn; fn="$(basename "$url")"
	# kimi_3.0.22.dmg  →  3.0.22
	sed -nE 's/^[Kk]imi[_-]([0-9][0-9.a-zA-Z_-]*)\.(dmg|exe|zip|pkg)$/\1/p' <<<"$fn"
}

# Build / resolve the concrete DMG URL. Honors KIMI_VERSION (pin) and
# KIMI_UPSTREAM_DMG_URL (bypass redirect). Sets RESOLVED_DMG_URL + KIMI_VERSION.
resolve_dmg_url() {
	if [ -n "${ZRESOLVED_DMG_URL:-}" ]; then
		echo "$ZRESOLVED_DMG_URL"
		return
	fi

	# Explicit override wins entirely.
	if [ -n "${KIMI_UPSTREAM_DMG_URL:-}" ]; then
		RESOLVED_DMG_URL="$KIMI_UPSTREAM_DMG_URL"
		[ -z "${KIMI_VERSION:-}" ] && KIMI_VERSION="$(_version_from_url "$RESOLVED_DMG_URL")"
		echo "$RESOLVED_DMG_URL"
		return
	fi

	# Pinned version → construct the CDN URL directly.
	if [ -n "${KIMI_VERSION:-}" ]; then
		RESOLVED_DMG_URL="${KIMI_UPSTREAM_DMG_BASE}/kimi_${KIMI_VERSION}.dmg"
		echo "$RESOLVED_DMG_URL"
		return
	fi

	# Auto: follow the redirect, read Location, parse version from filename.
	local loc; loc="$(_resolve_redirect)"
	[ -n "$loc" ] || die "could not resolve latest DMG from redirect endpoint: ${KIMI_UPSTREAM_DOWNLOAD_URL}"
	RESOLVED_DMG_URL="$loc"
	KIMI_VERSION="$(_version_from_url "$loc")"
	[ -n "$KIMI_VERSION" ] || die "could not parse version from DMG URL: $loc"
	echo "$RESOLVED_DMG_URL"
}

# Remote HTTP fingerprint of the concrete DMG via HEAD (etag / last-modified /
# content-length). The CDN (kimi-img.moonshot.cn / ByteDance TOS) supports HEAD
# with Accept-Ranges, so HEAD works here (unlike the appsupport redirect).
_fetch_remote_fingerprint() {
	local url="$1"
	local headers
	headers="$(curl -fsSIL --max-time 15 --connect-timeout 5 -- "$url" 2>/dev/null || true)"
	local etag lm cl
	etag="$(printf '%s\n' "$headers" | awk -F': ' 'tolower($1)=="etag"{gsub(/\r/,"",$2);print $2;exit}')"
	lm="$(printf '%s\n'   "$headers" | awk -F': ' 'tolower($1)=="last-modified"{gsub(/\r/,"",$2);print $2;exit}')"
	cl="$(printf '%s\n'   "$headers" | awk -F': ' 'tolower($1)=="content-length"{gsub(/\r/,"",$2);print $2;exit}')"
	echo "url=$url"
	echo "etag=${etag:-}"
	echo "last_modified=${lm:-}"
	echo "content_length=${cl:-}"
}

# Ensure the DMG is available locally (download if needed). Sets RESOLVED_DMG_PATH.
get_dmg() {
	# Explicit local path wins.
	if [ -n "$PROVIDED_DMG_PATH" ]; then
		[ -f "$PROVIDED_DMG_PATH" ] || die "provided DMG not found: $PROVIDED_DMG_PATH"
		RESOLVED_DMG_PATH="$(cd "$(dirname "$PROVIDED_DMG_PATH")" && pwd)/$(basename "$PROVIDED_DMG_PATH")"
		info "using provided DMG: $RESOLVED_DMG_PATH"
		return
	fi

	local url; url="$(resolve_dmg_url)"
	info "Kimi Work ${KIMI_VERSION:-<unknown>} → $url"

	if [ "$FRESH" = 1 ] && [ -f "$CACHED_DMG_PATH" ]; then
		info "discarding cached DMG (--fresh)"
		rm -f "$CACHED_DMG_PATH" "$CACHED_DMG_META"
	fi

	# Cache hit via fingerprint comparison.
	if [ -f "$CACHED_DMG_PATH" ] && [ -f "$CACHED_DMG_META" ]; then
		local remote
		if remote="$(_fetch_remote_fingerprint "$url")"; then
			local r_etag r_cl c_etag c_cl
			r_etag="$(printf '%s\n' "$remote" | sed -n 's/^etag=//p')"
			r_cl="$(printf '%s\n'   "$remote" | sed -n 's/^content_length=//p')"
			c_etag="$(sed -n 's/^etag=//p' "$CACHED_DMG_META" 2>/dev/null || true)"
			c_cl="$(sed -n 's/^content_length=//p' "$CACHED_DMG_META" 2>/dev/null || true)"
			if { [ -n "$r_etag" ] && [ "$r_etag" = "$c_etag" ]; } || \
			   { [ -n "$r_cl" ]   && [ "$r_cl"   = "$c_cl"   ]; }; then
				info "cached DMG is current (fingerprint match); skipping download"
				RESOLVED_DMG_PATH="$CACHED_DMG_PATH"
				return
			fi
		fi
	fi

	info "downloading DMG ($(numfmt --to=iec 765259217 2>/dev/null || echo ~730M) +)..."
	mkdir -p "$CACHE_DIR"
	local tmp_dmg="$CACHED_DMG_PATH.part"
	rm -f "$tmp_dmg"
	# Resume (-C -) so a flaky 765M download can continue across retries.
	curl -fL --retry 5 --retry-delay 3 -C - -o "$tmp_dmg" -- "$url"
	mv "$tmp_dmg" "$CACHED_DMG_PATH"

	local remote_meta
	remote_meta="$(_fetch_remote_fingerprint "$url" || true)"
	printf '%s\n' "$remote_meta" > "$CACHED_DMG_META"

	RESOLVED_DMG_PATH="$CACHED_DMG_PATH"
	info "DMG cached: $CACHED_DMG_PATH ($(du -h "$CACHED_DMG_PATH" | cut -f1))"
}

# Extract the .app bundle from a DMG. Sets APP_BUNDLE_DIR.
extract_dmg() {
	local dmg="${1:-${RESOLVED_DMG_PATH:-}}"
	[ -n "$dmg" ] && [ -f "$dmg" ] || die "no DMG to extract"
	[ -n "${SEVEN_ZIP_CMD:-}" ] || check_deps

	local extract_dir="$SCRIPT_DIR/dmg-extract"
	rm -rf "$extract_dir"
	mkdir -p "$extract_dir"

	info "extracting DMG with $SEVEN_ZIP_CMD..."
	# 7zz returns exit 2 when it skips "dangerous" symlink targets (absolute
	# or ../ escaping the extract root). Kimi Work's gateway node_modules/.bin/
	# has many such symlinks; they are dev-tool shims not needed at runtime,
	# so we tolerate exit code 2 as long as the .app bundle is present.
	local rc=0
	"$SEVEN_ZIP_CMD" x -y -snl "$dmg" -o"$extract_dir" >/dev/null 2>&1 || rc=$?
	if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
		die "7zz extraction failed (exit $rc)"
	fi

	APP_BUNDLE_DIR="$(find "$extract_dir" -maxdepth 4 -name "*.app" -type d 2>/dev/null | head -n1)"
	[ -n "$APP_BUNDLE_DIR" ] || die "no .app bundle found in DMG (extract dir: $extract_dir; 7zz exit $rc)"
	info "app bundle: $APP_BUNDLE_DIR"
	export APP_BUNDLE_DIR
}
