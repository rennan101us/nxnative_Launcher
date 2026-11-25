#!/usr/bin/env bash
# ==============================================================================
# NxNative Launcher - Dual Release Publisher (GitHub Default + GitLab Fallback)
# ==============================================================================
# This script builds the production application, creates the compressed .dmg,
# and publishes the release and verified assets to BOTH GitHub and GitLab simultaneously.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$REPO_ROOT/.." && pwd)"

GITHUB_REPO="rennan101us/nxnative_Launcher"
GITLAB_PROJECT="88419597"
GITLAB_URL="https://gitlab.com"
DMG_NAME="NxNative_Launcher.dmg"
DMG_PATH="$WORKSPACE_DIR/$DMG_NAME"
APP_PATH="$WORKSPACE_DIR/NxNative_Launcher.app"
SHA256_FILE="$WORKSPACE_DIR/$DMG_NAME.sha256"

echo "=================================================="
echo "  NxNative Launcher - Dual Release Publisher      "
echo "  Targets: GitHub ($GITHUB_REPO) & GitLab        "
echo "=================================================="

# 1. Build GUI application
echo "==> [1/5] Building production Swift GUI..."
"$SCRIPT_DIR/build_gui.sh"

# Extract Version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "2.3.4")
TAG_NAME="v$VERSION"
echo "==> Target Version: $TAG_NAME"

# 2. Package DMG
echo "==> [2/5] Building compressed DMG ($DMG_NAME)..."
"$SCRIPT_DIR/create_dmg.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "[ERROR] DMG creation failed. $DMG_PATH does not exist." >&2
    exit 1
fi

DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
SHA256_HASH=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "$SHA256_HASH  $DMG_NAME" > "$SHA256_FILE"
echo "==> DMG successfully created: $DMG_PATH ($DMG_SIZE)"
echo "==> SHA-256 Checksum: $SHA256_HASH"

# 3. Synchronize code to GitHub
echo "==> [3/5] Synchronizing latest code to GitHub fork..."
"$SCRIPT_DIR/sync_github.sh"

# 4. Generate Unified Release Notes
NOTES_FILE="/tmp/nxnative_release_notes_${TAG_NAME}.md"
cat << EOF > "$NOTES_FILE"
### NxNative Launcher ${TAG_NAME} - Official Release

