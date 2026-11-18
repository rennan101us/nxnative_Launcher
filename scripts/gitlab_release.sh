#!/usr/bin/env bash
# ==============================================================================
# NxNative Launcher - GitLab Release & DMG Publisher
# ==============================================================================
# This script builds the production application, creates the compressed .dmg,
# and publishes/attaches it to GitLab Releases, keeping the latest release updated.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$REPO_ROOT/.." && pwd)"

GITLAB_PROJECT="88419597"
GITLAB_URL="https://gitlab.com"
DMG_NAME="NxNative_Launcher.dmg"
DMG_PATH="$WORKSPACE_DIR/$DMG_NAME"
APP_PATH="$WORKSPACE_DIR/NxNative_Launcher.app"

echo "=================================================="
echo "  NxNative Launcher - GitLab Release Packaging    "
echo "=================================================="

# 1. Build GUI application
echo "==> [1/3] Building production Swift GUI..."
"$SCRIPT_DIR/build_gui.sh"

# Extract Version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "2.3.2")
TAG_NAME="v$VERSION"

echo "==> Target Version: $TAG_NAME"

# 2. Package DMG
echo "==> [2/3] Building compressed DMG ($DMG_NAME)..."
"$SCRIPT_DIR/create_dmg.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "[ERROR] DMG creation failed. $DMG_PATH does not exist."
    exit 1
fi

DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
echo "==> DMG successfully created: $DMG_PATH ($DMG_SIZE)"

# 3. GitLab Release Integration
echo "==> [3/3] Preparing GitLab Release for $TAG_NAME..."

TOKEN="${GITLAB_TOKEN:-${GL_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    REMOTE_URL=$(git -C "$REPO_ROOT" remote get-url gitlab 2>/dev/null || git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
    TOKEN=$(echo "$REMOTE_URL" | sed -nE 's/.*(glpat-[^@]+)@.*/\1/p')
fi
if [ -z "$TOKEN" ]; then
    TOKEN=$(security find-internet-password -s gitlab.com -w 2>/dev/null || true)
fi

if [ -z "$TOKEN" ]; then
    echo "[ERROR] No GitLab API token found in GITLAB_TOKEN / GL_TOKEN, git remotes, or macOS Keychain."
    exit 1
fi

