#!/usr/bin/env bash
# install-deps.sh — bootstrap system build deps + a modern 7zz on Linux.
set -euo pipefail

info()  { printf '\033[1;34m[install-deps]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[install-deps]\033[0m %s\n' "$*"; }

detect_pm() {
	if   command -v apt-get >/dev/null 2>&1; then echo apt
	elif command -v dnf     >/dev/null 2>&1; then echo dnf
	elif command -v pacman  >/dev/null 2>&1; then echo pacman
	elif command -v zypper  >/dev/null 2>&1; then echo zypper
	else echo unknown; fi
}

ensure_7zz() {
	if command -v 7zz >/dev/null 2>&1; then
		info "7zz already available: $(command -v 7zz)"
		return 0
	fi
	if command -v 7z >/dev/null 2>&1; then
		local banner; banner="$(7z 2>&1 | head -n3 || true)"
		if ! printf '%s' "$banner" | grep -qiE 'p7zip Version|16\.02'; then
			info "system 7z looks modern enough; skipping 7zz bootstrap"
			return 0
		fi
	fi

	local arch; arch="$(uname -m)"
	case "$arch" in
		x86_64|amd64)  arch="x64" ;;
		aarch64|arm64) arch="arm64" ;;
		*) warn "cannot bootstrap 7zz for arch $arch"; return 0 ;;
	esac

	local bin_dir="$HOME/.local/bin"
	mkdir -p "$bin_dir"
	local ver="2409"
	local url="https://www.7-zip.org/a/7z${ver}-linux-${arch}.tar.xz"
	local tmp; tmp="$(mktemp -d)"
	info "bootstrapping 7zz ${ver} from $url"
	if curl -fsSL "$url" -o "$tmp/7zz.tar.xz"; then
		tar -xJf "$tmp/7zz.tar.xz" -C "$tmp"
		install -m 0755 "$tmp/7zz" "$bin_dir/7zz" 2>/dev/null || cp "$tmp/7zz" "$bin_dir/7zz"
		chmod +x "$bin_dir/7zz"
		info "installed 7zz → $bin_dir/7zz (ensure $bin_dir is on your PATH)"
	else
		warn "failed to download 7zz. Install manually from https://www.7-zip.org/download.html"
	fi
	rm -rf "$tmp"
}

ensure_en_us_locale() {
	if ! command -v locale-gen >/dev/null 2>&1; then return 0; fi
	if locale -a 2>/dev/null | grep -qixFe 'en_US.UTF-8'; then
		info "en_US.UTF-8 locale already available"
		return 0
	fi
	info "generating en_US.UTF-8 locale..."
	if [ -f /etc/locale.gen ]; then
		sudo sed -i 's/^# *\(en_US\.UTF-8.*\)/\1/' /etc/locale.gen
	fi
	sudo locale-gen en_US.UTF-8 >/dev/null 2>&1 \
		|| warn "locale-gen failed; the app will fall back to the system locale"
}

main() {
	local pm; pm="$(detect_pm)"
	info "package manager: $pm"

	local pkgs=(curl python3 unzip)
	case "$pm" in
		apt)
			# On Ubuntu 24.04+ several libs were renamed to a *t64 variant
			# (libasound2 → libasound2t64, libatk1.0-0 → libatk1.0-0t64, …)
			# and the old name is no longer installable. Pass both names as an
			# apt alternative ("pkg|pkg") so apt picks whichever is available —
			# the same idiom used in our .deb control file's Depends line.
			pkgs+=(build-essential pkg-config dpkg-dev python3-pil fonts-dejavu-core \
			       libnss3 libnspr4 \
			       "libatk1.0-0|libatk1.0-0t64" \
			       "libatk-bridge2.0-0|libatk-bridge2.0-0t64" \
			       "libcups2|libcups2t64" \
			       libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
			       libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
			       "libasound2|libasound2t64" \
			       "libatspi2.0-0|libatspi2.0-0t64")
			sudo apt-get update -y
			sudo apt-get install -y "${pkgs[@]}"
			;;
		dnf)
			pkgs+=(gcc-c++ make rpm-build python3-pillow dejavu-sans-fonts)
			sudo dnf install -y "${pkgs[@]}"
			;;
		pacman)
			pkgs+=(base-devel python-pillow ttf-dejavu)
			sudo pacman -Sy --noconfirm "${pkgs[@]}"
			;;
		zypper)
			pkgs+=(gcc-c++ make python3-Pillow dejavu-fonts)
			sudo zypper install -y "${pkgs[@]}"
			;;
		*)
			warn "unknown package manager. Install manually: curl python3 unzip python3-pil fonts-dejavu-core + Electron shared libs"
			;;
	esac

	ensure_7zz
	ensure_en_us_locale
}

main "$@"
