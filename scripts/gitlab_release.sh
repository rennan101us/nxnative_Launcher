#!/usr/bin/env bash
# ==============================================================================
# NxNative Launcher - Release & DMG Publisher (Wrapper)
# ==============================================================================
# Forwards to unified dual-release publisher (GitHub default + GitLab fallback)
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/publish_release.sh" "$@"
