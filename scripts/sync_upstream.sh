#!/usr/bin/env bash
# ==============================================================================
# NxNative Launcher - Safe Upstream Synchronization Script (seedds/nxnative)
# ==============================================================================
# Features:
# 1. Transactional Staging Sandbox: Merges and tests in an isolated shadow branch;
#    main is never touched or corrupted if an upstream conflict or error occurs.
# 2. Unpatch -> Merge -> Repatch: Reverts in-tree hooks before merge to eliminate
#    conflicts, then semantically reapplies them on the clean upstream base.
# 3. Soft Degradation: P0 engine compatibility is preserved; non-critical P1
#    visual tweaks are bypassed gracefully without aborting the entire update.
# 4. Mandatory Anti-Regression: Runs unit tests and dmhost smoke builds before
#    promoting changes to main.
# ==============================================================================
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Ensure fallback Git committer identity for automated merge commits on user machines
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-NxNative Launcher}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-launcher@nxnative.local}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

# Prefer bundled Python 3.12+ or Homebrew Python over macOS stub /usr/bin/python3
PYTHON_BIN=""
for candidate in \
    "$REPO_ROOT/gui/Resources/python/bin/python3" \
    "${NXNATIVE_RUNNING_APP:-}/Contents/Resources/python/bin/python3" \
    "/Applications/NxNative_Launcher.app/Contents/Resources/python/bin/python3" \
    "$HOME/Applications/NxNative_Launcher.app/Contents/Resources/python/bin/python3" \
    "/opt/homebrew/bin/python3" \
    "/usr/local/bin/python3" \
    "$(command -v python3 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        PYTHON_BIN="$candidate"
        break
    fi
done
PYTHON_BIN="${PYTHON_BIN:-python3}"
export PATH="$(dirname "$PYTHON_BIN"):/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "🔄 [NxNative Launcher] Checking upstream synchronization (seedds/nxnative)..."

# 1. Configure merge drivers for zero-conflict automated updates
git config merge.ours.driver true

# 2. Ensure upstream (GitHub) and origin (GitLab) remotes are configured
if ! git remote get-url upstream >/dev/null 2>&1; then
    echo "⚙️ Adding upstream remote (https://github.com/seedds/nxnative.git)..."
    git remote add upstream https://github.com/seedds/nxnative.git
fi

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "⚙️ Adding origin remote (https://gitlab.com/rennan-group2/nxnative_Launcher.git)..."
    git remote add origin https://gitlab.com/rennan-group2/nxnative_Launcher.git
else
    ORIGIN_URL=$(git remote get-url origin)
    if [[ "$ORIGIN_URL" =~ "github.com/rennan101" ]]; then
        echo "⚙️ Migrating origin remote from suspended GitHub to GitLab..."
        git remote set-url origin https://gitlab.com/rennan-group2/nxnative_Launcher.git
    fi
fi

# 3. Fetch upstream updates cleanly with explicit refspec
echo "📥 Fetching commits from upstream/main..."
git fetch upstream "+refs/heads/main:refs/remotes/upstream/main" --force

# 4. Verify local branch status
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "⚠️ Warning: You are currently on branch '$CURRENT_BRANCH'. Switching to 'main'..."
    git checkout main
fi

# 4.5 Save any local apply_oot_patches.py edits across auto-stash & clear transient runtime patches
TMP_OOT_PATCHES="/tmp/nxnative_apply_oot_patches_$$.py"
trap 'rm -f "${TMP_OOT_PATCHES:-}"' EXIT
if [ -f "$REPO_ROOT/scripts/apply_oot_patches.py" ]; then
    cp -f "$REPO_ROOT/scripts/apply_oot_patches.py" "$TMP_OOT_PATCHES" 2>/dev/null || true
