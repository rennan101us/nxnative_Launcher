#!/usr/bin/env python3
"""Idempotent verification and restoration of isolated Orbitals (040032B023CA4000 / 040004F027560000) patches.

Ensures future upstream merges from seedds/nxnative never silently drop Orbitals enhancements,
while keeping other games on their standard code paths.

Usage:
    python3 scripts/apply_orbitals_patches.py --check   # Verify all hooks & config lines exist (exit 0 = OK)
    python3 scripts/apply_orbitals_patches.py [--apply] # Verify and restore missing hooks cleanly
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]

GAME_TSV_DELUXE = REPO_ROOT / "dm/games/040032B023CA4000/game.tsv"
GAME_TSV_STD = REPO_ROOT / "dm/games/040004F027560000/game.tsv"
UE_CVAR_PY_PATH = REPO_ROOT / "dm/tools/ue_cvar.py"
HLE_UECVAR_C_PATH = REPO_ROOT / "dm/host/hle_uecvar.c"


def patch_game_tsv(tsv_path: Path, apply: bool) -> list[str]:
    if not tsv_path.is_file():
        return [f"missing {tsv_path.relative_to(REPO_ROOT)}"]
    text = tsv_path.read_text(encoding="utf-8", errors="replace")
    needed: list[tuple[str, str]] = []
    if "fps_target\t60" not in text:
        needed.append(("fps_target\t60", "fps_target\t60\n"))
    if "ue_texture_pool\t1000" not in text:
        needed.append(("ue_texture_pool\t1000", "ue_texture_pool\t1000\n"))

    if not needed:
        return []
    if not apply:
        return [f"{tsv_path.relative_to(REPO_ROOT)} missing: {[k for k, _ in needed]}"]

    # Insert under # ---- Graphics ----
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    inserted = False
    for line in lines:
        out.append(line)
        if "# ---- Graphics ----" in line and not inserted:
            for _, val in needed:
                out.append(val)
            inserted = True

    if not inserted:
        for _, val in needed:
            out.append(val)

    tsv_path.write_text("".join(out), encoding="utf-8")
    print(f"[REPAIRED] {tsv_path.relative_to(REPO_ROOT)} (added fps_target 60 & ue_texture_pool 1000)")
    return []


def patch_ue_cvar_py(apply: bool) -> list[str]:
    if not UE_CVAR_PY_PATH.is_file():
        return ["missing dm/tools/ue_cvar.py"]
    text = UE_CVAR_PY_PATH.read_text(encoding="utf-8", errors="replace")
    tokens = [
        "r.DynamicRes.OperationMode",
        "r.DynamicRes.MinScreenPercentage",
        "r.DynamicRes.MaxScreenPercentage",
        "r.AntiAliasingMethod",
    ]
    missing = [t for t in tokens if t not in text]
    if not missing:
        return []
    if not apply:
        return [f"dm/tools/ue_cvar.py missing NAMES tokens: {missing}"]

    pattern = r"NAMES\s*=\s*\((.*?)\)"
    m = re.search(pattern, text, flags=re.DOTALL)
    if not m:
        return ["dm/tools/ue_cvar.py: could not locate NAMES definition"]

    inside = m.group(1).rstrip()
    if not inside.endswith(","):
        inside += ","
    to_add = "\n    " + ",\n    ".join([repr(t) for t in missing]) + ","
    replacement = f"NAMES = ({inside}{to_add}\n)"
    new_text = text[:m.start()] + replacement + text[m.end():]
    UE_CVAR_PY_PATH.write_text(new_text, encoding="utf-8")
    print("[REPAIRED] dm/tools/ue_cvar.py (registered UE DRS and TSR CVars)")
    return []


def patch_hle_uecvar_c(apply: bool) -> list[str]:
    if not HLE_UECVAR_C_PATH.is_file():
        return ["missing dm/host/hle_uecvar.c"]
    text = HLE_UECVAR_C_PATH.read_text(encoding="utf-8", errors="replace")
    marker = "orbitals_drs_tick"
    if marker in text:
        return []
    if not apply:
        return ["dm/host/hle_uecvar.c missing orbitals_drs_tick injection"]

    addition = """
static void dm_ue_cvar_set_i32(uint64_t obj_off, int32_t val) {
    if (!obj_off) return;
    uint8_t *base = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) base = g_mod[i].base;
    uint64_t ptr;
    if (!base || !rd((uint64_t)(uintptr_t)(base + obj_off + 0x10), &ptr, sizeof ptr) || !ptr) return;
    for (int c = 0; c < 2; c++) {
        int32_t cur, *p = (int32_t *)(uintptr_t)(ptr + 4 * (uint64_t)c);
        if (!rd((uint64_t)(uintptr_t)p, &cur, sizeof cur) || cur == val) continue;
        dm_guest_write_prepare(p, sizeof *p); __atomic_store_n(p, val, __ATOMIC_RELAXED);
    }
}

