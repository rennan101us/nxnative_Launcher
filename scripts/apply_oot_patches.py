#!/usr/bin/env python3
"""Idempotent verification and restoration of isolated Zelda: Ocarina of Time (0400486024DEC000) patches.

Ensures future upstream merges from seedds/nxnative never silently drop or break OoT enhancements,
while leaving all other games strictly on unmodified upstream code paths.

Usage:
    python3 scripts/apply_oot_patches.py --check   # Verify all hooks & config lines exist (exit 0 = OK)
    python3 scripts/apply_oot_patches.py [--apply] # Verify and restore missing hooks cleanly
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]

OOT_INC_PATH = REPO_ROOT / "dm/gfx/nvn/oot_enhancements.inc"
NVN_MTL_PATH = REPO_ROOT / "dm/gfx/nvn/nvn_mtl.m"
NVN_GEOMETRY_PATH = REPO_ROOT / "dm/gfx/nvn/nvn_geometry.inc"
PRESENT_METAL_PATH = REPO_ROOT / "dm/gfx/msl/present.metal"
COPY_METAL_PATH = REPO_ROOT / "dm/gfx/msl/copy.metal"
GAME_TSV_PATH = REPO_ROOT / "dm/games/0400486024DEC000/game.tsv"
PATCHES_PY_PATH = REPO_ROOT / "dm/games/0400486024DEC000/patches.py"
PACK_APP_PY_PATH = REPO_ROOT / "dm/mac/pack_app.py"
BUILD_IPA_PY_PATH = REPO_ROOT / "scripts/build_ipa_from_nsp.py"


def check_oot_inc() -> list[str]:
    if not OOT_INC_PATH.is_file():
        return ["missing dm/gfx/nvn/oot_enhancements.inc"]
    text = OOT_INC_PATH.read_text(encoding="utf-8", errors="replace")
    required = [
        "OOT_ENH_TOP",
        "OOT_ENH_MEM",
        "OOT_ENH_UPCHAIN",
        "OOT_ENH_FRAMEGEN",
        "is_oot_game(void)",
        "0400486024DEC000",
        "rel_push(",
        "rel_run(",
        "rel_donor(",
        "rt_lossy(",
        "pool_skip_retired(",
        "fb_dself(",
        "cond_conservative(",
        "oot_up_chain_dispatch(",
        "up_sharpen(",
        "fg_on(",
        "fg_handle_held(",
        "fg_take_or_hold(",
        "fg_drop_held(",
        "g_fg_args",
        "k_nxnative_compat_chains",
    ]
    missing = [tok for tok in required if tok not in text]
    return [f"dm/gfx/nvn/oot_enhancements.inc missing token: {tok}" for tok in missing]


def patch_present_metal(apply: bool) -> list[str]:
    if not PRESENT_METAL_PATH.is_file():
        return ["missing dm/gfx/msl/present.metal"]
    text = PRESENT_METAL_PATH.read_text(encoding="utf-8", errors="replace")
    if "struct CropMix" in text and "fs_blend(" in text:
        return []
    if not apply:
        return ["dm/gfx/msl/present.metal missing CropMix / fs_blend"]
    anchor = "struct Crop { float4 rect; float4 edge; };\nfragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }"
    addition = (
        "\nstruct CropMix { float4 rect; float4 edge; float4 mixw; };\n"
        "fragment float4 fs_blend(V in [[stage_in]], texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]], sampler s [[sampler(0)]], constant CropMix& c [[buffer(0)]]) { "
        "float2 uv = clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw); "
        "return mix(t0.sample(s, uv), t1.sample(s, uv), c.mixw.x); }\n"
    )
    if anchor in text:
        PRESENT_METAL_PATH.write_text(text.replace(anchor, anchor + addition, 1), encoding="utf-8")
        print("[REPAIRED] dm/gfx/msl/present.metal (restored CropMix & fs_blend)")
        return []
    # Resilient regex fallback matching struct Crop + fragment float4 fs
    m = re.search(r'(struct\s+Crop\s*\{[^}]*\};[\s\S]*?fragment\s+float4\s+fs\s*\([^)]*\)\s*\{[^}]*\})', text)
    if m:
        full_anchor = m.group(1)
        PRESENT_METAL_PATH.write_text(text.replace(full_anchor, full_anchor + addition, 1), encoding="utf-8")
        print("[REPAIRED] dm/gfx/msl/present.metal (via regex pattern)")
        return []
    return ["dm/gfx/msl/present.metal anchor not found for fs_blend injection"]


def patch_copy_metal(apply: bool) -> list[str]:
    if not COPY_METAL_PATH.is_file():
        return ["missing dm/gfx/msl/copy.metal"]
    text = COPY_METAL_PATH.read_text(encoding="utf-8", errors="replace")
    if "fragment float4 fsq(" in text and "fragment float4 fsh(" in text:
        return []
    if not apply:
        return ["dm/gfx/msl/copy.metal missing fsq / fsh (CAS sharpening & root decode)"]
    anchor = "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float4 *p [[buffer(0)]]) {\n  float2 st = p[0].xy + (in.p.xy - p[1].xy) * p[0].zw; return t.sample(s, st / p[1].zw, level(0)); }"
    addition = ""
    if "fragment float4 fsq(" not in text:
        addition += (
            "\nfragment float4 fsq(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float4 *p [[buffer(0)]]) {\n"
            "  float2 st = p[0].xy + (in.p.xy - p[1].xy) * p[0].zw; float4 c = t.sample(s, st / p[1].zw, level(0)); return float4(c.rgb * abs(c.rgb), c.a); }\n"
        )
    if "fragment float4 fsh(" not in text:
        addition += (
            "\nfragment float4 fsh(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float4 *p [[buffer(0)]]) {\n"
            "  float2 st = p[0].xy + (in.p.xy - p[1].xy) * p[0].zw, d = 1 / p[1].zw, uv = st / p[1].zw;\n"
            "  float4 c = t.sample(s, uv, level(0));\n"
            "  float3 n = t.sample(s, uv - float2(0, d.y), level(0)).rgb, so = t.sample(s, uv + float2(0, d.y), level(0)).rgb;\n"
            "  float3 e = t.sample(s, uv + float2(d.x, 0), level(0)).rgb, w = t.sample(s, uv - float2(d.x, 0), level(0)).rgb;\n"
            "  float3 mn = min(min(min(n, so), min(e, w)), c.rgb), mx = max(max(max(n, so), max(e, w)), c.rgb);\n"
            "  float3 amp = sqrt(saturate(min(mn, 1 - mx) / max(mx, 1e-4)));\n"
            "  float3 k = amp * (-1 / mix(8.0, 5.0, p[2].x));\n"
            "  return float4((c.rgb + (n + so + e + w) * k) / (1 + 4 * k), c.a); }\n"
        )
    if anchor in text:
        COPY_METAL_PATH.write_text(text.replace(anchor, anchor + addition, 1), encoding="utf-8")
        print("[REPAIRED] dm/gfx/msl/copy.metal (restored fsq / fsh)")
        return []
    # Resilient regex fallback matching fragment float4 fs(...) { ... return t.sample(...); }
    m = re.search(r'(fragment\s+float4\s+fs\s*\([^)]*\)\s*\{[\s\S]*?return\s+t\.sample\([^;]*\);\s*\})', text)
    if m:
        full_anchor = m.group(1)
        COPY_METAL_PATH.write_text(text.replace(full_anchor, full_anchor + addition, 1), encoding="utf-8")
        print("[REPAIRED] dm/gfx/msl/copy.metal (via regex pattern)")
        return []
    return ["dm/gfx/msl/copy.metal anchor not found for fsq / fsh restoration"]


def patch_game_tsv(apply: bool) -> list[str]:
    if not GAME_TSV_PATH.is_file():
        return ["missing dm/games/0400486024DEC000/game.tsv"]
    text = GAME_TSV_PATH.read_text(encoding="utf-8", errors="replace")
    required_kv = [
        ("mem_reserve", "0x468000000"),
        ("mem_alias", "0x200000000"),
        ("present_snap", "on"),
        ("frame_wg", "off"),
        ("res_presets", "on"),
        ("pool_skip_retired", "on"),
        ("tex_release", "1"),
        ("rt_lossy", "on"),
        ("pso_mtl4", "on"),
        ("op_mode", "handheld"),
        ("pad_layout", "full"),
        (
            "upscaler_chain",
            "f8965bffbdf51d78,d17eefaff4f0bc23,a335c1db6270c355>aad7ea7e5c02f41d|b106afba1a18faa9|fa3033d05c0a41d6|04135bb812a0d66e|8df148d58b7cbe8e",
        ),
        ("render_cond", "on"),
        ("draw_barriers", "game"),
        ("tex_flush_upload", "on"),
        ("tex_dirty_upload", "on"),
        (
            "shader_groups",
            "/Shader/=shader /Effect/=effect /Lib/=lib /Layout2Shader/=layout /Layout/=layout /UI/=layout /Movie/=movie",
        ),
    ]
    lines = text.splitlines()
    present: dict[str, str] = {}
    for ln in lines:
        s = ln.strip()
        if not s or s.startswith("#") or "\t" not in s:
            continue
        k, v = s.split("\t", 1)
        present[k] = v

    missing = [(k, v) for k, v in required_kv if present.get(k) != v]
    has_sub = any(ln.startswith("romfs_substitute\t") for ln in lines)
    if not missing and has_sub:
        return []
    if not apply:
        errs = [f"dm/games/0400486024DEC000/game.tsv expects {k}={v} (got {present.get(k)!r})" for k, v in missing]
        if not has_sub:
            errs.append("dm/games/0400486024DEC000/game.tsv missing romfs_substitute")
        return errs

    kv_map = dict(required_kv)
    new_lines: list[str] = []
    seen_keys: set[str] = set()
    for ln in lines:
        s = ln.strip()
        if s and not s.startswith("#") and "\t" in s:
            k, _ = s.split("\t", 1)
            if k in kv_map:
                if k not in seen_keys:
                    new_lines.append(f"{k}\t{kv_map[k]}")
                    seen_keys.add(k)
                continue
        new_lines.append(ln)

    extras = [f"{k}\t{v}" for k, v in required_kv if k not in seen_keys]
    if not has_sub:
        extras.append(
            "romfs_substitute\tPack/Bootup.Nin_Ounce_NVN2.pack.zs="
            "3fc3ee760f8f7958b33c699d318d8d8ef57fd59394412369c25da6f377bf8ba5:"
            "be2c07a03c1b7f82f4e18cdbcbbbf6c3b659348148d7e8173c864e6f2964f06b"
        )
    if extras:
        new_lines.append("")
        new_lines.append("# ---- Restored OoT Optimizations (apply_oot_patches.py) ----")
        new_lines.extend(extras)

    GAME_TSV_PATH.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    print("[REPAIRED] dm/games/0400486024DEC000/game.tsv")
    return []


def patch_patches_py(apply: bool) -> list[str]:
    if not PATCHES_PY_PATH.is_file():
        return ["missing dm/games/0400486024DEC000/patches.py"]
    text = PATCHES_PY_PATH.read_text(encoding="utf-8", errors="replace")
    required = [
        "def render_scale(ctx):",
        "def motion_blur(ctx):",
        "'FIXED_RESOLUTION'",
        "'dynamic resolution': 0x8065e0",
        "'dynamic resolution update': 0x805aa0",
        "def v131072(ctx):",
        "FRAME_STEP",
        "MATCH_FRAME_STEP",
    ]
    missing = [tok for tok in required if tok not in text]
    if not missing:
        return []
    _ = apply
    return [f"dm/games/0400486024DEC000/patches.py missing protected symbol: {tok}" for tok in missing]


NVN_MTL_HOOK_RULES: list[tuple] = [
    (
        "top_include",
        '#include "oot_enhancements.inc"',
        '#include "game_profile.h"   // game profile constants (profile id, the profile\'s switches)',
        '#include "game_profile.h"   // game profile constants (profile id, the profile\'s switches)\n'
        '#define OOT_ENH_TOP\n#include "oot_enhancements.inc"',
    ),
    (
        "present_args_tex2",
        "pad.maxTextureBindCount = 2;",
        "    MTL4ArgumentTableDescriptor *pad = [MTL4ArgumentTableDescriptor new];\n"
        "    pad.maxTextureBindCount = 1; pad.maxSamplerStateBindCount = 1; pad.maxBufferBindCount = 1;",
        "    MTL4ArgumentTableDescriptor *pad = [MTL4ArgumentTableDescriptor new];\n"
        "    pad.maxTextureBindCount = 2; pad.maxSamplerStateBindCount = 1; pad.maxBufferBindCount = 1;",
    ),
    (
        "mtl_pool_del",
        "if (is_oot_game()) rel_pool_gone(mem);",
        "void mtl_pool_del(const void *mem) {\n    reg_bump(-1, REG_POOL);",
        "void mtl_pool_del(const void *mem) {\n    reg_bump(-1, REG_POOL);\n    if (is_oot_game()) rel_pool_gone(mem);",
    ),
    (
        "rc_note",
        "if (kind == 2 && is_oot_game() && cond_conservative()) kind = 3;",
        "static void rc_note(uint64_t addr, int kind) {\n    rc_report *r=rc_ensure(addr);",
        "static void rc_note(uint64_t addr, int kind) {\n    if (kind == 2 && is_oot_game() && cond_conservative()) kind = 3;\n    rc_report *r=rc_ensure(addr);",
    ),
    (
        "mem_include",
        "#define OOT_ENH_MEM",
        "static void up_diag(void);\nstatic void up_flush(void) {",
        "#define OOT_ENH_MEM\n#include \"oot_enhancements.inc\"\nstatic void up_diag(void);\nstatic void up_flush(void) {",
    ),
    (
        "up_flush_copy",
        "g_up_tc_src",
        [
            (
                "    id<MTL4ComputeCommandEncoder> b = g_nup_blits ? g_up_ce = [g_up_cb computeCommandEncoder] : nil;\n"
                "    if (b) [b barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];\n"
                "    id<MTLTexture> from = nil;\n"
                "    for (int i = 0; b && i < g_nup_blits; i++) {\n"
                "        up_blit *x = &g_up_blits[i];\n"
                "        if (!x->tsrc) { enc_b_copy_buffer_texture(b, x->src, x->off, x->row, x->image, x->size, x->dst, x->slice, x->level, x->at); continue; }\n"
                "        // The source may be the target of this encoder's earlier copies (a texture uploaded and replaced within one batch)\n"
                "        if (x->tsrc != from) { from = x->tsrc; [b barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice]; }\n"
                "        enc_b_copy_texture(b, x->tsrc, x->slice, x->level, MTLOriginMake(0, 0, 0), x->size, x->dst, x->slice, x->level, MTLOriginMake(0, 0, 0));\n"
                "    }",
                "    id<MTL4ComputeCommandEncoder> b = (g_nup_blits || (is_oot_game() && g_up_tc_dst.count)) ? g_up_ce = [g_up_cb computeCommandEncoder] : nil;\n"
                "    if (b) [b barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];\n"
                "    id<MTLTexture> from = nil;\n"
                "    for (int i = 0; b && i < g_nup_blits; i++) {\n"
                "        up_blit *x = &g_up_blits[i];\n"
                "        if (!x->tsrc) { enc_b_copy_buffer_texture(b, x->src, x->off, x->row, x->image, x->size, x->dst, x->slice, x->level, x->at); continue; }\n"
                "        // The source may be the target of this encoder's earlier copies (a texture uploaded and replaced within one batch)\n"
                "        if (x->tsrc != from) { from = x->tsrc; [b barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice]; }\n"
                "        enc_b_copy_texture(b, x->tsrc, x->slice, x->level, MTLOriginMake(0, 0, 0), x->size, x->dst, x->slice, x->level, MTLOriginMake(0, 0, 0));\n"
                "    }\n"
                "    if (is_oot_game()) for (NSUInteger i = 0; b && i < g_up_tc_dst.count; i++) [b copyFromTexture:g_up_tc_src[i] toTexture:g_up_tc_dst[i]];\n"
                "    NSArray *tc_keep = g_up_tc_src; g_up_tc_src = g_up_tc_dst = nil;",
            ),
            (
                "    id<MTL4ComputeCommandEncoder> b = g_nup_blits ? g_up_ce = [g_up_cb computeCommandEncoder] : nil;\n"
                "    if (b) [b barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];\n"
                "    for (int i = 0; b && i < g_nup_blits; i++) {\n"
                "        up_blit *x = &g_up_blits[i];\n"
                "        enc_b_copy_buffer_texture(b, x->src, x->off, x->row, x->image, x->size, x->dst, x->slice, x->level, x->at);\n"
                "    }",
                "    id<MTL4ComputeCommandEncoder> b = (g_nup_blits || (is_oot_game() && g_up_tc_dst.count)) ? g_up_ce = [g_up_cb computeCommandEncoder] : nil;\n"
                "    if (b) [b barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];\n"
                "    for (int i = 0; b && i < g_nup_blits; i++) {\n"
                "        up_blit *x = &g_up_blits[i];\n"
                "        enc_b_copy_buffer_texture(b, x->src, x->off, x->row, x->image, x->size, x->dst, x->slice, x->level, x->at);\n"
                "    }\n"
                "    if (is_oot_game()) for (NSUInteger i = 0; b && i < g_up_tc_dst.count; i++) [b copyFromTexture:g_up_tc_src[i] toTexture:g_up_tc_dst[i]];\n"
                "    NSArray *tc_keep = g_up_tc_src; g_up_tc_src = g_up_tc_dst = nil;",
            ),
        ],
    ),
    (
        "up_flush_rel",
        "rel_run(relbid, f.error != nil)",
        "    MTL4CommitOptions *o = [MTL4CommitOptions new];\n"
        "    atomic_fetch_add(&g_up_pending, 1);\n"
        "    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {\n",
        "    uint64_t relbid = is_oot_game() ? rel_close() : 0;\n"
        "    MTL4CommitOptions *o = [MTL4CommitOptions new];\n"
        "    atomic_fetch_add(&g_up_pending, 1);\n"
        "    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {\n"
        "        (void)tc_keep;\n"
        "        if (relbid) rel_run(relbid, f.error != nil);\n",
    ),
    (
        "pkg_upload_donor",
        "rel_donor(t, mt)",
        "    int sparse = t->pool && nvn_sparse_pool(t->pool);\n"
        "    if (stamp) {   // no stamp: a one-time upload of content the CPU will not change (tex_init_fill), with no write tracking\n"
        "        *stamp = nvn_dirty_now();\n"
        "        if (sparse) nvn_sparse_protect(t->pool, (uint64_t)(uintptr_t)t->mem, t->L.size); else nvn_dirty_protect(t->mem, t->L.size); }",
        "    int sparse = t->pool && nvn_sparse_pool(t->pool);\n"
        "    if (stamp) {   // no stamp: a one-time upload of content the CPU will not change (tex_init_fill), with no write tracking\n"
        "        *stamp = nvn_dirty_now();\n"
        "        if (sparse) nvn_sparse_protect(t->pool, (uint64_t)(uintptr_t)t->mem, t->L.size); else nvn_dirty_protect(t->mem, t->L.size); }\n"
        "    if (is_oot_game() && stamp && !sparse && !rb_shift && !linear) {\n"
        "        id<MTLTexture> dt = rel_donor(t, mt);\n"
        "        if (dt) {\n"
        "            up_begin();\n"
        "            if (!g_up_tc_src) { g_up_tc_src = [NSMutableArray array]; g_up_tc_dst = [NSMutableArray array]; }\n"
        "            [g_up_tc_src addObject:dt]; [g_up_tc_dst addObject:mt]; [g_up_texs addObject:mt];\n"
        "            if (!g_cb) up_flush();\n"
        "            return mt;\n"
        "        }\n"
        "    }",
    ),
    (
        "pkg_upload_direct",
        "if(is_oot_game())rel_push(t, stamp != NULL);",
        "                if(ok){[g_up_texs addObject:mt];g_direct_uploads++;if(!g_cb)up_flush();return mt;}",
        "                if(ok){[g_up_texs addObject:mt];g_direct_uploads++;if(is_oot_game())rel_push(t, stamp != NULL);if(!g_cb)up_flush();return mt;}",
    ),
    (
        "pkg_upload_enc_ok",
        "        if (enc_ok) {\n            [g_up_texs addObject:mt];\n            if (is_oot_game()) rel_push(t, stamp != NULL);",
        [
            (
                "        if (enc_ok) {\n            [g_up_texs addObject:mt];\n            if (!g_cb) up_flush();\n            free(need);\n            return mt;\n        }",
                "        if (enc_ok) {\n            [g_up_texs addObject:mt];\n            if (is_oot_game()) rel_push(t, stamp != NULL);\n            if (!g_cb) up_flush();\n            free(need);\n            return mt;\n        }",
            ),
            (
                "        if (enc_ok) {\n            [g_up_texs addObject:mt];\n            if (!g_cb) up_flush();\n            return mt;\n        }",
                "        if (enc_ok) {\n            [g_up_texs addObject:mt];\n            if (is_oot_game()) rel_push(t, stamp != NULL);\n            if (!g_cb) up_flush();\n            return mt;\n        }",
            ),
        ],
    ),
    (
        "pkg_upload_cpu",
        "    if (is_oot_game()) rel_push(t, stamp != NULL);\n    up_flush();",
        [
            (
                "    free(part); free(need);\n    up_flush();",
                "    free(part); free(need);\n    if (is_oot_game()) rel_push(t, stamp != NULL);\n    up_flush();",
            ),
            (
                "    free(part);\n    up_flush();",
                "    free(part);\n    if (is_oot_game()) rel_push(t, stamp != NULL);\n    up_flush();",
            ),
        ],
    ),
    (
        "tex_mtl_lossy",
        "if (is_oot_game()) rt_lossy(d);",
        "        mt = image_texture(t, d);\n"
        "        if (!mt) { mt = rh_texture(t, d); if (!mt) mt = [g_dev newTextureWithDescriptor:d];\n"
        "            if (mt) { res_add(mt); if (!tex_init_fill(t, mt)) tex_zero_fill(mt); } }",
        "        mt = image_texture(t, d);\n"
        "        if (!mt) {\n"
        "            mt = rh_texture(t, d);\n"
        "            if (!mt) {\n"
        "                if (is_oot_game()) rt_lossy(d);\n"
        "                mt = [g_dev newTextureWithDescriptor:d];\n"
        "                if (!mt && is_oot_game() && d.compressionType == MTLTextureCompressionTypeLossy) {\n"
        "                    d.compressionType = MTLTextureCompressionTypeLossless;\n"
        "                    mt = [g_dev newTextureWithDescriptor:d];\n"
        "                }\n"
        "            }\n"
        "            if (mt) { res_add(mt); if (!tex_init_fill(t, mt)) tex_zero_fill(mt); }\n"
        "        }",
    ),
    (
        "tex_mtl_rel",
        "if (mt) filled = 1;",
        [
            (
                "    id<MTLTexture> mt = tex_linear(t); int tu = 0;\n"
                "    if (!mt && t->pool && nvn_sparse_pool(t->pool)) mt = sparse_gpu_make(t);",
                "    int filled = 0;\n"
                "    id<MTLTexture> mt = tex_linear(t); int tu = 0;\n"
                "    if (mt) filled = 1;\n"
                "    if (!mt && t->pool && nvn_sparse_pool(t->pool)) { mt = sparse_gpu_make(t); if (mt) filled = 1; }",
            ),
            (
                "    id<MTLTexture> mt = tex_linear(t);\n"
                "    if (!mt && t->pool && nvn_sparse_pool(t->pool)) mt = sparse_gpu_make(t);",
                "    int filled = 0;\n"
                "    id<MTLTexture> mt = tex_linear(t);\n"
                "    if (mt) filled = 1;\n"
                "    if (!mt && t->pool && nvn_sparse_pool(t->pool)) { mt = sparse_gpu_make(t); if (mt) filled = 1; }",
            ),
        ],
    ),
    (
        "tex_mtl_rel_push",
        "if (is_oot_game() && !filled && t->pool",
        [
            (
                "    id<MTLTexture> got = own_alias_publish(t->serial, &ak, mt);\n"
                "    if (got != mt) { static int nrace; if (nrace++ < 4) MLOG(\"texture ser=%llu made twice over one storage: the first one registered is shared (%d so far)\", (unsigned long long)t->serial, nrace); defer_obj_release(mt); }\n"
                "    else if (tu) tu_register(mt, t->serial);\n"
                "    return got;\n"
                "}\n"
                "// Memory readout line",
                "    if (is_oot_game() && !filled && t->pool && (t->pool->flags & NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS) && t->d.target != NVN_TEXTURE_TARGET_BUFFER) {\n"
                "        rel_push(t, 0);\n"
                "    }\n"
                "    id<MTLTexture> got = own_alias_publish(t->serial, &ak, mt);\n"
                "    if (got != mt) { static int nrace; if (nrace++ < 4) MLOG(\"texture ser=%llu made twice over one storage: the first one registered is shared (%d so far)\", (unsigned long long)t->serial, nrace); defer_obj_release(mt); }\n"
                "    else if (tu) tu_register(mt, t->serial);\n"
                "    return got;\n"
                "}\n"
                "// Memory readout line",
            ),
            (
                "    id<MTLTexture> got = own_alias_publish(t->serial, &ak, mt);\n"
                "    if (got != mt) { static int nrace; if (nrace++ < 4) MLOG(\"texture ser=%llu made twice over one storage: the first one registered is shared (%d so far)\", (unsigned long long)t->serial, nrace); defer_obj_release(mt); }\n"
                "    return got;\n"
                "}\n"
                "// Memory readout line",
                "    if (is_oot_game() && !filled && t->pool && (t->pool->flags & NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS) && t->d.target != NVN_TEXTURE_TARGET_BUFFER) {\n"
                "        rel_push(t, 0);\n"
                "    }\n"
                "    id<MTLTexture> got = own_alias_publish(t->serial, &ak, mt);\n"
                "    if (got != mt) { static int nrace; if (nrace++ < 4) MLOG(\"texture ser=%llu made twice over one storage: the first one registered is shared (%d so far)\", (unsigned long long)t->serial, nrace); defer_obj_release(mt); }\n"
                "    return got;\n"
                "}\n"
                "// Memory readout line",
            ),
            (
                "    tex_put(t->serial, mt);\n    return mt;\n}\n// Memory readout line",
                "    if (is_oot_game() && !filled && t->pool && (t->pool->flags & NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS) && t->d.target != NVN_TEXTURE_TARGET_BUFFER) {\n"
                "        rel_push(t, 0);\n"
                "    }\n"
                "    tex_put(t->serial, mt);\n    return mt;\n}\n// Memory readout line",
            ),
        ],
    ),
    (
        "pool_seen_scan_skip",
        "is_oot_game() && pool_skip_retired()) { g_seen_todo[i] &= ~(1u << b); continue; }",
        "            g_seen_todo[i] &= ~(1u << b);\n            void *tv = NULL; uint64_t tr = tex_fast_rid(id_, &tv); if (!tv || !tr) continue;",
        "            if (g_treg[id_].retired && !g_treg[id_].transient_sub && !g_treg[id_].view && is_oot_game() && pool_skip_retired()) { g_seen_todo[i] &= ~(1u << b); continue; }\n"
        "            g_seen_todo[i] &= ~(1u << b);\n            void *tv = NULL; uint64_t tr = tex_fast_rid(id_, &tv); if (!tv || !tr) continue;",
    ),
    (
        "pool_entry_skip",
        "if (r->retired && !r->transient_sub && !r->view && is_oot_game() && pool_skip_retired()) return 0;",
        "    const treg_t *r = &g_treg[id_];\n    if (r->gone) { ++*gone; return 0; }",
        "    const treg_t *r = &g_treg[id_];\n    if (r->gone) { ++*gone; return 0; }\n"
        "    if (r->retired && !r->transient_sub && !r->view && is_oot_game() && pool_skip_retired()) return 0;",
    ),
    (
        "fb_prepare_dself",
        "!(is_oot_game() && S.ds.dt && S.ds.dw && fb_dself())",
        "if (R.rt.n && R.rt.depth && !g_fb_dread && ((fs->rf.pool && pool_ds_read(R.rt.depth) && (g_fb_dread_pool = 1)) || fs->rf.dyn)) g_fb_dread = 1;",
        "if (R.rt.n && R.rt.depth && !g_fb_dread && ((fs->rf.pool && pool_ds_read(R.rt.depth) && (g_fb_dread_pool = 1)) || fs->rf.dyn) && !(is_oot_game() && S.ds.dt && S.ds.dw && fb_dself())) g_fb_dread = 1;",
    ),
    (
        "upchain_include",
        "#define OOT_ENH_UPCHAIN",
        "    if (ndve_engine_dispatch(cs, dp)) return;   // nn::ndve's movie network as the host's kernels (DM_NDVE_ENGINE=1)\n"
        "    if (up_mfx_wanted(cs) && !dp->ind && up_mfx_encode(cs)) return;   // the game's upscaler, drawn by MetalFX instead (DM_UPSCALER=metalfx)",
        "    if (ndve_engine_dispatch(cs, dp)) return;   // nn::ndve's movie network as the host's kernels (DM_NDVE_ENGINE=1)\n"
        "    if (is_oot_game() && oot_up_chain_dispatch(cs, dp)) return;\n"
        "    if (up_mfx_wanted(cs) && !dp->ind && up_mfx_encode(cs)) return;   // the game's upscaler, drawn by MetalFX instead (DM_UPSCALER=metalfx)",
    ),
    (
        "upchain_include_top",
        '#define OOT_ENH_UPCHAIN\n#include "oot_enhancements.inc"',
        "static id<MTL4ComputeCommandEncoder> dispatch_enc(void) {",
        '#define OOT_ENH_UPCHAIN\n#include "oot_enhancements.inc"\nstatic id<MTL4ComputeCommandEncoder> dispatch_enc(void) {',
    ),
    (
        "copy_t2t_draw_x",
        ("static int copy_t2t_draw_x(", "static inline int copy_t2t_draw_x("),
        "static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror) {\n"
        "    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *pso; static id<MTLFunction> vf, ff, fd, fds; static id<MTLSamplerState> samp[2]; static id<MTL4ArgumentTable> at; static id<MTLDepthStencilState> dss, dss_s; static int failed;\n"
        "    if (failed || sr->width <= 0 || sr->height <= 0 || dr->width <= 0 || dr->height <= 0) return 0;\n"
        "    int depth = (s.pixelFormat == MTLPixelFormatDepth32Float || s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 || s.pixelFormat == MTLPixelFormatDepth16Unorm) && d.pixelFormat == s.pixelFormat, stencil = depth && d.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;\n"
        "    if (!depth && (fmt_int_or_ds(s.pixelFormat) || fmt_int_or_ds(d.pixelFormat))) return 0;\n"
        "    if (mtl_fmt_block(d.pixelFormat) || !(d.usage & MTLTextureUsageRenderTarget) || s.sampleCount > 1 || d.sampleCount > 1) return 0;\n"
        "    if (!pso) {\n"
        "        NSError *e = nil; id<MTLLibrary> lib = host_lib(\"copy\", &e);\n"
        "        vf = [lib newFunctionWithName:@\"vs\"]; ff = [lib newFunctionWithName:@\"fs\"]; fd = [lib newFunctionWithName:@\"fsd\"]; fds = [lib newFunctionWithName:@\"fsds\"];\n"
        "        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; dss = [g_dev newDepthStencilStateWithDescriptor:dd];\n"
        "        MTLStencilDescriptor *sd_ = [MTLStencilDescriptor new]; sd_.stencilCompareFunction = MTLCompareFunctionAlways; sd_.depthStencilPassOperation = MTLStencilOperationReplace;   // Replace writes the [[stencil]] output\n"
        "        dd.frontFaceStencil = dd.backFaceStencil = sd_; dss_s = [g_dev newDepthStencilStateWithDescriptor:dd];\n"
        "        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount = 2; ad.maxSamplerStateBindCount = 1; ad.maxBufferBindCount = 1; at = rec_table([g_dev newArgumentTableWithDescriptor:ad error:&e]);\n"
        "        for (int i = 0; i < 2; i++) { MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = i ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;\n"
        "            sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge; sd.supportArgumentBuffers = YES; samp[i] = [g_dev newSamplerStateWithDescriptor:sd]; }\n"
        "        if (!vf || !ff || !fd || !fds || !dss || !dss_s || !at || !samp[0] || !samp[1]) { failed = 1; MLOG(\"[RED] cannot create the pipelines for format-converting / scaling texture copies: %s\", e.localizedDescription.UTF8String); return 0; }\n"
        "        pso = [NSMutableDictionary dictionary];\n"
        "    }\n"
        "    // Stencil: read through a stencil-only view of the source (one per layer below); without one it is cleared to 0\n"
        "    id<MTLTexture> stv0 = stencil && s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? [s newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8 textureType:MTLTextureType2D levels:NSMakeRange(sl, 1) slices:NSMakeRange(ss + sr->zoffset, 1)] : nil;\n"
        "    int scopy = stv0 != nil;\n"
        "    NSNumber *pk = @(d.pixelFormat * 2 + scopy);\n"
        "    id<MTLRenderPipelineState> ps = pso[pk];\n"
        "    if (!ps) {\n"
        "        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = vf; pd.fragmentFunction = depth ? (scopy ? fds : fd) : ff;\n"
        "        if (depth) { pd.depthAttachmentPixelFormat = d.pixelFormat; if (stencil) pd.stencilAttachmentPixelFormat = d.pixelFormat; } else pd.colorAttachments[0].pixelFormat = d.pixelFormat;\n"
        "        NSError *e = nil; ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];\n"
        "        if (!ps) { RED_ONCE(83, \"format-converting / scaling texture copy: cannot create the pipeline for destination format %lu: %s\", (unsigned long)d.pixelFormat, e.localizedDescription.UTF8String); return 0; }\n"
        "        pso[pk] = ps;\n"
        "    }\n"
        "    unsigned sw = MAX(s.width >> sl, 1ul), sh = MAX(s.height >> sl, 1ul), dw = MAX(d.width >> dl, 1ul), dh = MAX(d.height >> dl, 1ul);\n"
        "    if ((unsigned)(dr->xoffset + dr->width) > dw || (unsigned)(dr->yoffset + dr->height) > dh) return 0;\n"
        "    int nz = sr->depth ? sr->depth : 1;\n"
        "    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }\n"
        "    for (int z = 0; z < nz; z++) {\n"
        "        id<MTLTexture> sv = [s newTextureViewWithPixelFormat:s.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(sl, 1) slices:NSMakeRange(ss + sr->zoffset + z, 1)];\n"
        "        id<MTLBuffer> pb; size_t po = arena_alloc(32, &pb);   // parameters in the frame arena (resident already): a fresh 32-byte buffer per copy was a residency add, a commit and a release (Link's Awakening, about 11 a frame)\n"
        "        if (!sv || !pb) { RED_ONCE(84, \"format-converting / scaling texture copy: cannot create the source view / argument block\"); return z > 0; }\n"
        "        float *p = (float *)((uint8_t *)pb.contents + po); p[0] = sr->xoffset; p[1] = sr->yoffset; p[2] = (float)sr->width / dr->width; p[3] = (float)sr->height / dr->height;\n"
        "        if (mirror & NVN_COPY_FLAGS_MIRROR_X_BIT) { p[0] += sr->width; p[2] = -p[2]; }   // mirrored: walk the source region from its far edge\n"
        "        if (mirror & NVN_COPY_FLAGS_MIRROR_Y_BIT) { p[1] += sr->height; p[3] = -p[3]; }\n"
        "        p[4] = dr->xoffset; p[5] = dr->yoffset; p[6] = sw; p[7] = sh;",
        "static int copy_t2t_draw_x(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror, int square, float sharpen) {\n"
        "    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *pso; static id<MTLFunction> vf, ff, fq, fsh, fd, fds; static id<MTLSamplerState> samp[2]; static id<MTL4ArgumentTable> at; static id<MTLDepthStencilState> dss, dss_s; static int failed;\n"
        "    if (failed || sr->width <= 0 || sr->height <= 0 || dr->width <= 0 || dr->height <= 0) return 0;\n"
        "    int sharp = sharpen > 0;\n"
        "    int depth = (s.pixelFormat == MTLPixelFormatDepth32Float || s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 || s.pixelFormat == MTLPixelFormatDepth16Unorm) && d.pixelFormat == s.pixelFormat, stencil = depth && d.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;\n"
        "    if (!depth && (fmt_int_or_ds(s.pixelFormat) || fmt_int_or_ds(d.pixelFormat))) return 0;\n"
        "    if (mtl_fmt_block(d.pixelFormat) || !(d.usage & MTLTextureUsageRenderTarget) || s.sampleCount > 1 || d.sampleCount > 1) return 0;\n"
        "    if (!pso) {\n"
        "        NSError *e = nil; id<MTLLibrary> lib = host_lib(\"copy\", &e);\n"
        "        vf = [lib newFunctionWithName:@\"vs\"]; ff = [lib newFunctionWithName:@\"fs\"]; fq = [lib newFunctionWithName:@\"fsq\"]; fsh = [lib newFunctionWithName:@\"fsh\"]; fd = [lib newFunctionWithName:@\"fsd\"]; fds = [lib newFunctionWithName:@\"fsds\"];\n"
        "        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; dss = [g_dev newDepthStencilStateWithDescriptor:dd];\n"
        "        MTLStencilDescriptor *sd_ = [MTLStencilDescriptor new]; sd_.stencilCompareFunction = MTLCompareFunctionAlways; sd_.depthStencilPassOperation = MTLStencilOperationReplace;   // Replace writes the [[stencil]] output\n"
        "        dd.frontFaceStencil = dd.backFaceStencil = sd_; dss_s = [g_dev newDepthStencilStateWithDescriptor:dd];\n"
        "        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount = 2; ad.maxSamplerStateBindCount = 1; ad.maxBufferBindCount = 1; at = rec_table([g_dev newArgumentTableWithDescriptor:ad error:&e]);\n"
        "        for (int i = 0; i < 2; i++) { MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = i ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;\n"
        "            sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge; sd.supportArgumentBuffers = YES; samp[i] = [g_dev newSamplerStateWithDescriptor:sd]; }\n"
        "        if (!vf || !ff || !fq || !fsh || !fd || !fds || !dss || !dss_s || !at || !samp[0] || !samp[1]) { failed = 1; MLOG(\"[RED] cannot create the pipelines for format-converting / scaling texture copies: %s\", e.localizedDescription.UTF8String); return 0; }\n"
        "        pso = [NSMutableDictionary dictionary];\n"
        "    }\n"
        "    // Stencil: read through a stencil-only view of the source (one per layer below); without one it is cleared to 0\n"
        "    id<MTLTexture> stv0 = stencil && s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? [s newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8 textureType:MTLTextureType2D levels:NSMakeRange(sl, 1) slices:NSMakeRange(ss + sr->zoffset, 1)] : nil;\n"
        "    int scopy = stv0 != nil;\n"
        "    NSNumber *pk = @(d.pixelFormat * 8 + scopy + (depth ? 0 : sharp ? 4 : square ? 2 : 0));\n"
        "    id<MTLRenderPipelineState> ps = pso[pk];\n"
        "    if (!ps) {\n"
        "        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = vf; pd.fragmentFunction = depth ? (scopy ? fds : fd) : sharp ? fsh : square ? fq : ff;\n"
        "        if (depth) { pd.depthAttachmentPixelFormat = d.pixelFormat; if (stencil) pd.stencilAttachmentPixelFormat = d.pixelFormat; } else pd.colorAttachments[0].pixelFormat = d.pixelFormat;\n"
        "        NSError *e = nil; ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];\n"
        "        if (!ps) { RED_ONCE(83, \"format-converting / scaling texture copy: cannot create the pipeline for destination format %lu: %s\", (unsigned long)d.pixelFormat, e.localizedDescription.UTF8String); return 0; }\n"
        "        pso[pk] = ps;\n"
        "    }\n"
        "    unsigned sw = MAX(s.width >> sl, 1ul), sh = MAX(s.height >> sl, 1ul), dw = MAX(d.width >> dl, 1ul), dh = MAX(d.height >> dl, 1ul);\n"
        "    if ((unsigned)(dr->xoffset + dr->width) > dw || (unsigned)(dr->yoffset + dr->height) > dh) return 0;\n"
        "    int nz = sr->depth ? sr->depth : 1;\n"
        "    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }\n"
        "    for (int z = 0; z < nz; z++) {\n"
        "        id<MTLTexture> sv = [s newTextureViewWithPixelFormat:s.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(sl, 1) slices:NSMakeRange(ss + sr->zoffset + z, 1)];\n"
        "        id<MTLBuffer> pb; size_t po = arena_alloc(48, &pb);   // parameters in the frame arena (resident already): a fresh 32-byte buffer per copy was a residency add, a commit and a release (Link's Awakening, about 11 a frame)\n"
        "        if (!sv || !pb) { RED_ONCE(84, \"format-converting / scaling texture copy: cannot create the source view / argument block\"); return z > 0; }\n"
        "        float *p = (float *)((uint8_t *)pb.contents + po); p[0] = sr->xoffset; p[1] = sr->yoffset; p[2] = (float)sr->width / dr->width; p[3] = (float)sr->height / dr->height;\n"
        "        if (mirror & NVN_COPY_FLAGS_MIRROR_X_BIT) { p[0] += sr->width; p[2] = -p[2]; }   // mirrored: walk the source region from its far edge\n"
        "        if (mirror & NVN_COPY_FLAGS_MIRROR_Y_BIT) { p[1] += sr->height; p[3] = -p[3]; }\n"
        "        p[4] = dr->xoffset; p[5] = dr->yoffset; p[6] = sw; p[7] = sh; p[8] = sharpen; p[9] = p[10] = p[11] = 0;",
    ),
    (
        "copy_t2t_draw_wrappers",
        ("static int copy_t2t_draw_sq(", "static inline int copy_t2t_draw_sq("),
        '    { static int once[2]; if (!once[depth]++) MLOG("format-converting / scaling texture copy: first case %dx%d format %lu → %dx%d format %lu%s%s", sr->width, sr->height, (unsigned long)s.pixelFormat, dr->width, dr->height, (unsigned long)d.pixelFormat,\n'
        '                                                    linear && !depth ? " (bilinear)" : "", stencil ? (scopy ? " (depth + stencil)" : " (no stencil view possible, cleared to 0)") : ""); }\n'
        '    return 1;\n}',
        '    { static int once[2]; if (!once[depth]++) MLOG("format-converting / scaling texture copy: first case %dx%d format %lu → %dx%d format %lu%s%s", sr->width, sr->height, (unsigned long)s.pixelFormat, dr->width, dr->height, (unsigned long)d.pixelFormat,\n'
        '                                                    linear && !depth ? " (bilinear)" : "", stencil ? (scopy ? " (depth + stencil)" : " (no stencil view possible, cleared to 0)") : ""); }\n'
        '    return 1;\n}\n'
        'static int copy_t2t_draw_sq(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror, int square) {\n'
        '    return copy_t2t_draw_x(s, d, sl, ss, dl, ds, sr, dr, linear, mirror, square, 0);\n}\n'
        'static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror) {\n'
        '    return copy_t2t_draw_x(s, d, sl, ss, dl, ds, sr, dr, linear, mirror, 0, 0);\n}',
    ),
    (
        "up_mfx_on",
        'DM_UPSCALER=%s: metalfx, off or game',
        '    const char *e = getenv("DM_UPSCALER"); v = e && !strcmp(e, "metalfx");\n'
        '    if (e && *e && strcmp(e, "metalfx") && strcmp(e, "game")) MLOG("[RED] DM_UPSCALER=%s: metalfx or game; keeping the game\'s", e);\n'
        '    if (v && !(g_q4 && [MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev])) { MLOG("upscaler: this GPU has no Metal 4 MetalFX spatial scaler; the game\'s own upscaler draws"); v = 0; }\n'
        '    if (v) MLOG("upscaler (DM_UPSCALER): metalfx, the game\'s upscaler shaders (%d, from the shader map) are drawn by MetalFX\'s spatial scaler", DM_GAME_UPSCALER_N);',
        '    const char *e = getenv("DM_UPSCALER");\n'
        '    if (is_oot_game()) {\n'
        '        v = e && !strcmp(e, "metalfx") ? 1 : e && !strcmp(e, "off") ? 2 : 0;\n'
        '        if (e && *e && strcmp(e, "metalfx") && strcmp(e, "off") && strcmp(e, "game")) MLOG("[RED] DM_UPSCALER=%s: metalfx, off or game; keeping the game\'s", e);\n'
        '        if (v == 1 && !(g_q4 && [MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev])) { MLOG("upscaler: this GPU has no Metal 4 MetalFX spatial scaler; the game\'s own upscaler draws"); v = 0; }\n'
        '        if (v == 1) MLOG("upscaler (DM_UPSCALER): metalfx, the game\'s upscaler shaders (%d, from the shader map) are drawn by MetalFX\'s spatial scaler", DM_GAME_UPSCALER_N);\n'
        '        if (v == 2) MLOG("upscaler (DM_UPSCALER): off, the game\'s upscaler shaders (%d, from the shader map) are skipped (bilinear copy instead)", DM_GAME_UPSCALER_N);\n'
        '        return v;\n'
        '    }\n'
        '    v = e && !strcmp(e, "metalfx");\n'
        '    if (e && *e && strcmp(e, "metalfx") && strcmp(e, "game")) MLOG("[RED] DM_UPSCALER=%s: metalfx or game; keeping the game\'s", e);\n'
        '    if (v && !(g_q4 && [MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev])) { MLOG("upscaler: this GPU has no Metal 4 MetalFX spatial scaler; the game\'s own upscaler draws"); v = 0; }\n'
        '    if (v) MLOG("upscaler (DM_UPSCALER): metalfx, the game\'s upscaler shaders (%d, from the shader map) are drawn by MetalFX\'s spatial scaler", DM_GAME_UPSCALER_N);',
    ),
    (
        "up_mfx_encode_chain_in",
        "if (is_oot_game() && g_up_chain_in && up_chain_role(cs) == 3) tin = g_up_chain_in;",
        "    int tin = (int)(tex_slot_h(S.tex[5], S.img[5], cs->rf.b[ti].reg) & 0xfffff), tout = cs->rf.b[oi].reg < 32 ? (int)(S.img[5][cs->rf.b[oi].reg] & 0xfffff) : 0;",
        "    int tin = (int)(tex_slot_h(S.tex[5], S.img[5], cs->rf.b[ti].reg) & 0xfffff), tout = cs->rf.b[oi].reg < 32 ? (int)(S.img[5][cs->rf.b[oi].reg] & 0xfffff) : 0;\n"
        "    if (is_oot_game() && g_up_chain_in && up_chain_role(cs) == 3) tin = g_up_chain_in;",
    ),
    (
        "up_mfx_encode_off_and_sharpen",
        "if (is_oot_game() && up_mfx_on() == 2) {",
        [
            (
                "    int srgb = cs->up_color == UP_COLOR_SRGB, root = cs->up_color == UP_COLOR_ROOT;\n"
                "    // Each side is the game's own texture when MetalFX can take it as it is: the rectangle is the whole texture (MetalFX reads and writes from the origin) and the format is not sRGB (as the\n"
                "    // copies, which keep its decode). The input in any format MetalFX takes, unless it is square-rooted: only the copy squares it (COPY_T2T_SQUARE). The output, private, only in the\n"
                "    // scaler's own: MetalFX's own writes of R11G11B10F come out about two steps of its mantissa low (2.0 as 1.94, 0.5 as 0.484), where its RGBA16F output drawn back gives 1.98 and 0.496\n"
                "    // (t_upscaler_mfx), so a packed output stays drawn back. sRGB input's output is always the scaler's own, for its decode. Else the scaler's own texture, through a copy\n"
                "    MTLPixelFormat c16 = MTLPixelFormatRGBA16Float, of = srgb ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA16Float;\n"
                "    int whole_in = !root && !ir.xoffset && !ir.yoffset && (NSUInteger)ir.width == in.width && (NSUInteger)ir.height == in.height && pf_srgb_linear(in.pixelFormat) == MTLPixelFormatInvalid && !mtl_fmt_block(in.pixelFormat);\n"
                "    int whole_out = !srgb && !orr.xoffset && !orr.yoffset && (NSUInteger)orr.width == out.width && (NSUInteger)orr.height == out.height && out.storageMode == MTLStorageModePrivate && out.pixelFormat == of;",
                "    int srgb = cs->up_color == UP_COLOR_SRGB && !(is_oot_game() && g_up_chain_in && up_chain_role(cs) == 3), root = cs->up_color == UP_COLOR_ROOT;\n"
                "    float sharpen = is_oot_game() ? up_sharpen() : 0.0f;\n"
                "    if (is_oot_game() && up_mfx_on() == 2) {\n"
                "        if (!(out.usage & MTLTextureUsageRenderTarget)) { g_up_mfx_kept++; return 0; }\n"
                "        rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }\n"
                "        ubd_land_compute();\n"
                "        int copied = 0;\n"
                "        if (sharpen > 0) {\n"
                "            id<MTLTexture> sc = up_scratch((NSUInteger)orr.width, (NSUInteger)orr.height);\n"
                "            NVNcopyRegion at0o = {0, 0, 0, orr.width, orr.height, 1};\n"
                "            copied = sc && copy_t2t_draw_sq(in, sc, 0, 0, 0, 0, &ir, &at0o, 1, 0, srgb || root)\n"
                "                     && copy_t2t_draw_x(sc, out, 0, 0, 0, 0, &at0o, &orr, 0, 0, 0, sharpen);\n"
                "        } else {\n"
                "            copied = copy_t2t_draw_sq(in, out, 0, 0, 0, 0, &ir, &orr, 1, 0, srgb || root);\n"
                "        }\n"
                "        args_dirty_all();\n"
                "        if (!copied) { g_up_mfx_kept++; return 0; }\n"
                "        if (!g_up_mfx_n++) MLOG(\"upscaler: first dispatch of %s skipped (bilinear%s), %dx%d at %d,%d of %lux%lu (format %lu) → %dx%d at %d,%d of %lux%lu (format %lu)%s\",\n"
                "                                cs->key, sharpen > 0 ? \" + sharpen\" : \"\", ir.width, ir.height, ir.xoffset, ir.yoffset,\n"
                "                                (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat,\n"
                "                                orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width, (unsigned long)out.height,\n"
                "                                (unsigned long)out.pixelFormat, srgb || root ? \", decoded from root\" : \"\");\n"
                "        return 1;\n"
                "    }\n"
                "    // Each side is the game's own texture when MetalFX can take it as it is: the rectangle is the whole texture (MetalFX reads and writes from the origin) and the format is not sRGB (as the\n"
                "    // copies, which keep its decode). The input in any format MetalFX takes, unless it is square-rooted: only the copy squares it (COPY_T2T_SQUARE). The output, private, only in the\n"
                "    // scaler's own: MetalFX's own writes of R11G11B10F come out about two steps of its mantissa low (2.0 as 1.94, 0.5 as 0.484), where its RGBA16F output drawn back gives 1.98 and 0.496\n"
                "    // (t_upscaler_mfx), so a packed output stays drawn back. sRGB input's output is always the scaler's own, for its decode. Else the scaler's own texture, through a copy\n"
                "    MTLPixelFormat c16 = MTLPixelFormatRGBA16Float, of = srgb ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA16Float;\n"
                "    int whole_in = !root && !ir.xoffset && !ir.yoffset && (NSUInteger)ir.width == in.width && (NSUInteger)ir.height == in.height && pf_srgb_linear(in.pixelFormat) == MTLPixelFormatInvalid && !mtl_fmt_block(in.pixelFormat);\n"
                "    int whole_out = !srgb && !orr.xoffset && !orr.yoffset && (NSUInteger)orr.width == out.width && (NSUInteger)orr.height == out.height && out.storageMode == MTLStorageModePrivate && out.pixelFormat == of && (!is_oot_game() || sharpen <= 0);",
            ),
            (
                "    int srgb = cs->up_color == UP_COLOR_SRGB;\n"
                "    // Each side is the game's own texture when MetalFX can take it as it is: the rectangle is the whole texture (MetalFX reads and writes from the origin) and the format is not sRGB (as the\n"
                "    // copies, which keep its decode). The input in any format MetalFX takes; the output, private, only in the scaler's own: MetalFX's own writes of R11G11B10F come out about two steps of its\n"
                "    // mantissa low (2.0 as 1.94, 0.5 as 0.484), where its RGBA16F output drawn back gives 1.98 and 0.496 (t_upscaler_mfx), so a packed output stays drawn back. sRGB input's output is always\n"
                "    // the scaler's own, for its decode. Else the scaler's own texture, through a copy\n"
                "    MTLPixelFormat c16 = MTLPixelFormatRGBA16Float, of = srgb ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA16Float;\n"
                "    int whole_in = !ir.xoffset && !ir.yoffset && (NSUInteger)ir.width == in.width && (NSUInteger)ir.height == in.height && pf_srgb_linear(in.pixelFormat) == MTLPixelFormatInvalid && !mtl_fmt_block(in.pixelFormat);\n"
                "    int whole_out = !srgb && !orr.xoffset && !orr.yoffset && (NSUInteger)orr.width == out.width && (NSUInteger)orr.height == out.height && out.storageMode == MTLStorageModePrivate && out.pixelFormat == of;",
                "    int srgb = cs->up_color == UP_COLOR_SRGB && !(is_oot_game() && g_up_chain_in && up_chain_role(cs) == 3);\n"
                "    float sharpen = is_oot_game() ? up_sharpen() : 0.0f;\n"
                "    if (is_oot_game() && up_mfx_on() == 2) {\n"
                "        if (!(out.usage & MTLTextureUsageRenderTarget)) { g_up_mfx_kept++; return 0; }\n"
                "        rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }\n"
                "        ubd_land_compute();\n"
                "        int copied = 0;\n"
                "        if (sharpen > 0) {\n"
                "            id<MTLTexture> sc = up_scratch((NSUInteger)orr.width, (NSUInteger)orr.height);\n"
                "            NVNcopyRegion at0o = {0, 0, 0, orr.width, orr.height, 1};\n"
                "            copied = sc && copy_t2t_draw_sq(in, sc, 0, 0, 0, 0, &ir, &at0o, 1, 0, srgb)\n"
                "                     && copy_t2t_draw_x(sc, out, 0, 0, 0, 0, &at0o, &orr, 0, 0, 0, sharpen);\n"
                "        } else {\n"
                "            copied = copy_t2t_draw_sq(in, out, 0, 0, 0, 0, &ir, &orr, 1, 0, srgb);\n"
                "        }\n"
                "        args_dirty_all();\n"
                "        if (!copied) { g_up_mfx_kept++; return 0; }\n"
                "        if (!g_up_mfx_n++) MLOG(\"upscaler: first dispatch of %s skipped (bilinear%s), %dx%d at %d,%d of %lux%lu (format %lu) → %dx%d at %d,%d of %lux%lu (format %lu)%s\",\n"
                "                                cs->key, sharpen > 0 ? \" + sharpen\" : \"\", ir.width, ir.height, ir.xoffset, ir.yoffset,\n"
                "                                (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat,\n"
                "                                orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width, (unsigned long)out.height,\n"
                "                                (unsigned long)out.pixelFormat, srgb ? \", decoded from root\" : \"\");\n"
                "        return 1;\n"
                "    }\n"
                "    // Each side is the game's own texture when MetalFX can take it as it is: the rectangle is the whole texture (MetalFX reads and writes from the origin) and the format is not sRGB (as the\n"
                "    // copies, which keep its decode). The input in any format MetalFX takes; the output, private, only in the scaler's own: MetalFX's own writes of R11G11B10F come out about two steps of its\n"
                "    // mantissa low (2.0 as 1.94, 0.5 as 0.484), where its RGBA16F output drawn back gives 1.98 and 0.496 (t_upscaler_mfx), so a packed output stays drawn back. sRGB input's output is always\n"
                "    // the scaler's own, for its decode. Else the scaler's own texture, through a copy\n"
                "    MTLPixelFormat c16 = MTLPixelFormatRGBA16Float, of = srgb ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA16Float;\n"
                "    int whole_in = !ir.xoffset && !ir.yoffset && (NSUInteger)ir.width == in.width && (NSUInteger)ir.height == in.height && pf_srgb_linear(in.pixelFormat) == MTLPixelFormatInvalid && !mtl_fmt_block(in.pixelFormat);\n"
                "    int whole_out = !srgb && !orr.xoffset && !orr.yoffset && (NSUInteger)orr.width == out.width && (NSUInteger)orr.height == out.height && out.storageMode == MTLStorageModePrivate && out.pixelFormat == of && (!is_oot_game() || sharpen <= 0);",
            ),
            (
                "    int srgb = cs->up_color == UP_COLOR_SRGB;\n"
                "    up_mfx_scaler *e = up_mfx_scaler_for((NSUInteger)ir.width, (NSUInteger)ir.height, (NSUInteger)orr.width, (NSUInteger)orr.height, srgb); if (!e) { g_up_mfx_kept++; return 0; }\n"
                "    id<MTL4FXSpatialScaler> sc = e->sc;\n"
                "    // Straight in and out when MetalFX can take the game's textures as they are; through the scaler's own textures otherwise\n"
                "    int direct = !srgb && (NSUInteger)ir.width == in.width && (NSUInteger)ir.height == in.height && out.storageMode == MTLStorageModePrivate &&\n"
                "                 in.pixelFormat == MTLPixelFormatRGBA16Float && out.pixelFormat == MTLPixelFormatRGBA16Float && !ir.xoffset && !ir.yoffset && !orr.xoffset && !orr.yoffset && (NSUInteger)orr.width == out.width &&\n"
                "                 (NSUInteger)orr.height == out.height && (in.usage & sc.colorTextureUsage) == sc.colorTextureUsage && (out.usage & sc.outputTextureUsage) == sc.outputTextureUsage;",
                "    int srgb = cs->up_color == UP_COLOR_SRGB && !(is_oot_game() && g_up_chain_in && up_chain_role(cs) == 3);\n"
                "    float sharpen = is_oot_game() ? up_sharpen() : 0.0f;\n"
                "    if (is_oot_game() && up_mfx_on() == 2) {\n"
                "        if (!(out.usage & MTLTextureUsageRenderTarget)) { g_up_mfx_kept++; return 0; }\n"
                "        rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }\n"
                "        ubd_land_compute();\n"
                "        int copied = 0;\n"
                "        if (sharpen > 0) {\n"
                "            id<MTLTexture> sc = up_scratch((NSUInteger)orr.width, (NSUInteger)orr.height);\n"
                "            NVNcopyRegion at0o = {0, 0, 0, orr.width, orr.height, 1};\n"
                "            copied = sc && copy_t2t_draw_sq(in, sc, 0, 0, 0, 0, &ir, &at0o, 1, 0, srgb)\n"
                "                     && copy_t2t_draw_x(sc, out, 0, 0, 0, 0, &at0o, &orr, 0, 0, 0, sharpen);\n"
                "        } else {\n"
                "            copied = copy_t2t_draw_sq(in, out, 0, 0, 0, 0, &ir, &orr, 1, 0, srgb);\n"
                "        }\n"
                "        args_dirty_all();\n"
                "        if (!copied) { g_up_mfx_kept++; return 0; }\n"
                "        if (!g_up_mfx_n++) MLOG(\"upscaler: first dispatch of %s skipped (bilinear%s), %dx%d at %d,%d of %lux%lu (format %lu) → %dx%d at %d,%d of %lux%lu (format %lu)%s\",\n"
                "                                cs->key, sharpen > 0 ? \" + sharpen\" : \"\", ir.width, ir.height, ir.xoffset, ir.yoffset,\n"
                "                                (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat,\n"
                "                                orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width, (unsigned long)out.height,\n"
                "                                (unsigned long)out.pixelFormat, srgb ? \", decoded from root\" : \"\");\n"
                "        return 1;\n"
                "    }\n"
                "    up_mfx_scaler *e = up_mfx_scaler_for((NSUInteger)ir.width, (NSUInteger)ir.height, (NSUInteger)orr.width, (NSUInteger)orr.height, srgb); if (!e) { g_up_mfx_kept++; return 0; }\n"
                "    id<MTL4FXSpatialScaler> sc = e->sc;\n"
                "    // Straight in and out when MetalFX can take the game's textures as they are; through the scaler's own textures otherwise\n"
                "    int direct = !srgb && (NSUInteger)ir.width == in.width && (NSUInteger)ir.height == in.height && out.storageMode == MTLStorageModePrivate &&\n"
                "                 in.pixelFormat == MTLPixelFormatRGBA16Float && out.pixelFormat == MTLPixelFormatRGBA16Float && !ir.xoffset && !ir.yoffset && !orr.xoffset && !orr.yoffset && (NSUInteger)orr.width == out.width &&\n"
                "                 (NSUInteger)orr.height == out.height && (in.usage & sc.colorTextureUsage) == sc.colorTextureUsage && (out.usage & sc.outputTextureUsage) == sc.outputTextureUsage && (!is_oot_game() || sharpen <= 0);",
            ),
        ],
    ),
    (
        "up_mfx_encode_sharpen_read",
        '", then sharpened"',
        [
            (
                '    if (!sout && !copy_t2t_draw(drawn, out, 0, 0, 0, 0, &at0o, &orr, 0, 0)) {\n'
                '        args_dirty_all(); g_up_mfx_kept++; return 0;   // only the scratch image was scaled; the game\'s shader can still produce the output\n    }\n'
                '    args_dirty_all();\n'
                '    g_up_mfx_straight[0] += sin; g_up_mfx_straight[1] += sout;\n'
                '    if (!g_up_mfx_n++) MLOG("upscaler: first dispatch of %s drawn by MetalFX, %dx%d at %d,%d of %lux%lu (format %lu, %s) → %dx%d at %d,%d of %lux%lu (format %lu, %s)%s", cs->key, ir.width, ir.height, ir.xoffset, ir.yoffset,\n'
                '                            (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat, sin ? "straight" : "copied", orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width,\n'
                '                            (unsigned long)out.height, (unsigned long)out.pixelFormat, sout ? "straight" : "drawn back", srgb ? ", decoded from sRGB" : root ? ", squared from its square roots" : "");',
                '    if (!sout && !copy_t2t_draw_x(drawn, out, 0, 0, 0, 0, &at0o, &orr, 0, 0, 0, sharpen)) {\n'
                '        args_dirty_all(); g_up_mfx_kept++; return 0;   // only the scratch image was scaled; the game\'s shader can still produce the output\n    }\n'
                '    args_dirty_all();\n'
                '    g_up_mfx_straight[0] += sin; g_up_mfx_straight[1] += sout;\n'
                '    if (!g_up_mfx_n++) MLOG("upscaler: first dispatch of %s drawn by MetalFX, %dx%d at %d,%d of %lux%lu (format %lu, %s) → %dx%d at %d,%d of %lux%lu (format %lu, %s)%s%s", cs->key, ir.width, ir.height, ir.xoffset, ir.yoffset,\n'
                '                            (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat, sin ? "straight" : "copied", orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width,\n'
                '                            (unsigned long)out.height, (unsigned long)out.pixelFormat, sout ? "straight" : "drawn back", srgb ? ", decoded from sRGB" : root ? ", squared from its square roots" : "", sharpen > 0 ? ", then sharpened" : "");',
            ),
            (
                '    if (!sout && !copy_t2t_draw(drawn, out, 0, 0, 0, 0, &at0o, &orr, 0, 0)) {\n'
                '        args_dirty_all(); g_up_mfx_kept++; return 0;   // only the scratch image was scaled; the game\'s shader can still produce the output\n    }\n'
                '    args_dirty_all();\n'
                '    g_up_mfx_straight[0] += sin; g_up_mfx_straight[1] += sout;\n'
                '    if (!g_up_mfx_n++) MLOG("upscaler: first dispatch of %s drawn by MetalFX, %dx%d at %d,%d of %lux%lu (format %lu, %s) → %dx%d at %d,%d of %lux%lu (format %lu, %s)%s", cs->key, ir.width, ir.height, ir.xoffset, ir.yoffset,\n'
                '                            (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat, sin ? "straight" : "copied", orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width,\n'
                '                            (unsigned long)out.height, (unsigned long)out.pixelFormat, sout ? "straight" : "drawn back", srgb ? ", decoded from sRGB" : "");',
                '    if (!sout && !copy_t2t_draw_x(drawn, out, 0, 0, 0, 0, &at0o, &orr, 0, 0, 0, sharpen)) {\n'
                '        args_dirty_all(); g_up_mfx_kept++; return 0;   // only the scratch image was scaled; the game\'s shader can still produce the output\n    }\n'
                '    args_dirty_all();\n'
                '    g_up_mfx_straight[0] += sin; g_up_mfx_straight[1] += sout;\n'
                '    if (!g_up_mfx_n++) MLOG("upscaler: first dispatch of %s drawn by MetalFX, %dx%d at %d,%d of %lux%lu (format %lu, %s) → %dx%d at %d,%d of %lux%lu (format %lu, %s)%s%s", cs->key, ir.width, ir.height, ir.xoffset, ir.yoffset,\n'
                '                            (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat, sin ? "straight" : "copied", orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width,\n'
                '                            (unsigned long)out.height, (unsigned long)out.pixelFormat, sout ? "straight" : "drawn back", srgb ? ", decoded from sRGB" : "", sharpen > 0 ? ", then sharpened" : "");',
            ),
            (
                '    if (!direct && !copy_t2t_draw(e->read, out, 0, 0, 0, 0, &at0o, &orr, 0, 0)) {\n'
                '        args_dirty_all(); g_up_mfx_kept++; return 0;   // only the scratch image was scaled; the game\'s shader can still produce the output\n    }\n'
                '    args_dirty_all();\n'
                '    if (!g_up_mfx_n++) MLOG("upscaler: first dispatch of %s drawn by MetalFX, %dx%d at %d,%d of %lux%lu (format %lu) → %dx%d at %d,%d of %lux%lu (format %lu)%s", cs->key, ir.width, ir.height, ir.xoffset, ir.yoffset,\n'
                '                            (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat, orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width, (unsigned long)out.height,\n'
                '                            (unsigned long)out.pixelFormat, direct ? ", straight" : srgb ? ", through RGBA16F, decoded from sRGB" : ", through RGBA16F");',
                '    if (!direct && !copy_t2t_draw_x(e->read, out, 0, 0, 0, 0, &at0o, &orr, 0, 0, 0, sharpen)) {\n'
                '        args_dirty_all(); g_up_mfx_kept++; return 0;   // only the scratch image was scaled; the game\'s shader can still produce the output\n    }\n'
                '    args_dirty_all();\n'
                '    if (!g_up_mfx_n++) MLOG("upscaler: first dispatch of %s drawn by MetalFX, %dx%d at %d,%d of %lux%lu (format %lu) → %dx%d at %d,%d of %lux%lu (format %lu)%s%s", cs->key, ir.width, ir.height, ir.xoffset, ir.yoffset,\n'
                '                            (unsigned long)in.width, (unsigned long)in.height, (unsigned long)in.pixelFormat, orr.width, orr.height, orr.xoffset, orr.yoffset, (unsigned long)out.width, (unsigned long)out.height,\n'
                '                            (unsigned long)out.pixelFormat, direct ? ", straight" : srgb ? ", through RGBA16F, decoded from sRGB" : ", through RGBA16F", sharpen > 0 ? ", then sharpened" : "");',
            ),
        ],
    ),
    (
        "present_now_pres_adj",
        "double pres_adj = is_oot_game() ? g_fg_tls_pres_adj : 0.0;",
        "static int present_now(const tex_t *t, double period, uint64_t frame, uint64_t ticket, const int crop[4], id<CAMetalDrawable> supplied, double target_ts) {",
        "static int present_now(const tex_t *t, double period, uint64_t frame, uint64_t ticket, const int crop[4], id<CAMetalDrawable> supplied, double target_ts) {\n"
        "    double pres_adj = is_oot_game() ? g_fg_tls_pres_adj : 0.0;\n"
        "    g_fg_tls_pres_adj = 0.0;",
    ),
    (
        "present_now_tt_adj",
        "tt > 0 ? tt + pres_adj : -1",
        [
            (
                "    (void)period; [dr present];\n#else\n"
                "    uint64_t pn = ticket;   // Record the present time by the game's present sequence number (ticket number): hle's present statistics are taken by \"the game's nth present\"; in the display link path the actual present count != the game's present count (old frames get merged and dropped)\n"
                "    [dr addPresentedHandler:^(id<MTLDrawable> d) {   // Actual presentation time (the time this frame is really put on screen, CACurrentMediaTime base)\n"
                "        CFTimeInterval tt = d.presentedTime;\n"
                "        g_pres[pn % PRING] = (pres_ent){pn, tt > 0 ? tt : -1};\n"
                "        pres_seen(pn, tt);\n"
                "    }];",
                "    (void)period; (void)pres_adj; [dr present];\n#else\n"
                "    uint64_t pn = ticket;   // Record the present time by the game's present sequence number (ticket number): hle's present statistics are taken by \"the game's nth present\"; in the display link path the actual present count != the game's present count (old frames get merged and dropped)\n"
                "    [dr addPresentedHandler:^(id<MTLDrawable> d) {   // Actual presentation time (the time this frame is really put on screen, CACurrentMediaTime base)\n"
                "        CFTimeInterval tt = d.presentedTime;\n"
                "        g_pres[pn % PRING] = (pres_ent){pn, tt > 0 ? tt + pres_adj : -1};\n"
                "        pres_seen(pn, tt);\n"
                "    }];",
            ),
            (
                "    (void)period; [dr present];\n#else\n"
                "    uint64_t pn = ticket;   // Record the present time by the game's present sequence number (ticket number): hle's present statistics are taken by \"the game's nth present\"; in the display link path the actual present count != the game's present count (old frames get merged and dropped)\n"
                "    [dr addPresentedHandler:^(id<MTLDrawable> d) {   // Actual presentation time (the time this frame is really put on screen, CACurrentMediaTime base)\n"
                "        CFTimeInterval tt = d.presentedTime;\n"
                "        g_pres[pn % PRING] = (pres_ent){pn, tt > 0 ? tt : -1};\n"
                "    }];",
                "    (void)period; (void)pres_adj; [dr present];\n#else\n"
                "    uint64_t pn = ticket;   // Record the present time by the game's present sequence number (ticket number): hle's present statistics are taken by \"the game's nth present\"; in the display link path the actual present count != the game's present count (old frames get merged and dropped)\n"
                "    [dr addPresentedHandler:^(id<MTLDrawable> d) {   // Actual presentation time (the time this frame is really put on screen, CACurrentMediaTime base)\n"
                "        CFTimeInterval tt = d.presentedTime;\n"
                "        g_pres[pn % PRING] = (pres_ent){pn, tt > 0 ? tt + pres_adj : -1};\n"
                "    }];",
            ),
        ],
    ),
    (
        "framegen_include",
        "#define OOT_ENH_FRAMEGEN",
        "@interface NvMetalDisplayLinkDelegate : NSObject <CAMetalDisplayLinkDelegate>",
        '#define OOT_ENH_FRAMEGEN\n#include "oot_enhancements.inc"\n\n@interface NvMetalDisplayLinkDelegate : NSObject <CAMetalDisplayLinkDelegate>',
    ),
    (
        "framegen_cad_tick_and_held",
        "fg_cad_tick(update.targetPresentationTimestamp);",
        "    pthread_mutex_lock(&g_pq_mu);\n"
        "    if (!g_dm_present_link || g_rescue_mode || g_pq_read == g_pq_in) { if (g_dm_present_link && !g_rescue_mode) g_link_empty++; pthread_mutex_unlock(&g_pq_mu); return; }",
        "    pthread_mutex_lock(&g_pq_mu);\n"
        "    if (is_oot_game() && fg_on()) {\n"
        "        fg_cad_tick(update.targetPresentationTimestamp);\n"
        "        if (!g_dm_present_link || g_rescue_mode) fg_drop_held();\n"
        "        else if (g_fg_have_held && fg_handle_held(update, cb)) return;\n"
        "    }\n"
        "    if (!g_dm_present_link || g_rescue_mode || g_pq_read == g_pq_in) { if (g_dm_present_link && !g_rescue_mode) g_link_empty++; pthread_mutex_unlock(&g_pq_mu); return; }",
    ),
    (
        "framegen_take_or_hold",
        "fg_take_or_hold(&it, ticket, update, fg_ticks)",
        [
            (
                "    pthread_cond_broadcast(&g_pq_cv);\n"
                "    pthread_mutex_unlock(&g_pq_mu);\n"
                "    link_drain_note(cb, cb - it.t_in, ticket > first);\n"
                "    int submitted;\n"
                "    ext_wait(it.ev_val); snap_commit_wait(it.snap_v);\n"
                "    @autoreleasepool { submitted = present_now(&it.t, it.period, it.frame, ticket, it.crop, update.drawable, update.targetPresentationTimestamp); mtl_tex_unpin(it.t.serial); }\n"
                "    g_link_hold_until = submitted && it.period > 0.025 ? update.targetPresentationTimestamp + it.period : 0;",
                "    int fg_ticks = (is_oot_game() && fg_on() && g_fg_win_n) ? g_fg_win[(g_fg_win_i + FG_WIN - 1) % FG_WIN] : 0;\n"
                "    pthread_cond_broadcast(&g_pq_cv);\n"
                "    pthread_mutex_unlock(&g_pq_mu);\n"
                "    link_drain_note(cb, cb - it.t_in, ticket > first);\n"
                "    int submitted;\n"
                "    ext_wait(it.ev_val); snap_commit_wait(it.snap_v);\n"
                "    if (is_oot_game() && fg_on() && fg_take_or_hold(&it, ticket, update, fg_ticks)) { g_link_hold_until = 0; return; }\n"
                "    @autoreleasepool { submitted = present_now(&it.t, it.period, it.frame, ticket, it.crop, update.drawable, update.targetPresentationTimestamp); mtl_tex_unpin(it.t.serial); }\n"
                "    g_link_hold_until = submitted && it.period > 0.025 ? update.targetPresentationTimestamp + it.period : 0;",
            ),
            (
                "    pthread_cond_broadcast(&g_pq_cv);\n"
                "    pthread_mutex_unlock(&g_pq_mu);\n"
                "    int submitted;\n"
                "    ext_wait(it.ev_val); snap_commit_wait(it.snap_v);\n"
                "    @autoreleasepool { submitted = present_now(&it.t, it.period, it.frame, ticket, it.crop, update.drawable, update.targetPresentationTimestamp); mtl_tex_unpin(it.t.serial); }\n"
                "    g_link_hold_until = submitted && it.period > 0.025 ? update.targetPresentationTimestamp + it.period : 0;",
                "    int fg_ticks = (is_oot_game() && fg_on() && g_fg_win_n) ? g_fg_win[(g_fg_win_i + FG_WIN - 1) % FG_WIN] : 0;\n"
                "    pthread_cond_broadcast(&g_pq_cv);\n"
                "    pthread_mutex_unlock(&g_pq_mu);\n"
                "    int submitted;\n"
                "    ext_wait(it.ev_val); snap_commit_wait(it.snap_v);\n"
                "    if (is_oot_game() && fg_on() && fg_take_or_hold(&it, ticket, update, fg_ticks)) { g_link_hold_until = 0; return; }\n"
                "    @autoreleasepool { submitted = present_now(&it.t, it.period, it.frame, ticket, it.crop, update.drawable, update.targetPresentationTimestamp); mtl_tex_unpin(it.t.serial); }\n"
                "    g_link_hold_until = submitted && it.period > 0.025 ? update.targetPresentationTimestamp + it.period : 0;",
            ),
        ],
    ),
    (
        "present_drop_for_suspend",
        "if (is_oot_game() && fg_on()) fg_drop_held();",
        "static void present_drop_for_suspend(void) {\n"
        "    pthread_mutex_lock(&g_pq_mu);\n"
        "    if (g_link_owns_layer) {\n"
        "        uint64_t n = g_pq_in - g_pq_read;",
        "static void present_drop_for_suspend(void) {\n"
        "    pthread_mutex_lock(&g_pq_mu);\n"
        "    if (g_link_owns_layer) {\n"
        "        if (is_oot_game() && fg_on()) fg_drop_held();\n"
        "        uint64_t n = g_pq_in - g_pq_read;",
    ),
    (
        "framegen_link_sync",
        "if (want && is_oot_game() && fg_on()) {",
        "    if (want && mtl_fps_target() == 30 && link_30hz()) want = 3;   // Power-saving mode: display link at 30 Hz",
        "    if (want && is_oot_game() && fg_on()) {\n"
        "        int max_hz = front_screen_max_fps();\n"
        "        if (want == 2 && max_hz > 0 && max_hz < 120) { want = 1; g_dm_present_link = 1; }\n"
        "        else if (want == 1 && max_hz >= 120 && mtl_fps_target() >= 60) { want = 2; g_dm_present_link = 2; }\n"
        "    }\n"
        "    if (want && mtl_fps_target() == 30 && link_30hz() && !(is_oot_game() && fg_on())) want = 3;   // Power-saving mode: display link at 30 Hz",
    ),
    (
        "framegen_snap_ring",
        "if (is_oot_game() && fg_on() && n > 0 && n < 3) n = 3;",
        "    int n = e ? atoi(e) : DM_GAME_PRESENT_SNAP ? 2 : 0;   // the profile's present_snap (a ring of 2)",
        "    int n = e ? atoi(e) : DM_GAME_PRESENT_SNAP ? 2 : 0;   // the profile's present_snap (a ring of 2)\n"
        "    if (is_oot_game() && fg_on() && n > 0 && n < 3) n = 3;",
    ),
    (
        "framegen_present_wait_stall",
        "int fg_held_tk = (is_oot_game() && fg_on() && g_fg_have_held && g_fg_held_ticket >= tk);",
        '        if (!g_link_owns_layer) { pthread_cond_wait(&g_pq_cv, &g_pq_mu); continue; }\n'
        '        if (g_pq_read >= tk) { pthread_cond_wait(&g_pq_cv, &g_pq_mu); continue; }   // This one has already been taken by the display link and is being presented: wait for it to be handed to the GPU (the GPU completion callback will wake us)\n'
        '        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_nsec += (long)STALL_NS; if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }\n'
        '        // Already determined to be in a stall (when the display link comes back the callback first clears g_stall_t0, then records the display-link tick time): no longer wait 100 ms in vain every frame, drop directly, and the game proceeds by its own display-link wait timeout (about two ticks)\n'
        '        if (!g_stall_t0 && (pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT || g_pq_done >= tk)) continue;\n'
        '        uint64_t now = now_ns(), last = __atomic_load_n(&g_link_tick_ns, __ATOMIC_RELAXED);\n'
        '        if (g_pq_read >= tk) continue;\n'
        '        if (now - last < STALL_NS) { pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts); continue; }   // The display link is still running, it is just not this one\'s turn yet: keep waiting (bounded, no busy spinning)\n'
        '        uint64_t n = tk - g_pq_read;\n'
        '        for (uint64_t k = g_pq_read + 1; k <= tk; k++) { g_pres[k % PRING] = (pres_ent){k, -1}; mtl_tex_unpin(g_pq[(k-1)%PQ].t.serial); }\n'
        '        g_link_dropped += n; g_pq_read = tk;',
        '        if (!g_link_owns_layer) { pthread_cond_wait(&g_pq_cv, &g_pq_mu); continue; }\n'
        '        int fg_held_tk = (is_oot_game() && fg_on() && g_fg_have_held && g_fg_held_ticket >= tk);\n'
        '        if (g_pq_read >= tk && !fg_held_tk) { pthread_cond_wait(&g_pq_cv, &g_pq_mu); continue; }   // This one has already been taken by the display link and is being presented: wait for it to be handed to the GPU (the GPU completion callback will wake us)\n'
        '        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_nsec += (long)STALL_NS; if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }\n'
        '        // Already determined to be in a stall (when the display link comes back the callback first clears g_stall_t0, then records the display-link tick time): no longer wait 100 ms in vain every frame, drop directly, and the game proceeds by its own display-link wait timeout (about two ticks)\n'
        '        if (!g_stall_t0 && (pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT || g_pq_done >= tk)) continue;\n'
        '        uint64_t now = now_ns(), last = __atomic_load_n(&g_link_tick_ns, __ATOMIC_RELAXED);\n'
        '        fg_held_tk = (is_oot_game() && fg_on() && g_fg_have_held && g_fg_held_ticket >= tk);\n'
        '        if (g_pq_read >= tk && !fg_held_tk) continue;\n'
        '        if (now - last < STALL_NS) { pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts); continue; }   // The display link is still running, it is just not this one\'s turn yet: keep waiting (bounded, no busy spinning)\n'
        '        if (is_oot_game() && fg_on() && g_fg_have_held) { fg_drop_held(); g_link_dropped++; }\n'
        '        uint64_t n = tk > g_pq_read ? tk - g_pq_read : 0;\n'
        '        for (uint64_t k = g_pq_read + 1; k <= tk; k++) { g_pres[k % PRING] = (pres_ent){k, -1}; mtl_tex_unpin(g_pq[(k-1)%PQ].t.serial); }\n'
        '        g_link_dropped += n; if (g_pq_read < tk) g_pq_read = tk;',
    ),
]


CRITICAL_P0_HOOKS = {"top_include", "mem_include"}

_POISONED_COPY_T2T_BLOCK = (
    "\nstatic int copy_t2t_draw_sq(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror, int square) {\n"
    "    return copy_t2t_draw_x(s, d, sl, ss, dl, ds, sr, dr, linear, mirror, square, 0);\n"
    "}\n"
    "static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror) {\n"
    "    return copy_t2t_draw_x(s, d, sl, ss, dl, ds, sr, dr, linear, mirror, 0, 0);\n"
    "}"
)


def _token_present(text: str, token: str | tuple[str, ...]) -> bool:
    if isinstance(token, tuple):
        return any(t in text for t in token)
    return token in text


def heal_duplicate_copy_t2t_wrappers(text: str) -> str:
    """Removes duplicate copy_t2t_draw_sq/copy_t2t_draw wrappers injected next to inline definitions."""
    if "static inline int copy_t2t_draw_sq(" in text and _POISONED_COPY_T2T_BLOCK in text:
        return text.replace(_POISONED_COPY_T2T_BLOCK, "")
    return text


def patch_nvn_mtl(apply: bool, soft: bool = False) -> tuple[list[str], list[str]]:
    if not NVN_MTL_PATH.is_file():
        return (["missing dm/gfx/nvn/nvn_mtl.m"], [])
    text = NVN_MTL_PATH.read_text(encoding="utf-8", errors="replace")
    healed = heal_duplicate_copy_t2t_wrappers(text)
    if not apply and healed != text:
        return (["dm/gfx/nvn/nvn_mtl.m contains duplicate copy_t2t_draw wrapper definitions"], [])
    updated = healed if apply else text
    changed = updated != text

    missing = [rule[0] for rule in NVN_MTL_HOOK_RULES if not _token_present(updated, rule[1])]
    if not missing and not changed:
        return ([], [])
    if not apply:
        return ([f"dm/gfx/nvn/nvn_mtl.m missing hook: {name}" for name in missing], [])

    errs: list[str] = []
    warns: list[str] = []
    for rule in NVN_MTL_HOOK_RULES:
        name, token = rule[0], rule[1]
        if _token_present(updated, token):
            continue
        if name == "copy_t2t_draw_wrappers" and (
            "copy_t2t_draw_x(" not in updated or "copy_t2t_draw_sq(" in updated
        ):
            msg = "dm/gfx/nvn/nvn_mtl.m skipped wrapper injection without copy_t2t_draw_x"
            if soft:
                warns.append(msg + " (P1 visual optimization skipped)")
            else:
                errs.append(msg)
            continue
        pairs = rule[2] if len(rule) == 3 else [(rule[2], rule[3])]
        matched = False
        for target, replacement in pairs:
            if target in updated:
                updated = updated.replace(target, replacement, 1)
                changed = True
                matched = True
                break
        if not matched:
            msg = f"dm/gfx/nvn/nvn_mtl.m anchor missing for hook {name}"
            if soft and name not in CRITICAL_P0_HOOKS:
                warns.append(msg + " (P1 visual optimization skipped)")
                print(f"[OOT-PATCH-WARN] {msg} (P1 enhancement skipped gracefully)")
            else:
                errs.append(msg)
    if errs:
        return (errs, warns)
    if changed:
        NVN_MTL_PATH.write_text(updated, encoding="utf-8")
        print("[REPAIRED] dm/gfx/nvn/nvn_mtl.m")
    return ([], warns)


def patch_pack_app(apply: bool) -> list[str]:
    """Idempotently preserves --romfs-overlay in dm/mac/pack_app.py across upstream merges."""
    if not PACK_APP_PY_PATH.is_file():
        return ["missing dm/mac/pack_app.py"]
    text = PACK_APP_PY_PATH.read_text(encoding="utf-8", errors="replace")
    required = ("'romfs_overlay'", "a.romfs_overlay", "--romfs-overlay")
    if all(tok in text for tok in required):
        return []
    if not apply:
        return ["dm/mac/pack_app.py missing --romfs-overlay support"]

    rules = [
        (
            "resolve_names",
            "'romfs_overlay'",
            [
                (
                    "('out', 'host', 'patched', 'romfs', 'msl', 'tables', 'font', 'aoc', 'pso', 'pso_pairs', 'env_file', 'settings', 'icon', 'html', 'control_nacp')",
                    "('out', 'host', 'patched', 'romfs', 'msl', 'tables', 'font', 'aoc', 'pso', 'pso_pairs', 'romfs_overlay', 'env_file', 'settings', 'icon', 'html', 'control_nacp')",
                ),
                (
                    "('out', 'host', 'patched', 'romfs', 'msl', 'tables', 'font', 'aoc', 'pso', 'pso_pairs', 'env_file', 'settings', 'icon', 'html')",
                    "('out', 'host', 'patched', 'romfs', 'msl', 'tables', 'font', 'aoc', 'pso', 'pso_pairs', 'romfs_overlay', 'env_file', 'settings', 'icon', 'html')",
                ),
            ],
        ),
        (
            "trees_inventory",
            "a.romfs_overlay",
            [
                (
                    "(a.romfs, a.aoc, a.html, *(str(x[1]) for x in programs), *(str(x[3]) for x in programs))",
                    "(a.romfs, a.aoc, a.html, a.romfs_overlay, *(str(x[1]) for x in programs), *(str(x[3]) for x in programs))",
                ),
            ],
        ),
        (
            "copy_overlay",
            "res / 'romfs_overlay'",
            [
                (
                    "    if a.html and Path(a.html).is_dir(): copy([Path(a.html)], res / 'html', False)   # the offline pages, beside the RomFS where the host looks for them (hle_web.c)",
                    "    if a.html and Path(a.html).is_dir(): copy([Path(a.html)], res / 'html', False)   # the offline pages, beside the RomFS where the host looks for them (hle_web.c)\n"
                    "    if a.romfs_overlay: step('game file replacements'); copy([Path(a.romfs_overlay)], res / 'romfs_overlay', False)   # served over the RomFS (launcher.c DM_ROMFS_OVERLAY)",
                ),
            ],
        ),
        (
            "cli_arg",
            "--romfs-overlay",
            [
                (
                    "    ap.add_argument('--html', help='the offline HTML pages (nx_extract --html), which go beside the RomFS')",
                    "    ap.add_argument('--romfs-overlay', help='game file replacements served over the RomFS (Resources/romfs_overlay, which the launcher makes DM_ROMFS_OVERLAY)')\n"
                    "    ap.add_argument('--html', help='the offline HTML pages (nx_extract --html), which go beside the RomFS')",
                ),
            ],
        ),
    ]

    updated = text
    errs: list[str] = []
    for name, token, candidates in rules:
        if token in updated:
            continue
        matched = False
        for target, repl in candidates:
            if target in updated:
                updated = updated.replace(target, repl, 1)
                matched = True
                break
        if not matched:
            errs.append(f"dm/mac/pack_app.py anchor missing for {name}")
    if errs:
        return errs
    if updated != text:
        PACK_APP_PY_PATH.write_text(updated, encoding="utf-8")
        print("[REPAIRED] dm/mac/pack_app.py (restored --romfs-overlay)")
    return []


def patch_build_ipa_from_nsp(apply: bool) -> list[str]:
    """Idempotently preserves --shell-framework in scripts/build_ipa_from_nsp.py across upstream merges."""
    if not BUILD_IPA_PY_PATH.is_file():
        return ["missing scripts/build_ipa_from_nsp.py"]
    text = BUILD_IPA_PY_PATH.read_text(encoding="utf-8", errors="replace")
    required = ("--shell-framework", "shell_fw =", "DM_FRAMEWORK_ONLY")
    if all(tok in text for tok in required):
        return []
    if not apply:
        return ["scripts/build_ipa_from_nsp.py missing --shell-framework support"]

    rules = [
        (
            "cli_arg",
            "--shell-framework",
            "    ap.add_argument('--prepare-xcode', action='store_true', help='prepare a per-game Xcode project and add it to the shared workspace instead of packing an IPA (requires keeping extracted files)')",
            "    ap.add_argument('--prepare-xcode', action='store_true', help='prepare a per-game Xcode project and add it to the shared workspace instead of packing an IPA (requires keeping extracted files)')\n"
            "    ap.add_argument('--shell-framework', metavar='FOLDER', help='route C\\'s shell (docs/launcher-c-plan.md M2): build only the game\\'s framework, FOLDER/DmGame<title ID>.framework '\n"
            "                    '(its code, tables, settings list, shader libraries and icon), for dm/ios/tools/build_shell.sh to embed in the one app for all games; no IPA or Xcode project, '\n"
            "                    'the game files stay separate (implies --romfs separate and --keep-extracted)')",
        ),
        (
            "validate_shell_fw",
            "shell_fw =",
            "    if mac and prepare_xcode: raise BuildError(f'--prepare-xcode makes an iPhone project: it cannot be combined with --platform {platform}')",
            "    if mac and prepare_xcode: raise BuildError(f'--prepare-xcode makes an iPhone project: it cannot be combined with --platform {platform}')\n"
            "    shell_fw = Path(os.path.expanduser(args.shell_framework)).resolve() if args.shell_framework else None\n"
            "    if shell_fw and (mac or prepare_xcode): raise BuildError('--shell-framework builds only the game framework for the shell: it cannot be combined with --platform mac / mac-app or --prepare-xcode')\n"
            "    if shell_fw and args.romfs == 'bundle': raise BuildError('--shell-framework keeps the game files separate (the shell takes them from Documents/games/<title ID>/): it cannot be combined with --romfs bundle')\n"
            "    if shell_fw: args.romfs = 'separate'; args.keep_extracted = True",
        ),
        (
            "free_space_msg",
            "and not shell_fw and free_gb",
            "    if not prepare_xcode and free_gb(out_ipa.parent) < 5: raise BuildError(f'less than 5 GB free on the volume of {out_ipa.parent}')\n"
            "    say('preparing the Xcode project' if prepare_xcode else f'building the IPA → {out_ipa}')",
            "    if not prepare_xcode and not shell_fw and free_gb(out_ipa.parent) < 5: raise BuildError(f'less than 5 GB free on the volume of {out_ipa.parent}')\n"
            "    say('preparing the Xcode project' if prepare_xcode else f'building the game framework for the shell → {shell_fw}' if shell_fw else f'building the IPA → {out_ipa}')",
        ),
        (
            "build_framework_branch",
            "DM_FRAMEWORK_ONLY",
            "    watch = IpaWatch(repo, work / 'ipa', out_ipa)",
            "    if shell_fw:   # route C's shell: the framework alone, which build_shell.sh embeds; the game files stay where they are for the copy to the device\n"
            "        ipa_env['DM_FRAMEWORK_ONLY'] = str(shell_fw)\n"
            "        fw = shell_fw / f'DmGame{g.id.upper()}.framework'\n"
            "        PROG.stage('game framework')\n"
            "        run(['bash', repo / 'dm/ios/tools/build_ipa.sh'], logs / 'build_framework.log', env=ipa_env)\n"
            "        if not fw.is_dir(): raise BuildError(f'no built framework at {fw}')\n"
            "        PROG.end(f'{fw.name}, {amount(sum(f.stat().st_size for f in fw.rglob(\"*\") if f.is_file()), \"B\")}')\n"
            "        rmtree(work / 'tmp')\n"
            "        say(f'done: {fw}')\n"
            "        report_profile_status(g, reg, pkg_ver, derived, provisional, 'game framework', patched)\n"
            "        return\n"
            "    watch = IpaWatch(repo, work / 'ipa', out_ipa)",
        ),
    ]

    updated = text
    errs: list[str] = []
    for name, token, target, repl in rules:
        if token in updated:
            continue
        if target in updated:
            updated = updated.replace(target, repl, 1)
        else:
            errs.append(f"scripts/build_ipa_from_nsp.py anchor missing for {name}")
    if errs:
        return errs
    if updated != text:
        BUILD_IPA_PY_PATH.write_text(updated, encoding="utf-8")
        print("[REPAIRED] scripts/build_ipa_from_nsp.py (restored --shell-framework)")
    return []


def revert_patches() -> list[str]:
    """Reverts patched in-tree files to clean git HEAD state before an upstream merge."""
    files_to_revert = [
        NVN_MTL_PATH,
        PRESENT_METAL_PATH,
        COPY_METAL_PATH,
        PACK_APP_PY_PATH,
        BUILD_IPA_PY_PATH,
    ]
    rel_paths = [str(p.relative_to(REPO_ROOT)) for p in files_to_revert if p.is_file()]
    if not rel_paths:
        return []
    try:
        subprocess.run(
            ["git", "-C", str(REPO_ROOT), "checkout", "HEAD", "--"] + rel_paths,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        print(f"[REVERT-OK] Cleaned in-tree patched files for upstream merge: {', '.join(rel_paths)}")
        return []
    except subprocess.CalledProcessError as e:
        err = e.stderr.decode("utf-8", errors="replace").strip()
        print(f"[REVERT-WARN] Could not revert in-tree files via git: {err}")
        return [f"git checkout failed: {err}"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Only verify hooks without editing files")
    mode.add_argument("--apply", action="store_true", help="Verify and repair missing hooks cleanly")
    mode.add_argument("--revert", action="store_true", help="Revert in-tree engine patches before upstream merge")
    parser.add_argument("--soft", action="store_true", help="Non-fatal mode: skip optional P1 enhancements if upstream refactored")
    args = parser.parse_args()

    if args.revert:
        revert_errors = revert_patches()
        return 1 if revert_errors else 0

    apply = not args.check
    soft = args.soft

    errors: list[str] = []
    warnings: list[str] = []

    errors.extend(check_oot_inc())
    errors.extend(patch_present_metal(apply))
    errors.extend(patch_copy_metal(apply))
    errors.extend(patch_game_tsv(apply))
    errors.extend(patch_patches_py(apply))
    if soft:
        for extra_err in patch_pack_app(apply) + patch_build_ipa_from_nsp(apply):
            warnings.append(extra_err)
    else:
        errors.extend(patch_pack_app(apply))
        errors.extend(patch_build_ipa_from_nsp(apply))
    
    nvn_errs, nvn_warns = patch_nvn_mtl(apply, soft=soft)
    errors.extend(nvn_errs)
    warnings.extend(nvn_warns)

    if NVN_GEOMETRY_PATH.is_file():
        geo_text = NVN_GEOMETRY_PATH.read_text(encoding="utf-8", errors="replace")
        if "g_mtk_legacy_first" not in geo_text:
            msg = "dm/gfx/nvn/nvn_geometry.inc missing g_mtk_legacy_first multi-chain support"
            (warnings if soft else errors).append(msg)
    if NVN_MTL_PATH.is_file():
        mtl_text = NVN_MTL_PATH.read_text(encoding="utf-8", errors="replace")
        for tok in ("g_active_chain", "g_mtk_legacy_first", "bmap_bytes"):
            if tok not in mtl_text:
                msg = f"dm/gfx/nvn/nvn_mtl.m missing multi-chain token: {tok}"
                (warnings if soft else errors).append(msg)

    if errors:
        for err in errors:
            print(f"[OOT-PATCH-ERROR] {err}", file=sys.stderr)
        return 1

    if warnings:
        for warn in warnings:
            print(f"[OOT-PATCH-WARN] {warn}", file=sys.stderr)
        print("[OOT-PATCH-OK] Core patches verified (with non-fatal P1 warnings).")
    else:
        print("[OOT-PATCH-OK] All isolated Ocarina of Time (0400486024DEC000) patches verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