fi
"$PYTHON_BIN" "$REPO_ROOT/scripts/apply_oot_patches.py" --revert >/dev/null 2>&1 || true
git checkout -- \
    dm/gfx/nvn/nvn_mtl.m \
    dm/gfx/msl/present.metal \
    dm/gfx/msl/copy.metal \
    dm/gfx/nvn/hle_nvn.c \
    dm/host/hle_fpslock.c \
    dm/host/front_mac.m \
    dm/mac/pack_app.py \
    scripts/build_ipa_from_nsp.py \
    dm/games/0100A9D01C446000/game.tsv \
    dm/games/01002DA013484000/game.tsv 2>/dev/null || true

# 5. Check for unstaged or uncommitted changes
STASHED=0
if ! git diff-index --quiet HEAD --; then
    echo "⚠️ Uncommitted modifications found in working directory."
    echo "📦 Auto-stashing local modifications before syncing..."
    git stash push -m "Auto-stash before sync-upstream on $(date)"
    STASHED=1
fi

# 6. Compare commit counts
BEHIND_COUNT=$(git rev-list --count HEAD..upstream/main)
if [ "$BEHIND_COUNT" -eq 0 ]; then
    echo "✅ Your fork is already 100% up to date with seedds/nxnative:main! No action required."
    if [ "$STASHED" -eq 1 ]; then
        echo "Restoring local stashed changes..."
        git stash pop || true
    fi
    exit 0
fi

echo "🚀 Found $BEHIND_COUNT new commits in upstream."
echo "--- Latest 5 commits in upstream ---"
git log HEAD..upstream/main --oneline -n 5
echo "------------------------------------"

# 7. Create an isolated staging branch to protect 'main'
STAGING_BRANCH="_staging_upstream_sync_$$"
echo "🛡️ Creating transaction-safe staging sandbox branch '$STAGING_BRANCH'..."
git checkout -b "$STAGING_BRANCH"
if [ -n "${TMP_OOT_PATCHES:-}" ] && [ -f "$TMP_OOT_PATCHES" ]; then
    cp -f "$TMP_OOT_PATCHES" "$REPO_ROOT/scripts/apply_oot_patches.py"
fi

cleanup_staging_failure() {
    echo ""
    echo "⚠️ Upstream synchronization failed verification or was cancelled."
    echo "🛡️ Discarding staging sandbox and returning to pristine 'main'..."
    git checkout main 2>/dev/null || true
    git branch -D "$STAGING_BRANCH" 2>/dev/null || true
    if [ "$STASHED" -eq 1 ]; then
        echo "Restoring local stashed changes..."
        git stash pop 2>/dev/null || true
    fi
    exit 1
}

# 8. Unpatch in-tree engine files before merge to eliminate all merge conflicts
echo "🧹 Reverting in-tree modifications before merge to guarantee clean fast merge..."
"$PYTHON_BIN" "$REPO_ROOT/scripts/apply_oot_patches.py" --revert >/dev/null 2>&1 || true
if ! git diff --quiet; then
    git commit -am "chore(sync): temporary unpatch before upstream merge" >/dev/null 2>&1 || true
fi

# 9. Execute safe merge with intelligent conflict resolution
echo "🔀 Merging upstream/main into staging sandbox..."
MERGE_OK=0
if git merge upstream/main --no-edit -m "chore(sync): merge upstream updates from seedds/nxnative"; then
    MERGE_OK=1