static void dm_ue_cvar_set_f32(uint64_t obj_off, float val) {
    if (!obj_off) return;
    uint8_t *base = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) base = g_mod[i].base;
    uint64_t ptr;
    if (!base || !rd((uint64_t)(uintptr_t)(base + obj_off + 0x10), &ptr, sizeof ptr) || !ptr) return;
    uint32_t wval; memcpy(&wval, &val, sizeof wval);
    for (int c = 0; c < 2; c++) {
        uint32_t cur, *p = (uint32_t *)(uintptr_t)(ptr + 4 * (uint64_t)c);
        if (!rd((uint64_t)(uintptr_t)p, &cur, sizeof cur) || cur == wval) continue;
        dm_guest_write_prepare(p, sizeof *p); __atomic_store_n(p, wval, __ATOMIC_RELAXED);
    }
}

static void orbitals_drs_tick(void) {
    static int drs_state = -1;
    static uint64_t off_opmode, off_min_sc, off_max_sc, off_aa;
    if (drs_state < 0) {
        drs_state = 0;
        int is_orbitals = (DM_GAME_PROGRAM_ID == 0x040032B023CA4000ull || DM_GAME_PROGRAM_ID == 0x040004F027560000ull);
        const char *e = getenv("DM_DYNAMIC_RESOLUTION");
        int want_drs = (e && atoi(e) == 1) || (is_orbitals && (!e || atoi(e) != 0));
        if (!want_drs) return;
        off_opmode = dm_ue_cvar("r.DynamicRes.OperationMode");
        off_min_sc = dm_ue_cvar("r.DynamicRes.MinScreenPercentage");
        off_max_sc = dm_ue_cvar("r.DynamicRes.MaxScreenPercentage");
        off_aa = dm_ue_cvar("r.AntiAliasingMethod");
        if (off_opmode || off_min_sc) {
            LOG("main: Unreal DRS 85%%-100%% + TSR active for %s", is_orbitals ? "Orbitals" : "UE5");
            drs_state = 1;
        }
    }
    if (!drs_state) return;
    if (off_opmode) dm_ue_cvar_set_i32(off_opmode, 1);
    if (off_min_sc) dm_ue_cvar_set_f32(off_min_sc, 85.0f);
    if (off_max_sc) dm_ue_cvar_set_f32(off_max_sc, 100.0f);
    if (off_aa) dm_ue_cvar_set_i32(off_aa, 4);
}
"""
    # Insert before dm_ue_cvar_tick
    target = "void dm_ue_cvar_tick(void) {"
    if target not in text:
        return ["dm/host/hle_uecvar.c: could not locate dm_ue_cvar_tick definition"]

    # Also add call inside dm_ue_cvar_tick
    call_injection = "    orbitals_drs_tick();\n"
    idx = text.find(target)
    new_text = text[:idx] + addition + text[idx:]
    # Now insert call after the opening brace
    target_new = "void dm_ue_cvar_tick(void) {\n"
    idx2 = new_text.find(target_new)
    if idx2 != -1:
        new_text = new_text[:idx2 + len(target_new)] + call_injection + new_text[idx2 + len(target_new):]

    HLE_UECVAR_C_PATH.write_text(new_text, encoding="utf-8")
    print("[REPAIRED] dm/host/hle_uecvar.c (injected orbitals_drs_tick for 85%-100% DRS & TSR)")
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify or apply isolated Orbitals patches")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Only verify hooks without editing files")
    mode.add_argument("--apply", action="store_true", help="Verify and repair missing hooks cleanly")
    parser.add_argument("--soft", action="store_true", help="Non-fatal mode on warnings")
    args = parser.parse_args()

    apply = not args.check
    errors: list[str] = []

    errors.extend(patch_game_tsv(GAME_TSV_DELUXE, apply))
    errors.extend(patch_game_tsv(GAME_TSV_STD, apply))
    errors.extend(patch_ue_cvar_py(apply))
    errors.extend(patch_hle_uecvar_c(apply))

    if errors:
        for err in errors:
            print(f"[ORBITALS-PATCH-ERROR] {err}", file=sys.stderr)
        return 1

    print("[ORBITALS-PATCH-OK] All isolated Orbitals (040032B023CA4000 / 040004F027560000) patches verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
