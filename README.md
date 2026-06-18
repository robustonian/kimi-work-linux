# kimi-work-linux

Run **Kimi Work / Kimi Desktop** (Moonshot AI's desktop AI agent) on Linux by
converting the upstream macOS build into a runnable Linux Electron app —
**automated, in one shell command.**

Moonshot AI ships official Kimi Work installers for macOS and Windows only.
This project fills in Linux by converting the upstream macOS `kimi_<ver>.dmg`
into a runnable Linux Electron app and packaging it as a `.deb` / `AppImage`.

> **Status:** the conversion pipeline, `.deb`/`AppImage` packaging, and a
> one-command installer are implemented and **verified end-to-end against the
> real Kimi Work 3.0.22 DMG** (0 Mach-O binaries remain; every native
> component is replaced with a Linux ELF). See [Verified below](#verified).
> A display was not available in the build environment, so final GUI launch
> testing is left to the user.

## ⚠️ Disclaimer

This is an **unofficial community project**. Kimi Work / Kimi Desktop is a
product of **Moonshot AI (月之暗面)**. This tool:

- **Does not redistribute any Moonshot AI software.** No upstream binaries are
  stored in this repository.
- Automates the conversion process that users perform on their own copy of the
  upstream DMG, which is fetched from Moonshot's CDN at build time.
- Is not affiliated with, endorsed by, or sponsored by Moonshot AI.

Use of the converted app is subject to Moonshot AI's own terms of service.
Ensure you have the right to run Kimi on your platform before using this tool.

## How it works

Kimi Work is an Electron app, but it is more complex than a typical one: it
bundles an agent runtime (`@kimi/daimon`), a gateway (`openclaw`/`clawhub`),
and standalone Python/Node/uv runtimes alongside the main `app.asar`. The
conversion handles all of them:

1. **Resolve** the latest version by following Moonshot's redirect endpoint
   (`appsupport.moonshot.cn/api/app/pkg/latest/macos/download` → `kimi_<ver>.dmg`).
2. **Fetch** the upstream macOS DMG (cached by HTTP fingerprint, resumable).
3. **Extract** the `.app` bundle with `7zz` (modern 7-Zip; old `p7zip` cannot
   open current APFS DMGs).
4. **Inspect** `app.asar` to discover native modules, the Electron version,
   integrity checks, and the bundle layout → `inspect-report.json`.
5. **Swap** every darwin native for its Linux equivalent across **four**
   component trees (see table below), all N-API / prebuild-based → no rebuild.
6. **Replace** the darwin-bundled Python, uv, and Node runtimes with their
   Linux builds (same upstream release tags).
7. **Strip** macOS-only leftovers (`fsevents`, `@esbuild/darwin-*`, symlinks,
   the conpty `spawn-helper`, …).
8. **Repack** `app.asar` deterministically, with native binaries unpacked
   beside the asar (Electron cannot `require()` from inside).
9. **Download** the matching Linux Electron runtime.
10. **Assemble** `kimi-app/` (Electron + repacked asar + launcher + icon) and
    generate `start.sh`.
11. **Package** as `.deb` / `AppImage`.

### Verified

End-to-end run against **Kimi Work 3.0.22** (macOS arm64 DMG → Linux x64):

| Check | Result |
| --- | --- |
| DMG download | ✅ 730 MB, resumable |
| Pipeline stages | ✅ all pass |
| **Mach-O binaries remaining** | **✅ 0** |
| Native binaries (Linux ELF) | ✅ 22 — all ELF-verified |
| `.deb` build | ✅ `kimi-work_3.0.22-klinux1_amd64.deb` (596 MB) |

The four component trees and their darwin → Linux swaps:

| Tree | Native module | Linux package |
| --- | --- | --- |
| **main `app.asar`** | `@minify-html/node-darwin-arm64` | `@minify-html/node-linux-x64` |
| | `@napi-rs/canvas-darwin-arm64` | `@napi-rs/canvas-linux-x64-gnu` |
| | `fsevents` | *(deleted; chokidar falls back)* |
| **gateway** (`openclaw`) | `@mariozechner/clipboard-darwin-arm64` | `…-clipboard-linux-x64-gnu` |
| | `@snazzah/davey-darwin-arm64` | `…-davey-linux-x64-gnu` |
| | `@napi-rs/canvas-darwin-arm64` | `…-canvas-linux-x64-gnu` |
| | `@lydell/node-pty-darwin-arm64` | `…-node-pty-linux-x64` |
| | `@img/sharp-darwin-arm64` + `sharp-libvips-darwin-arm64` | `…-sharp-linux-x64` + `…-sharp-libvips-linux-x64` |
| | `sqlite-vec-darwin-arm64` | `sqlite-vec-linux-x64` |
| | `koffi` (darwin-only build dir) | full `koffi` pkg → `build/koffi/linux_x64/` |
| **daimon-bundle** (`@kimi/daimon`) | `better-sqlite3` (prebuild-install) | fresh install → `build/Release/better_sqlite3.node` |
| **bundled runtimes** | Python 3.12 (cpython, darwin) | python-build-standalone, same release tag (linux) |
| | uv (darwin) | astral-sh/uv (linux) |
| | Node v24.15.0 (darwin) | nodejs.org (linux) |
| | `kimi-webbridge` (darwin Mach-O) | no-op stub (no linux build; disabled upstream) |

## Prerequisites

- Linux x86_64 (Ubuntu/Debian tested first; other distros later). arm64 should
  work via the same pipeline (linux arm64 prebuilds all exist).
- `curl`, `python3`, `unzip`, `make`
- Modern **7-Zip** (`7zz` ≥ 23.x). The ancient `p7zip` 16.02 cannot extract
  current DMGs — `make install-deps` bootstraps a modern `7zz` if needed.
- `dpkg-deb` (for `.deb`), `appimagetool` (for AppImage)
- A C++ toolchain (`build-essential`) — only needed if a native rebuild is
  required (the default path uses prebuilds, no rebuild).
- Node.js / npm — used at build time for `asar` / `prebuild-install`. The
  built app bundles its own Electron + Node runtime; you do **not** need a
  distro `nodejs` to run it.
- `python3-pil` (Pillow) — to convert the shipped `icon.icns` → PNG.

## Quick start

Clone, then run `make bootstrap` — it installs or updates to the latest
upstream version:

```bash
git clone https://github.com/<you>/kimi-work-linux.git
cd kimi-work-linux
make bootstrap            # deps → fetch latest DMG → build → package → install
```

`make bootstrap` (a.k.a. `scripts/install-latest.sh`) detects the latest
upstream version, skips the rebuild if you are already up to date, and
installs the `.deb` (it will prompt for sudo). Pass `--force` to rebuild
regardless: `make bootstrap -- --force`.

Step by step:

```bash
make install-deps         # bootstrap 7zz + system build deps
make inspect              # analyze the upstream DMG → inspect-report.json
make build-app            # build ./kimi-app/
./kimi-app/start.sh       # run it
make deb                  # build a .deb into dist/
make appimage             # build an AppImage into dist/
```

## Configuration (environment variables)

| Variable | Default | Purpose |
| --- | --- | --- |
| `KIMI_UPSTREAM_DOWNLOAD_URL` | `https://appsupport.moonshot.cn/api/app/pkg/latest/macos/download` | The redirect endpoint that resolves to the latest macOS DMG |
| `KIMI_UPSTREAM_DMG_URL` | resolved from the redirect | Override the DMG URL entirely |
| `KIMI_VERSION` | auto-detected from the redirect's `Location` | Pin an upstream version (e.g. `3.0.22`) |
| `KIMI_INSTALL_DIR` | `./kimi-app` | Where the runnable app is generated |
| `KIMI_ELECTRON_VERSION` | from `inspect-report.json` / Info.plist | Pin the Electron runtime version |
| `ELECTRON_MIRROR` | GitHub releases | Mirror root for the Linux Electron download |

## Project structure

```
install.sh               # conversion entry point (drives the pipeline)
Makefile                 # bootstrap / build-app / package / deb / appimage / inspect / run-app
scripts/
  install-deps.sh        # bootstrap 7zz + system build deps
  install-latest.sh      # one-command install / update (latest version detection)
  build-deb.sh           # .deb packaging
  build-appimage.sh      # AppImage packaging
  lib/                   # pipeline stages:
    install-helpers.sh     arch/distro detection, deps + modern 7zz check
    dmg.sh                 redirect-based version detection + fingerprint-cached download
    inspect.sh             asar analyzer → inspect-report.json
    asar.sh                extract / strip darwin artifacts / deterministic repack
    native-modules.sh      Linux prebuild swap across all node_modules trees
    electron.sh            resolve + cache + extract matching Linux Electron runtime
    runtimes.sh            replace darwin Python/uv/Node + neutralize webbridge
    assemble.sh            wire repacked asar + electron + launcher → kimi-app/
    package-common.sh      shared .deb/AppImage staging
    patches.sh             asar patch engine driver
  patches/                # asar patch engine (apply/engine/registry/shared) + core/
launcher/
  start.sh.template      # Linux launcher (Wayland/X11, --no-sandbox, fontconfig hint)
packaging/
  linux/                 # .deb control + desktop entry
  appimage/              # AppRun + runtime
```

## Known limitations

- **GUI launch untested here** — the build environment has no display; run
  `./kimi-app/start.sh` or `make run-app` to confirm.
- **`kimi-webbridge` (browser automation) is unavailable** — it is a
  darwin-only Mach-O with no known Linux build. It is replaced with a no-op
  stub. Upstream `bundle.json` defaults it to disabled, so most flows are
  unaffected.
- **Auto-updater is not patched** — Kimi runs `electron-updater` against
  `https://kimi-img.moonshot.cn/app/upgrade/`, which would push a macOS
  payload. Use `make bootstrap` to update instead of the in-app updater. A
  `disable-auto-update` patch descriptor is a known candidate (see
  `scripts/patches/core/README.md`).

## Acknowledgments

The architecture is directly inspired by — and borrows design patterns from:

- [`robustonian/zcode-linux`](https://github.com/robustonian/zcode-linux) — the
  same conversion approach for Z.ai's ZCode desktop app.
- [`ilysenko/codex-desktop-linux`](https://github.com/ilysenko/codex-desktop-linux)
  — the original approach for OpenAI Codex Desktop.

## License

MIT. See [LICENSE](LICENSE).