else
    echo "⚙️ Analyzing potential conflicts..."
    CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -n "$CONFLICT_FILES" ]; then
        echo "⚙️ Auto-resolving engine updates while safeguarding local launcher customizations..."
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            if [[ "$file" == gui/* ]] || \
               [[ "$file" == frontend-ios/* ]] || \
               [[ "$file" == "README.md" ]] || \
               [[ "$file" == "GEMINI.md" ]] || \
               [[ "$file" == .gitlab* ]] || \
               [[ "$file" == .github/* ]] || \
               [[ "$file" == scripts/build_gui.sh ]] || \
               [[ "$file" == scripts/create_dmg.sh ]] || \
               [[ "$file" == scripts/gitlab_release.sh ]] || \
               [[ "$file" == scripts/sync_upstream.sh ]] || \
               [[ "$file" == scripts/apply_oot_patches.py ]] || \
               [[ "$file" == dm/gfx/nvn/oot_enhancements.inc ]] || \
               [[ "$file" == dm/games/0400486024DEC000/* ]] || \
               [[ "$file" == dm/games/game.py ]] || \
               [[ "$file" == dm/tools/tests/test_oot_render_scale.py ]] || \
               [[ "$file" == gui/Resources/engine/* ]] || \
               [[ "$file" == dm/ios/Shell/* ]] || \
               [[ "$file" == dm/ios/framework/* ]] || \
               [[ "$file" == dm/ios/project-*.yml ]] || \
               [[ "$file" == dm/ios/tools/build_shell.sh ]] || \
               [[ "$file" == dm/ios/Sources/FrameworkBootstrap.* ]] || \
               [[ "$file" == dm/ios/Sources/DataBookmark.* ]]; then
                echo "  [KEEP OURS] $file"
                git checkout HEAD -- "$file" 2>/dev/null || true
            else
                echo "  [ACCEPT UPSTREAM] $file"
                git checkout --theirs -- "$file" 2>/dev/null || true
            fi
            git add "$file" 2>/dev/null || true
        done <<< "$CONFLICT_FILES"
        if git commit --no-edit -m "chore(sync): merge upstream updates from seedds/nxnative (auto-resolved)"; then
            MERGE_OK=1
        fi
    else
        git checkout -- . 2>/dev/null || true
        if git merge upstream/main --no-edit -m "chore(sync): merge upstream updates from seedds/nxnative"; then
            MERGE_OK=1
        fi
    fi
fi

if [ "$MERGE_OK" -ne 1 ]; then
    cleanup_staging_failure
fi

# 10. Re-apply patches in soft / resilient mode
echo ""
echo "🧚 Re-applying & verifying isolated engine patches (with soft degradation)..."
"$PYTHON_BIN" "$REPO_ROOT/scripts/apply_oot_patches.py" --apply --soft

# 11. Run profile and patch unit tests
echo ""
echo "🧪 Running profile and patch unit tests..."
if ! (cd "$REPO_ROOT" && "$PYTHON_BIN" -m unittest dm/tools/tests/test_oot_render_scale.py dm/tools/tests/test_patches.py dm/tools/tests/test_settings.py dm/tools/tests/test_split_d3cpk.py dm/tools/tests/test_split_casc.py >/tmp/sync_tests.log 2>&1); then
    echo "❌ ERROR: Critical unit tests failed after upstream sync!"
    tail -n 25 /tmp/sync_tests.log
    cleanup_staging_failure
else
    echo "✅ Profile & patch unit tests passed!"
fi

# 12. Mandatory Anti-Regression Verification (dmhost build)
echo ""
echo "🛡️ Running Mandatory Anti-Regression Verification (dmhost smoke build)..."
if ! make -C "$REPO_ROOT/dm/host" clean >/tmp/sync_verify.log 2>&1 || \
   ! make -C "$REPO_ROOT/dm/host" -j8 GAME=040074A01BF12000 >/tmp/sync_verify.log 2>&1 || \
   ! make -C "$REPO_ROOT/dm/host" -j8 GAME=0400486024DEC000 >/tmp/sync_verify.log 2>&1; then
    echo "❌ ERROR: Regression detected! dmhost failed to compile after upstream sync."
    tail -n 25 /tmp/sync_verify.log
    cleanup_staging_failure
else
    echo "✅ Rebuilding bundled Zelda OoT prebuilt engine binary..."
    OOT_ENGINE_DIR="$REPO_ROOT/gui/Resources/engine/0400486024DEC000"
    mkdir -p "$OOT_ENGINE_DIR"
    NEW_CHAIN="$(sed -n 's/^#define DMSH_CHAIN "\([0-9a-fA-F]*\)".*/\1/p' "$REPO_ROOT/dm/gfx/nvn/dmsh_chain.h" | head -n 1)"
    if [ -f "$OOT_ENGINE_DIR/dmhost" ] && [ -n "$NEW_CHAIN" ]; then
        OLD_CHAIN="$("$PYTHON_BIN" -c '
import re, sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
new_chain = sys.argv[2].lower().encode()
m = re.search(rb"\x00([0-9a-f]{12})\x000400486", data)
if m and m.group(1) != new_chain:
    print(m.group(1).decode())
' "$OOT_ENGINE_DIR/dmhost" "$NEW_CHAIN" 2>/dev/null || true)"
        if [ -n "$OLD_CHAIN" ] && [ ! -f "$OOT_ENGINE_DIR/dmhost-$OLD_CHAIN" ]; then
            echo "📦 Archiving previous shader-chain dmhost (dmhost-$OLD_CHAIN)..."
            cp -f "$OOT_ENGINE_DIR/dmhost" "$OOT_ENGINE_DIR/dmhost-$OLD_CHAIN"
            chmod 755 "$OOT_ENGINE_DIR/dmhost-$OLD_CHAIN"
            codesign --force --sign - "$OOT_ENGINE_DIR/dmhost-$OLD_CHAIN" >/dev/null 2>&1 || true
        fi
    fi

    cp -f "$REPO_ROOT/dm/host/dmhost" "$OOT_ENGINE_DIR/dmhost"
    chmod 755 "$OOT_ENGINE_DIR/dmhost"
    codesign --force --sign - "$OOT_ENGINE_DIR/dmhost" >/dev/null 2>&1 || true

    if [ -n "$(git status --porcelain -- \
        dm/gfx/nvn/nvn_mtl.m \
        dm/gfx/nvn/oot_enhancements.inc \
        dm/gfx/msl/present.metal \
        dm/gfx/msl/copy.metal \
        dm/mac/pack_app.py \
        scripts/build_ipa_from_nsp.py \
        dm/games/0400486024DEC000 \
        gui/Resources/engine/0400486024DEC000 2>/dev/null)" ]; then
        git add \
            dm/gfx/nvn/nvn_mtl.m \
            dm/gfx/nvn/oot_enhancements.inc \
            dm/gfx/msl/present.metal \
            dm/gfx/msl/copy.metal \
            dm/mac/pack_app.py \
            scripts/build_ipa_from_nsp.py \
            dm/games/0400486024DEC000 \
            gui/Resources/engine/0400486024DEC000 2>/dev/null || true
        git commit -m "chore(sync): preserve engine enhancements and rebuild dmhost" >/dev/null 2>&1 || true
    fi
    echo "✅ dmhost compilation smoke test passed successfully!"
fi

# 13. Regenerate SUPPORTED_GAMES.md
echo ""
echo "🎮 Regenerating SUPPORTED_GAMES.md from upstream game definitions..."
"$PYTHON_BIN" "$REPO_ROOT/scripts/generate_supported_games.py" 2>/dev/null || "$PYTHON_BIN" "$REPO_ROOT/nxnative/scripts/generate_supported_games.py" 2>/dev/null || true
if git status --porcelain | grep -q "SUPPORTED_GAMES.md"; then
    echo "📝 Committing updated SUPPORTED_GAMES.md..."
    git add SUPPORTED_GAMES.md nxnative/SUPPORTED_GAMES.md 2>/dev/null || true
    git commit -m "docs: auto-update SUPPORTED_GAMES.md from upstream game list" || true
fi

# 14. Fast-Forward 'main' to validated staging
echo ""
echo "🚀 Staging sandbox passed all verifications! Promoting changes to 'main'..."
git checkout main
git merge --ff-only "$STAGING_BRANCH"
git branch -D "$STAGING_BRANCH"

echo ""
echo "🎉 Merge completed successfully and verified!"
echo "All NxNative Launcher customizations and host binaries are verified."

if [ "$STASHED" -eq 1 ]; then
    echo ""
    echo "Restoring local stashed changes..."
    git stash pop || true
fi

exit 0
