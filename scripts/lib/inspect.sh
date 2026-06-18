#!/usr/bin/env bash
# inspect.sh — analyze the extracted app bundle's app.asar and write inspect-report.json.
# Sourced by install.sh (do not execute directly).

inspect_app() {
	local app="${1:-${APP_BUNDLE_DIR:-}}"
	[ -n "$app" ] && [ -d "$app" ] || die "no app bundle to inspect (run --extract-only first)"
	local resources="$app/Contents/Resources"
	local asar="$resources/app.asar"
	[ -f "$asar" ] || die "app.asar not found: $asar"

	local work="$SCRIPT_DIR/app-extracted"
	rm -rf "$work"
	mkdir -p "$work"

	info "extracting app.asar for inspection ($(du -h "$asar" | cut -f1))..."
	npx --yes asar extract "$asar" "$work" >/dev/null

	info "analyzing app bundle..."
	mkdir -p "$REPORT_DIR"
	python3 - "$work" "$app" "$REPORT_DIR" "$asar" <<'PY'
import json, os, sys, glob, re, struct
from collections import defaultdict

work, app, report_dir, asar_path = sys.argv[1:5]
resources = os.path.join(app, "Contents", "Resources")
report = {}

# --- 1. package.json ---
pkg = {}
pkg_path = os.path.join(work, "package.json")
if os.path.isfile(pkg_path):
    with open(pkg_path) as f:
        try:
            pkg = json.load(f)
        except Exception as e:
            pkg = {"_parse_error": str(e)}
deps = pkg.get("dependencies") or {}
devdeps = pkg.get("devDependencies") or {}
report["package_json"] = {
    "name": pkg.get("name"),
    "version": pkg.get("version"),
    "main": pkg.get("main"),
    "electron_version_hint": devdeps.get("electron") or deps.get("electron"),
    "dependencies": sorted(deps.keys()),
    "dependencies_count": len(deps),
}

# --- 2. Electron version from Info.plist ---
electron_version = None
plist_candidates = (
    glob.glob(os.path.join(app, "Contents", "Frameworks", "Electron Framework.framework", "Versions", "*", "Resources", "Info.plist"))
    + glob.glob(os.path.join(app, "Contents", "Frameworks", "Electron Framework.framework", "**", "Info.plist"), recursive=True)
)
for pp in plist_candidates:
    try:
        import plistlib
        with open(pp, "rb") as f:
            pl = plistlib.load(f)
        v = pl.get("CFBundleVersion") or pl.get("CFBundleShortVersionString")
        if v:
            electron_version = v
            break
    except Exception:
        pass
report["electron_version"] = electron_version

# --- 3. Native modules ---
def module_of(path):
    m = re.search(r"node_modules[/:](@[^/\\]+[/:][^/\\]+|[^/\\]+)", path)
    return m.group(1) if m else "unknown"

node_files = glob.glob(os.path.join(work, "**", "*.node"), recursive=True)
unpacked = os.path.join(resources, "app.asar.unpacked")
unpacked_node_files = glob.glob(os.path.join(unpacked, "**", "*.node"), recursive=True) if os.path.isdir(unpacked) else []
binding_gyps = glob.glob(os.path.join(work, "node_modules", "**", "binding.gyp"), recursive=True)

mod_nodes = defaultdict(list)
for n in node_files + unpacked_node_files:
    mod_nodes[module_of(n)].append(n)
mod_gyp = sorted({module_of(g) for g in binding_gyps})
report["native_modules"] = {
    "node_file_count": len(node_files) + len(unpacked_node_files),
    "by_module": {k: {"node_files": [os.path.relpath(x, work) for x in v]} for k, v in mod_nodes.items()},
    "binding_gyp_modules": mod_gyp,
}

# --- 4. asar integrity (header JSON "integrity" key) ---
integrity_info = {"enabled": False}
try:
    with open(asar_path, "rb") as f:
        f.read(4)                       # size slot = 4
        f.read(4)                       # headerSize
        f.read(4)                       # json+padding
        json_size = struct.unpack("<I", f.read(4))[0]
        header_json = f.read(json_size).decode("utf-8", errors="replace")
    hdr = json.loads(header_json)
    if "integrity" in hdr:
        integrity_info = {"enabled": True, "integrity": hdr["integrity"]}
except Exception as e:
    integrity_info = {"enabled": "unknown", "error": str(e)}
report["asar_integrity"] = integrity_info

# --- 5. Local native binaries (Mach-O / ELF) ---
def classify(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except Exception:
        return None
    if magic[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe"):
        return "mach-o"
    if magic[:4] == b"\x7fELF":
        return "elf"
    return None

macho, elf = [], []
scan_dirs = [work] + ([unpacked] if os.path.isdir(unpacked) else [])
seen = set()
for d in scan_dirs:
    for ext in ("*.node", "*.dylib", "*.so", "*.so.*"):
        for p in glob.glob(os.path.join(d, "**", ext), recursive=True):
            rp = os.path.relpath(p, d)
            if rp in seen:
                continue
            seen.add(rp)
            kind = classify(p)
            if kind == "mach-o":
                macho.append(rp)
            elif kind == "elf":
                elf.append(rp)
report["native_binaries"] = {
    "mach_o_count": len(macho),
    "elf_count": len(elf),
    "mach_o_samples": sorted(set(macho))[:25],
    "elf_samples": sorted(set(elf))[:25],
}

# --- 6. bundle layout ---
bundle = {}
for cand in (".vite/build", "out", "dist", "build"):
    d = os.path.join(work, cand)
    if os.path.isdir(d):
        mains = sorted(os.path.basename(x) for x in glob.glob(os.path.join(d, "main*.js")))
        if mains:
            bundle["main_bundle_dir"] = cand
            bundle["main_bundles"] = mains
            break
if not bundle and pkg.get("main"):
    bundle["main_entry"] = pkg.get("main")
report["bundle"] = bundle

# --- 7. icons ---
icons = [n for n in ("icon.png", "icon.icns", "icon_windows.png") if os.path.isfile(os.path.join(resources, n))]
report["icons"] = icons

# --- 8. extra resource dirs ---
report["resource_dirs"] = sorted(d for d in os.listdir(resources)
                                 if os.path.isdir(os.path.join(resources, d)) and not d.startswith("app.asar"))

# --- 9. known macOS-only npm packages present (strip candidates) ---
mac_only_packages = []
for cand in ("fsevents", "@rollup/rollup-darwin-arm64", "@rollup/rollup-darwin-x64",
             "node-mac-permissions", "sparkle-darwin"):
    if os.path.isdir(os.path.join(work, "node_modules", cand)):
        mac_only_packages.append(cand)
report["mac_only_packages"] = mac_only_packages

# --- feasibility notes ---
notes = []
nm = report["native_modules"]
if nm["node_file_count"] > 0:
    notes.append(f"{nm['node_file_count']} .node binaries found — rebuild/swap needed for: {sorted(nm['by_module'])}")
if macho:
    notes.append(f"{len(macho)} Mach-O binaries present — must replace with Linux ELF equivalents or rebuild")
if integrity_info.get("enabled") is True:
    notes.append("asar integrity IS enabled — repacking needs fuse disabling or hash recomputation")
if mac_only_packages:
    notes.append(f"macOS-only packages to strip: {mac_only_packages}")
if electron_version:
    notes.append(f"target Electron version for native rebuild: {electron_version}")
report["feasibility_notes"] = notes

out = os.path.join(report_dir, "inspect-report.json")
with open(out, "w") as f:
    json.dump(report, f, indent=2, ensure_ascii=False)
print(out)
PY

	info "inspect report written: $REPORT_DIR/inspect-report.json"
}