Official native Apple Silicon release for macOS 26.6+ (Tahoe) with Apple Metal 4 and Xcode 27.2+, including iOS 26.0+ / iPadOS 26.0+ companion deployment and optional Android APK (\`nx2android\`) porting support.

- Package: \`${DMG_NAME}\` (${DMG_SIZE})
- Direct GitHub Download: [${DMG_NAME}](https://github.com/${GITHUB_REPO}/releases/download/${TAG_NAME}/${DMG_NAME})
- Direct GitLab Mirror: [${DMG_NAME}](${GITLAB_URL}/api/v4/projects/${GITLAB_PROJECT}/packages/generic/nxnative-launcher/${VERSION}/${DMG_NAME})
- SHA-256: \`${SHA256_HASH}\`
- System Requirements: Apple Silicon Mac (M1-M5) on macOS 26.6+ (Tahoe) and Xcode 27.2+ (Metal 4)

---

### Highlights and Fixes in ${TAG_NAME}

- Fix(launcher): Preserve Game `dmhost` Executable When Saving Settings or Launching (GitLab Issue #12):
  - Stopped the launcher from automatically replacing `Contents/MacOS/dmhost` inside ported `.app` bundles when saving game settings or launching a game.
  - Saving settings now strictly updates `env.txt` (and sanitizes legacy `DM_TEX_RELEASE` values in `env.txt`) without modifying the app's executable binary.
  - Custom, backup, or newer `dmhost` binaries inside existing `.app` bundles are now always preserved intact. Users who want to upgrade a game's engine binary can explicitly re-port the game using "Port Again" (which preserves shader caches and unpacked assets).

- Fix(nvn/graphics): Stop Squaring Linear Colour on MetalFX Upscaler Chain (Included from v2.3.3):
  - Fixed an issue in The Legend of Zelda: Ocarina of Time (\`0400486024DEC000\`) where running with \`DM_UPSCALER=metalfx\` rendered scenes with an excessively dark overall image and crushed shadow values below 1.
  - The isolated \`upscaler_chain\` optimization skips the game's square-root pre-passes and feeds MetalFX the linear scene colour those passes read. The copy into the MetalFX spatial scaler now preserves linear color and avoids squaring when \`chain_linear\` is active, matching expected in-game lighting and contrast.
  - Recompiled and bundled optimized \`dmhost\` engine binary with the corrected shader dispatch pipeline.

- Universal NS Mod Compatibility (RomFS / LayeredFS Overlay & Zero Re-Porting):
  - Retains native LayeredFS RomFS mod overlay support matching standard NS modding workflows (Atmosphere / LayeredFS parity).
  - Multi-Directory Mod Scanning: Automatically scans and aggregates mods across \`<ROM>/NxNative_Data/mods\`, \`~/Documents/games/<TitleID>/mods\`, \`~/Library/Application Support/nxnative/<TitleID>/mods\`, and bundled app resources (\`Contents/Resources/mods\`).
  - Deep Archive & Atmosphere Layout Resolution: Resolves Atmosphere folder structures (\`atmosphere/contents/<TitleID>/romfs\`), nested zip archives (GameBanana mod packages), and loose asset folders.
  - Apple Liquid Glass Mod Manager UI: Dedicated Mods panel integrated into Game Settings with drag-and-drop installation, active state toggles, and instant \`DM_ROMFS_OVERLAY\` sync.

- Dual Release & Automatic Mirror Redundancy:
  - NxNative Launcher checks GitHub Releases as primary default with automatic zero-downtime fallback to GitLab Releases and Package Registry.
  - Verified atomic DMG download, SHA-256 checksum verification, and in-place relaunch.

---

### User Instructions

#### First-Time Setup (New Port):
1. Download ${DMG_NAME}, open it, and drag NxNative_Launcher.app into \`/Applications\` (or your NativePort folder).
2. Open NxNative Launcher and complete the Onboarding Wizard to verify tools and NS keys.
3. Open the Port tab, select your legally dumped game directory (\`.nsp\`/\`.xci\` for NS 1 or unpacked/NUP folder for NS 2), choose \`macOS\`, \`iOS/iPadOS\`, or \`Android\`, and start porting.
4. Launch directly from your Library with mouse, keyboard, or game controller.

#### Existing Setup (Previously Ported \`.app\` / \`.ipa\` - No Re-Port Needed):
1. Download ${DMG_NAME} for ${TAG_NAME} and replace your existing \`NxNative_Launcher.app\` (from ${TAG_NAME} onward, in-app System -> Updates relaunches cleanly automatically). All previously ported games, saves, and custom configurations remain intact.
2. Open Settings on your existing Mac \`.app\` to inspect shader status or select prebuilt performance presets.
3. To update an already-installed iPhone/iPad port (\`.ipa\` or NxN Launcher) without re-porting, switch the settings panel to iOS, pick your preset or tweaks, and click Sync Settings over USB or Wi-Fi.

---

### Game Preservation Notice ("for those who come after")

NxNative Launcher is an anti-piracy project strictly intended for software preservation, interoperability (DMCA 1201(f)), and educational research. It does not distribute, host, or link to any copyrighted proprietary games, ROMs, firmware, or encryption keys (\`keys\`), and only works with files legally dumped from your own hardware.
EOF

# 5. Publish to GitHub Releases (Default Mirror)
echo "==> [4/5] Publishing Release to GitHub ($GITHUB_REPO)..."
if command -v gh >/dev/null 2>&1; then
    if gh release view "$TAG_NAME" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        echo "   -> Updating existing release $TAG_NAME on GitHub..."
        gh release edit "$TAG_NAME" --repo "$GITHUB_REPO" --title "NxNative Launcher $TAG_NAME" --notes-file "$NOTES_FILE"
        gh release upload "$TAG_NAME" "$DMG_PATH" "$SHA256_FILE" --repo "$GITHUB_REPO" --clobber
    else
        echo "   -> Creating new release $TAG_NAME on GitHub..."
        gh release create "$TAG_NAME" "$DMG_PATH" "$SHA256_FILE" \
            --repo "$GITHUB_REPO" \
            --title "NxNative Launcher $TAG_NAME" \
            --notes-file "$NOTES_FILE"
    fi
    echo "[OK] Successfully published $TAG_NAME to GitHub Releases: https://github.com/$GITHUB_REPO/releases/tag/$TAG_NAME"
else
    echo "[WARN] 'gh' CLI not found; skipping GitHub release creation."
fi

# 6. Publish to GitLab Releases (Fallback Mirror)
echo "==> [5/5] Publishing Release to GitLab ($GITLAB_PROJECT)..."
TOKEN="${GITLAB_TOKEN:-${GL_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    REMOTE_URL=$(git -C "$REPO_ROOT" remote get-url gitlab 2>/dev/null || git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
    TOKEN=$(echo "$REMOTE_URL" | sed -nE 's/.*(glpat-[^@]+)@.*/\1/p')
fi
if [ -z "$TOKEN" ]; then
    TOKEN=$(security find-internet-password -s gitlab.com -w 2>/dev/null || true)
fi

if [ -n "$TOKEN" ]; then
    # Upload DMG to GitLab Generic Package Registry
    PACKAGE_URL="$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/packages/generic/nxnative-launcher/$VERSION/$DMG_NAME"
    SHA256_PACKAGE_URL="$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT/packages/generic/nxnative-launcher/$VERSION/$DMG_NAME.sha256"

    HTTP_CODE=$(curl -s --http1.1 -o /dev/null -w "%{http_code}" \
        --header "PRIVATE-TOKEN: $TOKEN" \
        --upload-file "$DMG_PATH" \
        "$PACKAGE_URL" || echo "000")

    if [ "$HTTP_CODE" -eq 201 ] || [ "$HTTP_CODE" -eq 200 ]; then
        echo "[OK] DMG package uploaded to GitLab Package Registry."
        _=$(curl -s --http1.1 -o /dev/null -w "%{http_code}" \
            --header "PRIVATE-TOKEN: $TOKEN" \
            --upload-file "$SHA256_FILE" \
            "$SHA256_PACKAGE_URL" || true)

        export TOKEN GITLAB_PROJECT TAG_NAME DMG_NAME DMG_SIZE NOTES_FILE PACKAGE_URL SHA256_PACKAGE_URL
        python3 - << 'PYEOF'
import os, urllib.request, urllib.parse, json

token = os.environ.get("TOKEN", "")
project_id = os.environ.get("GITLAB_PROJECT", "")
tag_name = os.environ.get("TAG_NAME", "")
dmg_name = os.environ.get("DMG_NAME", "")
dmg_size = os.environ.get("DMG_SIZE", "")
notes_file = os.environ.get("NOTES_FILE", "")
direct_url = os.environ.get("PACKAGE_URL", "")
sha256_url = os.environ.get("SHA256_PACKAGE_URL", "")

with open(notes_file, "r", encoding="utf-8") as f:
    desc = f.read()

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
    except Exception as e:
        print(f"[WARN] Error updating GitLab release: {e}")
else:
    post_req = urllib.request.Request(
        rel_url,
        data=json.dumps({"name": f"NxNative Launcher {tag_name}", "tag_name": tag_name, "ref": "main", "description": desc}).encode('utf-8'),
        method='POST'
    )
    post_req.add_header("PRIVATE-TOKEN", token)
    post_req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(post_req) as resp:
            print(f"[OK] Created Release {tag_name} on GitLab (HTTP {resp.status})")
    except Exception as e:
        print(f"[WARN] Error creating GitLab release: {e}")

# Attach Asset Links
link_url = f"{rel_url}/{encoded_tag}/assets/links"
for name, url, path in [
    (f"{dmg_name} ({dmg_size})", direct_url, f"/binaries/{dmg_name}"),
    (f"{dmg_name}.sha256", sha256_url, f"/binaries/{dmg_name}.sha256")
]:
    lreq = urllib.request.Request(link_url, data=json.dumps({"name": name, "url": url, "filepath": path, "link_type": "package"}).encode('utf-8'), method='POST')
    lreq.add_header("PRIVATE-TOKEN", token)
    lreq.add_header("Content-Type", "application/json")
    try:
        urllib.request.urlopen(lreq)
    except Exception:
        pass
PYEOF
        echo "[OK] Successfully published $TAG_NAME to GitLab Releases: $GITLAB_URL/rennan-group2/nxnative_Launcher/-/releases"
    else
        echo "[WARN] GitLab upload returned HTTP $HTTP_CODE; skipping GitLab release update."
    fi
else
    echo "[INFO] No GitLab token found; skipping GitLab release update."
fi

rm -f "$NOTES_FILE"

echo ""
echo "=================================================="
echo "  🎉 Dual Release Published Successfully!         "
echo "  GitHub: https://github.com/$GITHUB_REPO/releases"
echo "  GitLab: $GITLAB_URL/rennan-group2/nxnative_Launcher/-/releases"
echo "=================================================="