if [ -n "$TOKEN" ]; then
    # Clean up older releases so ONLY the latest version is kept on GitLab
    echo "==> Cleaning up older releases on GitLab (keeping only $TAG_NAME)..."
    OLD_RELEASES=$(curl -s --header "PRIVATE-TOKEN: $TOKEN" "$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/releases?per_page=100" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    target = sys.argv[1]
    for r in data:
        tag = r.get("tag_name", "")
        if tag and tag != target:
            print(tag)
except Exception:
    pass
' "$TAG_NAME")

    for old_tag in $OLD_RELEASES; do
        echo "   -> Removing older release $old_tag from GitLab..."
        ENC_TAG=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$old_tag")
        curl -s -X DELETE --header "PRIVATE-TOKEN: $TOKEN" "$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/releases/$ENC_TAG" > /dev/null || true
    done

    # Also clean up older generic packages from GitLab Package Registry
    OLD_PKG_IDS=$(curl -s --header "PRIVATE-TOKEN: $TOKEN" "$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/packages?per_page=100" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    target_ver = sys.argv[1]
    for p in data:
        if p.get("version") != target_ver and p.get("id"):
            print(p["id"])
except Exception:
    pass
' "$VERSION")

    for pkg_id in $OLD_PKG_IDS; do
        echo "   -> Removing older package ID $pkg_id from GitLab Package Registry..."
        curl -s -X DELETE --header "PRIVATE-TOKEN: $TOKEN" "$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/packages/$pkg_id" > /dev/null || true
    done

    echo "==> Uploading $DMG_NAME to GitLab Generic Package Registry..."
    PACKAGE_URL="$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/packages/generic/nxnative-launcher/$VERSION/$DMG_NAME"

    SHA256_FILE="$WORKSPACE_DIR/$DMG_NAME.sha256"
    SHA256_HASH=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
    echo "$SHA256_HASH  $DMG_NAME" > "$SHA256_FILE"
    SHA256_PACKAGE_URL="$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/packages/generic/nxnative-launcher/$VERSION/$DMG_NAME.sha256"
    echo "==> SHA-256 ($DMG_NAME): $SHA256_HASH"

    HTTP_CODE=$(curl -s --http1.1 -o /tmp/gl_upload.json -w "%{http_code}" \
        --header "PRIVATE-TOKEN: $TOKEN" \
        --upload-file "$DMG_PATH" \
        "$PACKAGE_URL")

    if [ "$HTTP_CODE" -eq 201 ] || [ "$HTTP_CODE" -eq 200 ]; then
        echo "[OK] Package uploaded successfully to GitLab Package Registry."
        SHA_HTTP_CODE=$(curl -s --http1.1 -o /tmp/gl_sha_upload.json -w "%{http_code}" \
            --header "PRIVATE-TOKEN: $TOKEN" \
            --upload-file "$SHA256_FILE" \
            "$SHA256_PACKAGE_URL" || echo "000")
        if [ "$SHA_HTTP_CODE" -eq 201 ] || [ "$SHA_HTTP_CODE" -eq 200 ]; then
            echo "[OK] Uploaded SHA-256 checksum ($DMG_NAME.sha256)."
        else
            echo "[WARN] Checksum upload returned HTTP $SHA_HTTP_CODE; continuing release."
            SHA256_PACKAGE_URL=""
        fi
        DIRECT_DOWNLOAD_URL="$PACKAGE_URL"

        export TOKEN
        export GITLAB_PROJECT
        export TAG_NAME
        export DMG_NAME
        export DMG_SIZE
        export DIRECT_DOWNLOAD_URL="$PACKAGE_URL"
        export SHA256_HASH
        export SHA256_PACKAGE_URL

        python3 - << 'PYEOF'
import os, urllib.request, urllib.parse, json

token = os.environ.get("TOKEN", "")
project_id = os.environ.get("GITLAB_PROJECT", "88419597")
tag_name = os.environ.get("TAG_NAME", "")
dmg_name = os.environ.get("DMG_NAME", "")
dmg_size = os.environ.get("DMG_SIZE", "")
direct_url = os.environ.get("DIRECT_DOWNLOAD_URL", "")

sha256_hash = os.environ.get("SHA256_HASH", "")
sha256_url = os.environ.get("SHA256_PACKAGE_URL", "")
sha256_line = f"- SHA-256: `{sha256_hash}`" if sha256_hash else ""

desc = f"""### NxNative Launcher {tag_name} - Official Release

Official native Apple Silicon release for macOS 26.6+ (Tahoe) with Apple Metal 4 and Xcode 27.2+, including iOS 26.0+ / iPadOS 26.0+ companion deployment and optional Android APK (`nx2android`) porting support.

- Package: `{dmg_name}` ({dmg_size})
- Direct Download: [{dmg_name}]({direct_url})
{sha256_line}
- Release Asset Mirror: [Download via Release Assets](https://gitlab.com/rennan-group2/nxnative_Launcher/-/releases/{tag_name}/downloads/binaries/{dmg_name})
- System Requirements: Apple Silicon Mac (M1-M5) on macOS 26.6+ (Tahoe) and Xcode 27.2+ (Metal 4)

---

### Highlights and Fixes in {tag_name}

- Universal NS Mod Compatibility (RomFS / LayeredFS Overlay & Zero Re-Porting):
  - Added native LayeredFS RomFS mod overlay support matching standard NS modding workflows (Atmosphere / LayeredFS parity).
  - Multi-Directory Mod Scanning: Automatically scans and aggregates mods across `<ROM>/NxNative_Data/mods`, `~/Documents/games/<TitleID>/mods`, `~/Library/Application Support/nxnative/<TitleID>/mods`, and bundled app resources (`Contents/Resources/mods`).
  - Deep Archive & Atmosphere Layout Resolution: Seamlessly resolves Atmosphere folder structures (`atmosphere/contents/<TitleID>/romfs`), nested zip archives (such as GameBanana mod packages), and loose asset folders, drilling down to find the true RomFS asset root and exefs patches.
  - Zero Re-Porting & Real-Time Disk Persistence: Dynamically constructs and injects `DM_ROMFS_OVERLAY` at launch, while synchronizing changes immediately into `env.txt` so mods take effect whether launched through NxNative Launcher or directly via macOS Finder.
  - Apple Liquid Glass Mod Manager UI: Dedicated Mods panel integrated into Game Settings (`GameSettingsModsAndSavesView.swift`) featuring one-click "Install Mod..." file picker, Drag & Drop (`.onDrop`) installation for `.zip` files and folders, active state toggles, RomFS/exefs status badges, and deletion controls.
  - Verified Compatibility: Validated with GameBanana Mod #737074 (*DualSense/Xbox/Steam Deck UI* for Title `0400486024DEC000`), accurately replacing UI textures in real time.

---

### Previous Release Highlights (Last 3 Releases)

- v2.3.1 - Professional Atomic DMG Self-Updater, Staging & External Workspace Enforcement, Play Time Tracking:
  - Replaced legacy git/source rebuild updater with `LauncherSelfUpdater` streaming `NxNative_Launcher.dmg` from GitLab Releases with live byte progress, SHA-256 validation, and silent atomic swap.
  - Enforced staging (`--work-dir`) and unified output folder resolution across external drives, preventing unwanted home directory workspace clutter.
  - Implemented live 15-second session heartbeat checkpointing, local `playtime.json` persistence, and historical play time reconstruction.

- v2.3.0 - Controller X/Y/A/B Remapping Fix, Restored `DM_INPUT_MAPPING`, Full Modal Gamepad Navigation & Title 0400486024DEC000 Motion Blur Hotpatch Fix:
  - Enforced 1-to-1 X/Y/A/B remapping conflict clearing, restored `DM_INPUT_MAPPING` loading in `dm/host/front_mac.m`, added full D-Pad/A/B navigation across Game Settings and Port Modals, fixed ARM64 icache invalidation for Title 0400486024DEC000 motion blur hotpatch, and added `Nx2AndroidAutoUpdater`.

- v2.2.9 - Live `nx2android` Compatibility Sync, Platform Filter & Auto Cover Art Discovery:
  - Synchronized Android compatibility live with `shirai91/nx2android`, added a **macOS / iOS / iPadOS / Android** Compatibility filter with emoji-free badges, automatic missing cover art discovery, and optional Android APK porting setup.

---

### User Instructions

#### First-Time Setup (New Port):
1. Download {dmg_name}, open it, and drag NxNative_Launcher.app into `/Applications` (or your NativePort folder).
2. Open NxNative Launcher and complete the Onboarding Wizard to verify tools and NS keys.
3. Open the Port tab, select your legally dumped game directory (`.nsp`/`.xci` for NS 1 or unpacked/NUP folder for NS 2), choose `macOS`, `iOS/iPadOS`, or `Android`, and start porting.
4. Launch directly from your Library with mouse, keyboard, or game controller.

#### Existing Setup (Previously Ported `.app` / `.ipa` - No Re-Port Needed):
1. Download {dmg_name} for {tag_name} and replace your existing `NxNative_Launcher.app` (from {tag_name} onward, in-app System -> Updates relaunches cleanly automatically). All previously ported games, saves, and custom configurations remain intact.
2. Open Settings on your existing Mac `.app` to inspect shader status or select prebuilt performance presets.
3. To update an already-installed iPhone/iPad port (`.ipa` or NxN Launcher) without re-porting, switch the settings panel to iOS, pick your preset or tweaks, and click Sync Settings over USB or Wi-Fi.

---

### Game Preservation Notice ("for those who come after")

NxNative Launcher is an anti-piracy project strictly intended for software preservation, interoperability (DMCA 1201(f)), and educational research. It does not distribute, host, or link to any copyrighted proprietary games, ROMs, firmware, or encryption keys (`keys`), and only works with files legally dumped from your own hardware."""

rel_url = f"https://gitlab.com/api/v4/projects/{project_id}/releases"
encoded_tag = urllib.parse.quote(tag_name, safe="")

# Check if release exists
check_req = urllib.request.Request(f"{rel_url}/{encoded_tag}")
check_req.add_header("PRIVATE-TOKEN", token)
release_exists = False
try:
    with urllib.request.urlopen(check_req) as resp:
        if resp.status == 200:
            release_exists = True
except Exception:
    release_exists = False

if release_exists:
    put_req = urllib.request.Request(
        f"{rel_url}/{encoded_tag}",
        data=json.dumps({"name": f"NxNative Launcher {tag_name}", "description": desc}).encode('utf-8'),
        method='PUT'
    )
    put_req.add_header("PRIVATE-TOKEN", token)
    put_req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(put_req) as resp:
            print(f"[OK] Updated existing Release {tag_name} on GitLab (HTTP {resp.status})")
    except urllib.error.HTTPError as put_e:
        print(f"[ERROR] Error updating release: HTTP {put_e.code} - {put_e.read().decode('utf-8', errors='replace')}")
else:
    payload = {
        "name": f"NxNative Launcher {tag_name}",
        "tag_name": tag_name,
        "ref": "main",
        "description": desc
    }
    post_req = urllib.request.Request(rel_url, data=json.dumps(payload).encode('utf-8'), method='POST')
    post_req.add_header("PRIVATE-TOKEN", token)
    post_req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(post_req) as resp:
            print(f"[OK] Created Release {tag_name} on GitLab (HTTP {resp.status})")
    except urllib.error.HTTPError as e:
        print(f"[ERROR] Error creating release: HTTP {e.code} - {e.read().decode('utf-8', errors='replace')}")

# Attach Asset Links (DMG + SHA-256)
link_url = f"{rel_url}/{encoded_tag}/assets/links"
assets_to_attach = [
    {
        "name": f"{dmg_name} ({dmg_size})",
        "url": direct_url,
        "filepath": f"/binaries/{dmg_name}",
        "link_type": "package",
    }
]
if sha256_url:
    assets_to_attach.append({
        "name": f"{dmg_name}.sha256",
        "url": sha256_url,
        "filepath": f"/binaries/{dmg_name}.sha256",
        "link_type": "package",
    })

for link_payload in assets_to_attach:
    lreq = urllib.request.Request(link_url, data=json.dumps(link_payload).encode('utf-8'), method='POST')
    lreq.add_header("PRIVATE-TOKEN", token)
    lreq.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(lreq) as resp:
            print(f"[OK] Registered {link_payload['name']} link in Release assets (HTTP {resp.status})")
    except urllib.error.HTTPError as e:
        err_body = e.read().decode('utf-8', errors='replace')
        if e.code in (400, 409) or "already exists" in err_body:
            print(f"[INFO] Asset link already registered in release {tag_name}: {link_payload['name']}")
        else:
            print(f"[WARN] Notice attaching link {link_payload['name']}: HTTP {e.code} - {err_body}")
PYEOF
    else
        echo "[WARN] Package upload returned HTTP $HTTP_CODE (Token may need 'api' or 'write_package_registry' scope)."
        echo "       Upload payload stored in /tmp/gl_upload.json"
        exit 1
    fi
fi

echo ""
echo "=================================================="
echo "  Release Package Ready: $DMG_PATH ($DMG_SIZE)"
echo "=================================================="
echo ""
echo "GitLab Releases URL:"
echo "  https://gitlab.com/rennan-group2/nxnative_Launcher/-/releases"
echo ""
echo "Latest Release Permalink (Always points to latest):"
echo "  https://gitlab.com/rennan-group2/nxnative_Launcher/-/releases/permalink/latest"
echo ""
