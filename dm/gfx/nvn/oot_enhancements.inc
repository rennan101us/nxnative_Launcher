// The Legend of Zelda: Ocarina of Time (0400486024DEC000) isolated engine enhancements.
// Included by nvn_mtl.m at controlled section points so upstream merges cannot overwrite
// the implementation and all other games stay on unmodified upstream code paths.

#ifdef OOT_ENH_TOP
#undef OOT_ENH_TOP

#ifndef DM_GAME_ID
#define DM_GAME_ID ""
#endif
#ifndef DM_GAME_TEX_RELEASE
#define DM_GAME_TEX_RELEASE 0
#endif
#ifndef DM_GAME_POOL_SKIP_RETIRED
#define DM_GAME_POOL_SKIP_RETIRED 0
#endif
#ifndef DM_GAME_RT_LOSSY
#define DM_GAME_RT_LOSSY 0
#endif

static inline int is_oot_game(void) {
    return strcmp(DM_GAME_ID, "0400486024DEC000") == 0;
}

static void rel_pool_gone(const void *mem);
static int cond_conservative(void);
static _Thread_local double g_fg_tls_pres_adj;

__attribute__((used)) static const char k_nxnative_compat_chains[] =
    "\0" "3ee52af3ca18" "\0" "6c5624e3ea0e" "\0" "8edb79f5396c" "\0" "d6b05d7481e5" "\0" "d254f45e8002" "\0";

#endif // OOT_ENH_TOP

#ifdef OOT_ENH_MEM
#undef OOT_ENH_MEM

static NSMutableArray *g_up_tc_src, *g_up_tc_dst;

static int rel_wired(uintptr_t lo, uintptr_t hi) {
    int w = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < g_npool; i++) {
        if (g_pools[i].res && g_pools[i].lo < hi && g_pools[i].hi > lo) { w = 1; break; }
    }
    pthread_mutex_unlock(&g_mu);
    return w;
}

typedef struct { uintptr_t lo, hi, pool; uint64_t bid; int tracked; } rel_ent;
static rel_ent *g_rel;
static int g_nrel, g_caprel;
static uint64_t g_rel_bid;
static pthread_mutex_t g_rel_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_rel_pushed, g_rel_done, g_rel_bytes, g_rel_wired, g_rel_gone, g_rel_tr_bytes, g_rel_na_bytes;

static int rel_mode(void) {
    static int m = -2;
    if (m == -2) {
        if (!is_oot_game()) { m = 0; return 0; }
        const char *e = getenv("DM_TEX_RELEASE");
        m = !e ? 0 : !strcmp(e, "probe") ? -1 : atoi(e);
        if (m > 1) {
            MLOG("DM_TEX_RELEASE=%d clamped to 1 (CPU-visible texture pools preserved to prevent Hyrule Field corruption)", m);
            m = 1;
        }
        if (m) MLOG("guest copy release of uploaded textures: %s",
                    m < 0 ? "probe (logs only)" : m == 1 ? "CPU_NO_ACCESS pools" : "CPU_NO_ACCESS and CPU-visible pools");
    }
    return m;
}

static int rel_method(void) {
    static int m = -1;
    if (m < 0) {
        const char *e = getenv("DM_TEX_RELEASE_METHOD");
        m = e && !strcmp(e, "free");
    }
    return m;
}

typedef struct { uint64_t ser, size; uint32_t fmt, w, h, dep, lv, tgt; } rel_don;
static nvn_hmap g_reldon = {.klen = 8};

static void rel_push(const tex_t *t, int stamped) {
    if (!is_oot_game()) return;
    int mode = rel_mode();
    if (!mode || !t->mem || !t->pool || !t->L.size || (t->pool->flags & NVN_MEMORY_POOL_FLAGS_VIRTUAL) || t->d.samples > 1) return;
    int noacc = (t->pool->flags & NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS) != 0;
    if (!noacc && (!stamped || mode == 1)) return;
    uintptr_t lo = (uintptr_t)t->mem, hi = lo + t->L.size, pg = (uintptr_t)getpagesize();
    if (((lo + pg - 1) & ~(pg - 1)) >= (hi & ~(pg - 1))) return;
    pthread_mutex_lock(&g_rel_mu);
    if (g_nrel == g_caprel) {
        g_caprel = g_caprel ? g_caprel * 2 : 1024;
        g_rel = realloc_or_die(g_rel, g_caprel * sizeof *g_rel, "release list");
    }
    g_rel[g_nrel++] = (rel_ent){lo, hi, (uintptr_t)t->pool->mem, 0, stamped};
    atomic_fetch_add(&g_rel_pushed, 1);
    {
        uint64_t k = lo;
        rel_don *e = nvn_hm_get(&g_reldon, &k);
        if (!e && (e = malloc(sizeof *e))) nvn_hm_put(&g_reldon, &k, e);
        if (e) *e = (rel_don){t->serial, t->L.size, t->d.format, t->d.width, t->d.height, t->d.depth, t->d.levels, t->d.target};
    }
    pthread_mutex_unlock(&g_rel_mu);
}

static uint64_t rel_close(void) {
    if (!is_oot_game()) return 0;
    uint64_t bid = 0;
    pthread_mutex_lock(&g_rel_mu);
    for (int i = 0; i < g_nrel; i++) {
        if (!g_rel[i].bid) {
            if (!bid) bid = ++g_rel_bid;
            g_rel[i].bid = bid;
        }
    }
    pthread_mutex_unlock(&g_rel_mu);
    return bid;
}

static nvn_hmap g_relpg = {.klen = 8};
static pthread_mutex_t g_relpg_mu = PTHREAD_MUTEX_INITIALIZER;

static void relpg_note(uintptr_t a, uintptr_t b) {
    pthread_mutex_lock(&g_relpg_mu);
    for (uint64_t pg = a >> 14; pg < (b + 16383) >> 14; pg++) {
        if (!nvn_hm_get(&g_relpg, &pg)) nvn_hm_put(&g_relpg, &pg, (void *)1);
    }
    pthread_mutex_unlock(&g_relpg_mu);
}

static _Atomic uint64_t g_reldon_used, g_reldon_miss;

static id<MTLTexture> rel_donor(const tex_t *t, id<MTLTexture> mt) {
    if (!is_oot_game()) return nil;
    static int on = -1;
    if (on < 0) { const char *e = getenv("DM_TEX_REL_DONOR"); on = !e || atoi(e); }
    if (!on || rel_mode() < 1 || !t->mem || !t->L.size || !g_relpg.n) return nil;
    uintptr_t lo = (uintptr_t)t->mem, hi = lo + t->L.size;
    int hit = 0;
    pthread_mutex_lock(&g_relpg_mu);
    for (uint64_t pg = lo >> 14; pg < (hi + 16383) >> 14 && !hit; pg++) hit = nvn_hm_get(&g_relpg, &pg) != NULL;
    pthread_mutex_unlock(&g_relpg_mu);
    if (!hit) return nil;
    uint64_t k = lo;
    rel_don e = {0};
    pthread_mutex_lock(&g_rel_mu);
    const rel_don *p = nvn_hm_get(&g_reldon, &k);
    if (p) e = *p;
    pthread_mutex_unlock(&g_rel_mu);
    id<MTLTexture> dt = nil;
    const char *why = "no texture released at this address";
    if (e.ser && e.ser != t->serial) {
        why = "another description";
        if (e.size == t->L.size && e.fmt == t->d.format && e.w == t->d.width && e.h == t->d.height &&
            e.dep == t->d.depth && e.lv == t->d.levels && e.tgt == t->d.target) {
            id o = tex_get(e.ser);
            NvPkg *pk = [o isKindOfClass:[NvPkg class]] ? o : nil;
            why = "no host texture";
            if (pk && !pk->sparse && pk->tex && pk->span) {
                why = "storage written since";
                if (!nvn_dirty_since_span(pk->span, t->mem, t->L.size, pk->stamp)) {
                    id<MTLTexture> s = pk->tex;
                    why = "host texture of another shape";
                    if (s.pixelFormat == mt.pixelFormat && s.width == mt.width && s.height == mt.height &&
                        s.depth == mt.depth && s.mipmapLevelCount == mt.mipmapLevelCount &&
                        s.arrayLength == mt.arrayLength && s.textureType == mt.textureType &&
                        s.sampleCount == mt.sampleCount) {
                        dt = s;
                    }
                }
            }
        }
    } else if (e.ser) {
        why = "same serial";
    }
    uint64_t n = atomic_fetch_add(dt ? &g_reldon_used : &g_reldon_miss, 1) + 1;
    if (n <= 8 || n % 500 == 0) {
        char how[96];
        if (dt) snprintf(how, sizeof how, "copied on the GPU from ser=%llu", (unsigned long long)e.ser);
        else snprintf(how, sizeof how, "%s: reads the released zero pages", why);
        MLOG("%stexture made again over released storage ser=%llu %ux%u format %#x %llu KB: %s (%llu copied, %llu not)",
             dt ? "" : "[RED] ", (unsigned long long)t->serial, t->d.width, t->d.height, t->d.format,
             (unsigned long long)(t->L.size >> 10), how,
             (unsigned long long)atomic_load(&g_reldon_used), (unsigned long long)atomic_load(&g_reldon_miss));
    }
    return dt;
}

static void rel_stats(void) {
    MLOG("  guest copy release: %llu textures queued, %llu released (%llu MB: %llu MB tracked, %llu MB CPU_NO_ACCESS), %llu left alone (pool in the residency set), %llu dropped (pool finalized first)",
         (unsigned long long)g_rel_pushed, (unsigned long long)g_rel_done, (unsigned long long)(g_rel_bytes >> 20),
         (unsigned long long)(g_rel_tr_bytes >> 20), (unsigned long long)(g_rel_na_bytes >> 20),
         (unsigned long long)g_rel_wired, (unsigned long long)g_rel_gone);
}

static void rel_run(uint64_t bid, int failed) {
    if (!is_oot_game()) return;
    int mode = rel_mode(), method = rel_method();
    pthread_mutex_lock(&g_rel_mu);
    int w = 0;
    for (int i = 0; i < g_nrel; i++) {
        rel_ent e = g_rel[i];
        if (e.bid != bid) { g_rel[w++] = e; continue; }
        if (failed) continue;
        uintptr_t pg = (uintptr_t)getpagesize(), a = (e.lo + pg - 1) & ~(pg - 1), b = e.hi & ~(pg - 1);
        if (rel_wired(a, b)) { atomic_fetch_add(&g_rel_wired, 1); continue; }
        if (mode < 0) { atomic_fetch_add(&g_rel_bytes, b - a); continue; }
        size_t n = nvn_dirty_discard((void *)e.lo, e.hi - e.lo, e.tracked, method);
        atomic_fetch_add(&g_rel_done, 1);
        if (n) relpg_note(a, b);
        atomic_fetch_add(&g_rel_bytes, n);
        atomic_fetch_add(e.tracked ? &g_rel_tr_bytes : &g_rel_na_bytes, n);
    }
    g_nrel = w;
    pthread_mutex_unlock(&g_rel_mu);
    { static _Atomic int nr; if (!(atomic_fetch_add(&nr, 1) % 40)) rel_stats(); }
}

static void rel_pool_gone(const void *mem) {
    if (!is_oot_game()) return;
    pthread_mutex_lock(&g_rel_mu);
    int w = 0;
    for (int i = 0; i < g_nrel; i++) {
        if (g_rel[i].pool == (uintptr_t)mem) { atomic_fetch_add(&g_rel_gone, 1); continue; }
        g_rel[w++] = g_rel[i];
    }
    g_nrel = w;
    pthread_mutex_unlock(&g_rel_mu);
}

static int cond_conservative(void) {
    static int v = -1;
    if (v < 0) {
        if (!is_oot_game()) { v = 0; return 0; }
        const char *e = getenv("DM_NVN_COND_CONSERVATIVE");
        v = e && atoi(e) == 1;
        if (v) MLOG("DM_NVN_COND_CONSERVATIVE=1: samples-passed conditions keep drawing");
    }
    return v;
}

static size_t mtl_pf_bytes(MTLPixelFormat pf);
static uint64_t g_rtl_n, g_rtl_bytes;
static void rt_lossy(MTLTextureDescriptor *d) {
    if (!is_oot_game()) return;
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("DM_NVN_RT_LOSSY");
        on = e ? atoi(e) != 0 : DM_GAME_RT_LOSSY;
        if (on) MLOG("render targets: lossy compression for colour targets drawn as attachments only (profile rt_lossy; DM_NVN_RT_LOSSY=0 turns it off)");
    }
    if (!on || d.storageMode != MTLStorageModePrivate) return;
    if ((d.usage & (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView)) != MTLTextureUsageRenderTarget) return;
    if (d.textureType != MTLTextureType2D && d.textureType != MTLTextureType2DArray) return;
    MTLPixelFormat f = d.pixelFormat;
    if (f != MTLPixelFormatRGBA8Unorm && f != MTLPixelFormatRGBA8Unorm_sRGB &&
        f != MTLPixelFormatBGRA8Unorm && f != MTLPixelFormatBGRA8Unorm_sRGB &&
        f != MTLPixelFormatRGBA16Float) return;
    d.allowGPUOptimizedContents = YES;
    d.compressionType = MTLTextureCompressionTypeLossy;
    g_rtl_n++;
    g_rtl_bytes += (uint64_t)d.width * d.height * mtl_pf_bytes(f);
}

static int g_pool_skip_retired = -1;
static int pool_skip_retired(void) {
    int v = g_pool_skip_retired;
    if (v < 0) {
        if (!is_oot_game()) { g_pool_skip_retired = 0; return 0; }
        const char *e = getenv("DM_NVN_POOL_SKIP_RETIRED");
        v = e ? atoi(e) != 0 : DM_GAME_POOL_SKIP_RETIRED;
        if (v) MLOG("pool_skip_retired: pool tables give retired texture IDs without a view the dummy");
        g_pool_skip_retired = v;
    }
    return v;
}

static int g_fb_dself_m = -1;
static int fb_dself(void) {
    if (!is_oot_game()) return 0;
    if (g_fb_dself_m < 0) g_fb_dself_m = sw_mode("DM_NVN_FB_DSELF", 1);
    return sw_on(g_fb_dself_m);
}

#endif // OOT_ENH_MEM

#ifdef OOT_ENH_UPCHAIN
#undef OOT_ENH_UPCHAIN

static int up_mfx_named(NvShader *cs);
static int up_mfx_on(void);
static int up_mfx_encode(NvShader *cs);
static int g_up_chain_in;
static int g_up_chain_refused;

static int up_chain_role(NvShader *cs) {
#ifdef DM_GAME_UPSCALER_CHAIN
    static const char *c = DM_GAME_UPSCALER_CHAIN;
#else
    static const char *c = "";
#endif
    if (!is_oot_game() || !*c || !cs->key[0]) return 0;
    const char *last = strchr(c, '>');
    if (!last) return 0;
    for (const char *l = last + 1; strlen(l) >= 16; l += 17) {
        if (!strncmp(l, cs->key, 16)) return 3;
        if (l[16] != '|') break;
    }
    for (const char *k = c; k < last; k += 17) {
        if (!strncmp(k, cs->key, 16)) return k == c ? 2 : 1;
    }
    return 0;
}

static int oot_up_chain_dispatch(NvShader *cs, const p_dispatch *dp) {
    if (!is_oot_game()) return 0;
    int role = up_mfx_on() && !g_up_chain_refused ? up_chain_role(cs) : 0;
    if (role == 2) {
        g_up_chain_in = 0;
        for (int i = 0; i < cs->rf.nb; i++) {
            if (cs->rf.b[i].kind == NVN_RB_TEX) {
                g_up_chain_in = (int)(tex_slot_h(S.tex[5], S.img[5], cs->rf.b[i].reg) & 0xfffff);
                break;
            }
        }
    }
    if (role == 1 || role == 2) {
        if (g_up_chain_in) return 1;
    }
    if (role == 3) {
        if (g_up_chain_in && !dp->ind && up_mfx_encode(cs)) { g_up_chain_in = 0; return 1; }
        if (g_up_chain_in) {
            g_up_chain_refused = 1;
            MLOG("[RED] upscaler chain: MetalFX refused the last stage %s; the game's chain runs from the next frame on", cs->key);
        }
        g_up_chain_in = 0;
    }
    if (!role && g_up_chain_in && up_mfx_named(cs)) {
        g_up_chain_refused = 1;
        g_up_chain_in = 0;
        MLOG("[RED] upscaler chain: %s is not the profile's last stage; the game's chain runs from the next frame on", cs->key);
    }
    return 0;
}

static float up_sharpen(void) {
    static float v = -1;
    if (v >= 0) return v;
    if (!is_oot_game()) { v = 0; return 0; }
    const char *e = getenv("DM_SHARPEN");
    v = e && *e ? (float)atof(e) : 0;
    if (v < 0 || v > 1) { MLOG("[RED] DM_SHARPEN=%s: 0 to 1; sharpening off", e); v = 0; }
    if (v > 0) MLOG("upscaler sharpening (DM_SHARPEN): %.2f, applied after %s", v,
                    up_mfx_on() == 1 ? "MetalFX" : up_mfx_on() == 2 ? "the skipped network" :
                    "nothing: the game's own upscaler runs (DM_UPSCALER=game), so it does not apply");
    return v;
}

static id<MTLTexture> up_scratch(NSUInteger w, NSUInteger h) {
    static id<MTLTexture> t;
    if (!is_oot_game()) return nil;
    if (t && (t.width != w || t.height != h)) { res_remove(t); res_commit(); defer_obj_release(t); t = nil; }
    if (!t) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        t = [g_dev newTextureWithDescriptor:td];
        if (t) { t.label = @"upscaler skip scratch"; res_add(t); res_commit(); }
    }
    return t;
}

#endif // OOT_ENH_UPCHAIN

#ifdef OOT_ENH_FRAMEGEN
#undef OOT_ENH_FRAMEGEN

// Experimental Stage-1 Frame Blend (DM_FRAMEGEN), strictly isolated to Ocarina of Time (0400486024DEC000).
// Improvements over reference stage-1 patch:
//   - fg_on() parses atoi(e) > 0 strictly and returns 0 for non-OoT games (empty DM_FRAMEGEN="" no longer activates).
//   - Pre-allocated 4-slot command allocator / buffer / shared-constant rings eliminate per-frame Metal allocation & residency churn.
//   - fg_hist_tex() commits new textures into residency and removes old resized textures cleanly.
//   - present_now() keeps its upstream 7-arg signature via _Thread_local g_fg_tls_pres_adj.

static int fg_on(void) {
    static int on = -1;
    if (on < 0) {
        if (!is_oot_game()) { on = 0; return 0; }
        const char *e = getenv("DM_FRAMEGEN");
        on = e && atoi(e) > 0;
        if (on) MLOG("display link: frame generation on (DM_FRAMEGEN): blended frames between the real ones of a settled 2-, 3- or 4-tick cadence (60 Hz: 30 -> 60 fps; 120 Hz: 60/40/30 -> 120 fps)");
    }
    return on;
}

static int fg_maxk(void) {
    static int m = 0;
    if (!m) {
        const char *e = getenv("DM_FRAMEGEN_MAXK");
        m = e ? atoi(e) : 4;
        if (m < 2) m = 2;
        if (m > 4) m = 4;
        MLOG("display link: frame generation engages up to k=%d (DM_FRAMEGEN_MAXK)", m);
    }
    return m;
}

static id<MTLRenderPipelineState> g_fg_pso;
static MTLPixelFormat g_fg_fmt;

static void fg_pipeline(MTLPixelFormat format) {
    if (!g_fg_pso || g_fg_fmt != format) {
        NSError *e = nil;
        id<MTLLibrary> lib = host_lib("present", &e);
        if (!lib) MDIE("present shader compile failed %s", e.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs_blend"];
        pd.colorAttachments[0].pixelFormat = format;
        g_fg_pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!g_fg_pso) MDIE("frame generation pipeline failed %s", e.localizedDescription.UTF8String);
        g_fg_fmt = format;
    }
}

static id<MTLTexture> g_fg_hist[2], g_fg_scr[2];
static int g_fg_scr_i;

static id<MTLTexture> fg_hist_tex(id<MTLTexture> src, id<MTLTexture> cur) {
    MTLPixelFormat pf = src.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ? MTLPixelFormatRGBA8Unorm
                      : src.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB ? MTLPixelFormatBGRA8Unorm
                      : src.pixelFormat;
    if (cur && cur.width == src.width && cur.height == src.height && cur.pixelFormat == pf) return cur;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:src.width height:src.height mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
    if (t) {
        if (cur) { res_remove(cur); defer_obj_unref(cur); }
        res_add(t);
        res_commit();
    }
    return t;
}

enum { FG_RING = 4 };
static id<MTL4CommandAllocator> g_fg_copy_alloc[FG_RING];
static id<MTL4CommandBuffer> g_fg_copy_cb[FG_RING];
static id<MTLBuffer> g_fg_copy_uv[FG_RING];
static uint64_t g_fg_copy_fence[FG_RING], g_fg_copy_done[FG_RING], g_fg_copy_seq;
static int g_fg_copy_i;

static id<MTL4CommandAllocator> g_fg_blend_alloc[FG_RING];
static id<MTL4CommandBuffer> g_fg_blend_cb[FG_RING];
static id<MTLBuffer> g_fg_blend_uv[FG_RING];
static uint64_t g_fg_blend_fence[FG_RING], g_fg_blend_done[FG_RING], g_fg_blend_seq;
static int g_fg_blend_i;

static id<MTL4CommandAllocator> g_fg_alloc4[3];
static id<MTL4CommandBuffer> g_fg_present_cb[3];
static id<MTLBuffer> g_fg_present_uv[3];
static uint64_t g_fg_alloc_fence[3], g_fg_alloc_done[3], g_fg_seq;
static int g_fg_alloc_i, g_fg_late;

static int fg_wait_slot(const uint64_t *done, const uint64_t *fence, int slot) {
    if (!fence[slot]) return 1;
    int late = 0;
    pthread_mutex_lock(&g_pq_mu);
    while (done[slot] < fence[slot]) {
        struct timespec rel = {0, 2000000};
        if (pthread_cond_timedwait_relative_np(&g_pq_cv, &g_pq_mu, &rel)) { late = 1; break; }
    }
    pthread_mutex_unlock(&g_pq_mu);
    if (late) { g_fg_late = 1; return 0; }
    return 1;
}

static int fg_copy(const tex_t *t, const int crop[4], int slot) {
    id<MTLTexture> src = tex_mtl(t);
    if (!src) return 0;
    id<MTLTexture> out = fg_hist_tex(src, g_fg_hist[slot]);
    if (!out) return 0;
    g_fg_hist[slot] = out;
    if (!g_fg_copy_alloc[0]) {
        int added = 0;
        for (int i = 0; i < FG_RING; i++) {
            g_fg_copy_alloc[i] = [g_dev newCommandAllocator];
            g_fg_copy_cb[i] = [g_dev newCommandBuffer];
            g_fg_copy_uv[i] = [g_dev newBufferWithLength:sizeof(float) * 8 options:MTLResourceStorageModeShared];
            if (!g_fg_copy_alloc[i] || !g_fg_copy_cb[i] || !g_fg_copy_uv[i]) {
                MLOG("[RED] frame generation: no command allocator or buffer ring for history copy");
                g_fg_copy_alloc[0] = nil;
                return 0;
            }
            res_add(g_fg_copy_uv[i]);
            added = 1;
        }
        if (added) res_commit();
    }
    int ri = g_fg_copy_i;
    g_fg_copy_i = (g_fg_copy_i + 1) % FG_RING;
    if (!fg_wait_slot(g_fg_copy_done, g_fg_copy_fence, ri)) return 0;
    [g_fg_copy_alloc[ri] reset];
    res_commit();
    id<MTL4CommandBuffer> cb = g_fg_copy_cb[ri];
    [cb beginCommandBufferWithAllocator:g_fg_copy_alloc[ri]];
    int kind = present_encode_m4(cb, src, out, crop, g_fg_copy_uv[ri], NULL);
    [cb endCommandBuffer];
    if (!kind) return 0;
    uint64_t seq = ++g_fg_copy_seq;
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        if (f.error) { MLOG("[RED] frame generation history copy: %s", f.error.description.UTF8String); gpu_lost_check(f.error, "frame generation"); }
        pthread_mutex_lock(&g_pq_mu);
        if (seq > g_fg_copy_done[ri]) g_fg_copy_done[ri] = seq;
        pthread_cond_broadcast(&g_pq_cv);
        pthread_mutex_unlock(&g_pq_mu);
    }];
    id<MTL4CommandBuffer> buffers[] = {cb};
    [g_q4 commit:buffers count:1 options:o];
    g_fg_copy_fence[ri] = seq;
    return 1;
}

static int fg_blend_scratch(id<MTLTexture> a, id<MTLTexture> b, float w) {
    int si = g_fg_scr_i ^ 1;
    id<MTLTexture> sc = fg_hist_tex(a, g_fg_scr[si]);
    if (!sc) return 0;
    g_fg_scr[si] = sc;
    g_fg_scr_i = si;
    static id<MTL4ArgumentTable> g_fg_args;
    if (!g_fg_args) {
        MTL4ArgumentTableDescriptor *fad = [MTL4ArgumentTableDescriptor new];
        fad.maxTextureBindCount = 2;
        fad.maxSamplerStateBindCount = 1;
        fad.maxBufferBindCount = 1;
        NSError *fae = nil;
        g_fg_args = [g_dev newArgumentTableWithDescriptor:fad error:&fae];
        if (!g_fg_args) {
            MLOG("[RED] frame generation: failed to create argument table: %s", fae ? fae.localizedDescription.UTF8String : "unknown");
            return 0;
        }
    }
    if (!g_fg_blend_alloc[0]) {
        int added = 0;
        for (int i = 0; i < FG_RING; i++) {
            g_fg_blend_alloc[i] = [g_dev newCommandAllocator];
            g_fg_blend_cb[i] = [g_dev newCommandBuffer];
            g_fg_blend_uv[i] = [g_dev newBufferWithLength:sizeof(float) * 12 options:MTLResourceStorageModeShared];
            if (!g_fg_blend_alloc[i] || !g_fg_blend_cb[i] || !g_fg_blend_uv[i]) {
                MLOG("[RED] frame generation: no command allocator or buffer ring for blend");
                g_fg_blend_alloc[0] = nil;
                return 0;
            }
            res_add(g_fg_blend_uv[i]);
            added = 1;
        }
        if (added) res_commit();
    }
    int ri = g_fg_blend_i;
    g_fg_blend_i = (g_fg_blend_i + 1) % FG_RING;
    if (!fg_wait_slot(g_fg_blend_done, g_fg_blend_fence, ri)) return 0;
    fg_pipeline(sc.pixelFormat);
    [g_fg_blend_alloc[ri] reset];
    id<MTL4CommandBuffer> cb = g_fg_blend_cb[ri];
    [cb beginCommandBufferWithAllocator:g_fg_blend_alloc[ri]];
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = sc;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    if (!en) { MLOG("[RED] failed to create the frame generation render encoder"); [cb endCommandBuffer]; return 0; }
    [en barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];
    [en setArgumentTable:g_fg_args atStages:MTLRenderStageFragment];
    [g_fg_args setTexture:a.gpuResourceID atIndex:0];
    [g_fg_args setTexture:b.gpuResourceID atIndex:1];
    [g_fg_args setSamplerState:g_blit_samp.gpuResourceID atIndex:0];
    id<MTLBuffer> uvb = g_fg_blend_uv[ri];
    float *uv = uvb.contents;
    NSUInteger tw = a.width, th = a.height;
    uv[0] = 0; uv[1] = 0; uv[2] = 1; uv[3] = 1;
    uv[4] = 0.5f / tw; uv[5] = 0.5f / th; uv[6] = (tw - 0.5f) / tw; uv[7] = (th - 0.5f) / th;
    if (atomic_load_explicit(&g_origin_ll, memory_order_relaxed)) { uv[1] += uv[3]; uv[3] = -uv[3]; }
    uv[8] = w; uv[9] = uv[10] = uv[11] = 0;
    [g_fg_args setAddress:uvb.gpuAddress atIndex:0];
    [en setViewport:(MTLViewport){0, 0, (double)sc.width, (double)sc.height, 0, 1}];
    [en setRenderPipelineState:g_fg_pso];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    m4_end(en);
    [cb endCommandBuffer];
    uint64_t seq = ++g_fg_blend_seq;
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        if (f.error) { MLOG("[RED] frame generation blend: %s", f.error.description.UTF8String); gpu_lost_check(f.error, "frame generation"); }
        pthread_mutex_lock(&g_pq_mu);
        if (seq > g_fg_blend_done[ri]) g_fg_blend_done[ri] = seq;
        pthread_cond_broadcast(&g_pq_cv);
        pthread_mutex_unlock(&g_pq_mu);
    }];
    id<MTL4CommandBuffer> buffers[] = {cb};
    [g_q4 commit:buffers count:1 options:o];
    g_fg_blend_fence[ri] = seq;
    return 1;
}

static int fg_present_blend(id<CAMetalDrawable> dr, id<MTLTexture> prev, id<MTLTexture> cur, float w) {
    if (!dr) return 0;
    if (!fg_blend_scratch(prev, cur, w)) return 0;
    if (!g_fg_alloc4[0]) {
        int added = 0;
        for (int i = 0; i < 3; i++) {
            g_fg_alloc4[i] = [g_dev newCommandAllocator];
            g_fg_present_cb[i] = [g_dev newCommandBuffer];
            g_fg_present_uv[i] = [g_dev newBufferWithLength:sizeof(float) * 8 options:MTLResourceStorageModeShared];
            if (!g_fg_alloc4[i] || !g_fg_present_cb[i] || !g_fg_present_uv[i]) { g_fg_alloc4[0] = nil; return 0; }
            res_add(g_fg_present_uv[i]);
            added = 1;
        }
        if (added) res_commit();
    }
    int alloc_i = g_fg_alloc_i;
    g_fg_alloc_i = (g_fg_alloc_i + 1) % 3;
    if (!fg_wait_slot(g_fg_alloc_done, g_fg_alloc_fence, alloc_i)) return 0;
    [g_fg_alloc4[alloc_i] reset];
    [g_q4 waitForDrawable:dr];
    id<MTL4CommandBuffer> cb = g_fg_present_cb[alloc_i];
    [cb beginCommandBufferWithAllocator:g_fg_alloc4[alloc_i]];
    static const int whole[4] = {0};
    int kind = present_encode_m4(cb, g_fg_scr[g_fg_scr_i], dr.texture, whole, g_fg_present_uv[alloc_i], &g_fx_present);
    [cb endCommandBuffer];
    if (!kind) { [g_q4 signalDrawable:dr]; return -1; }
    uint64_t seq = ++g_fg_seq;
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        if (f.error) { MLOG("[RED] frame generation command buffer error: %s", f.error.description.UTF8String); gpu_lost_check(f.error, "frame generation"); }
        pthread_mutex_lock(&g_pq_mu);
        if (seq > g_fg_alloc_done[alloc_i]) g_fg_alloc_done[alloc_i] = seq;
        pthread_cond_broadcast(&g_pq_cv);
        pthread_mutex_unlock(&g_pq_mu);
    }];
    id<MTL4CommandBuffer> buffers[] = {cb};
    [g_q4 commit:buffers count:1 options:o];
    [g_q4 signalDrawable:dr];
    g_fg_alloc_fence[alloc_i] = seq;
    [dr present];
    return 1;
}

static pq_item g_fg_held;
static uint64_t g_fg_held_ticket;
static double g_fg_held_target;
static int g_fg_have_held;
static int g_fg_plan_k, g_fg_plan_left;
static int g_fg_last_slot = -1;
#ifdef OOT_NO_TEX_PIN
static inline void mtl_tex_unpin(uint64_t s) { (void)s; }
#endif
int mtl_link_rate(void);
static inline double fg_tick_sec(void) {
    int r = mtl_link_rate();
    return 1.0 / (double)(r >= 120 ? 120 : 60);
}
static const double fg_warm_first_s = 1.5;
static const double fg_warm_again_s = 0.5;
static const double fg_warm_cap_s = 10.0;
static const double fg_cost_limit = 0.005;
static int g_fg_engaged, g_fg_warmed_once, g_fg_k;
static double g_fg_again_s;
static int g_fg_slow, g_fg_run, g_fg_off;
static double g_fg_base_s, g_fg_eng_t0;
static int g_fg_eng_n;
static double g_fg_st_t;
static int g_fg_st_plans, g_fg_st_off;

#define FG_WIN 16
static uint8_t g_fg_win[FG_WIN];
static int g_fg_win_i, g_fg_win_n;
static int g_fg_k_est;
static double g_fg_stable_since;
static double g_fg_arr_t;
static uint64_t g_fg_seen_in;

static void fg_leave(void) {
    g_fg_engaged = 0; g_fg_run = 0; g_fg_off = 0; g_fg_slow = 0; g_fg_eng_t0 = 0; g_fg_last_slot = -1;
    if (g_fg_have_held) g_fg_plan_left = 1;
    g_fg_win_n = 0; g_fg_win_i = 0; g_fg_k_est = 0; g_fg_stable_since = 0;
}

static void fg_backoff(const char *why) {
    if (g_fg_engaged) {
        double w = g_fg_run < 300 ? (g_fg_again_s > 0 ? g_fg_again_s : fg_warm_again_s) * 2 : fg_warm_again_s;
        if (w > fg_warm_cap_s) w = fg_warm_cap_s;
        g_fg_again_s = w;
        MLOG("display link: frame generation disengaged (%s); back after %.1f s of a settled cadence", why, w);
    }
    fg_leave();
}

static void fg_shift(const char *why) {
    if (g_fg_engaged) MLOG("display link: frame generation paused (%s); re-learning the cadence", why);
    fg_leave();
}

static void fg_watch(double t0) {
    if (g_fg_late || (t0 > 0 && CACurrentMediaTime() - t0 > fg_cost_limit)) {
        if (g_fg_late || ++g_fg_slow >= 3) fg_backoff(g_fg_late ? "the GPU was still busy with the previous generated frame" : "the generation work ran over its time budget");
    } else {
        g_fg_slow = 0;
    }
}

static double fg_win_mean(void) {
    int n = g_fg_win_n;
    if (n <= 0) return 0;
    int s = 0;
    for (int i = 0; i < n; i++) s += g_fg_win[i];
    return (double)s / n;
}

static void fg_cad_eval(double now) {
    if (g_fg_win_n < 12) { g_fg_k_est = 0; g_fg_stable_since = 0; return; }
    uint8_t s[FG_WIN];
    int n = g_fg_win_n;
    for (int i = 0; i < n; i++) s[i] = g_fg_win[i];
    for (int i = 1; i < n; i++) { uint8_t v = s[i]; int j = i - 1; while (j >= 0 && s[j] > v) { s[j + 1] = s[j]; j--; } s[j + 1] = v; }
    int med = s[(n - 1) / 2], near = 0;
    for (int i = 0; i < n; i++) if (s[i] + 1 >= med && s[i] <= med + 1) near++;
    int kc = med;
    double mean = fg_win_mean();
    if (mean < med - 0.25) kc = (int)(mean + 0.25);
    int k = (near * 100 >= n * 85 && kc >= 2 && kc <= fg_maxk()) ? kc : 0;
    if (k && k == g_fg_k_est) return;
    g_fg_k_est = k;
    g_fg_stable_since = k ? now : 0;
}

static void fg_cad_note(int gap, double now) {
    int raw = gap;
    if (gap > 12) gap = 12;
    if (gap < 0) gap = 0;
    g_fg_win[g_fg_win_i] = (uint8_t)gap;
    g_fg_win_i = (g_fg_win_i + 1) % FG_WIN;
    if (g_fg_win_n < FG_WIN) g_fg_win_n++;
    fg_cad_eval(now);
    if (!g_fg_engaged) return;
    if (raw >= 24) { fg_backoff("a stall"); return; }
    if (gap + 1 < g_fg_k || gap > g_fg_k + 1) { if (++g_fg_off >= 2) { fg_shift("the game's cadence moved"); return; } } else g_fg_off = 0;
    if (!g_fg_k_est) { fg_backoff("the cadence broke"); return; }
    if (g_fg_k_est != g_fg_k) { if (now - g_fg_stable_since >= 1.0) fg_shift("the settled cadence changed"); return; }
    if (!g_fg_eng_t0) { g_fg_eng_t0 = now; g_fg_eng_n = 0; }
    else if (++g_fg_eng_n >= 1 && now - g_fg_eng_t0 >= 3.0) {
        double per = (now - g_fg_eng_t0) / g_fg_eng_n;
        if (g_fg_base_s > 0 && per > g_fg_base_s * 1.12) { fg_backoff("the game's frame rate fell under generation"); return; }
        g_fg_eng_t0 = now;
        g_fg_eng_n = 0;
    }
}

static int g_fg_rate_was;

static void fg_cad_tick(double target_ts) {
    int rate = mtl_link_rate();
    if (g_fg_rate_was && g_fg_rate_was != rate) {
        fg_shift("the display link rate changed");
        g_fg_seen_in = 0;
        g_fg_arr_t = 0;
    }
    g_fg_rate_was = rate;
    if ((g_dm_present_link == 1 || g_dm_present_link == 2) && (rate == 60 || rate == 120) && g_pq_in != g_fg_seen_in) {
        uint64_t fg_n = g_pq_in - g_fg_seen_in;
        if (g_fg_seen_in && g_fg_arr_t > 0) {
            fg_cad_note((int)((target_ts - g_fg_arr_t) / fg_tick_sec() + 0.5), CACurrentMediaTime());
            for (uint64_t q = 1; q < fg_n && q < 4; q++) fg_cad_note(0, CACurrentMediaTime());
        }
        g_fg_seen_in = g_pq_in;
        g_fg_arr_t = target_ts;
    }
}

static void fg_drop_held(void) {
    if (!g_fg_have_held) return;
    uint64_t hticket = g_fg_held_ticket;
    g_pres[hticket % PRING] = (pres_ent){hticket, -1};
    mtl_tex_unpin(g_fg_held.t.serial);
    g_fg_have_held = 0;
    g_fg_plan_left = 0;
    g_fg_last_slot = -1;
    if (hticket > g_pq_done) g_pq_done = hticket;
    pthread_cond_broadcast(&g_pq_cv);
}

// Called with g_pq_mu locked when g_fg_have_held && g_dm_present_link && !g_rescue_mode.
// Returns 1 if the display-link callback handled the tick and unlocked g_pq_mu.
static int fg_handle_held(CAMetalDisplayLinkUpdate *update, double cb) {
    if (g_fg_plan_left > 1 && g_pq_in == g_pq_read && g_fg_engaged && g_fg_last_slot >= 0 && update.drawable) {
        int fk = g_fg_plan_k, fj = fk - g_fg_plan_left + 1, fsl = g_fg_last_slot;
        pthread_mutex_unlock(&g_pq_mu);
        g_fg_late = 0;
        double fg_t0 = CACurrentMediaTime();
        int fb = fg_present_blend(update.drawable, g_fg_hist[fsl ^ 1], g_fg_hist[fsl], (float)fj / (float)fk);
        fg_watch(fg_t0);
        pthread_mutex_lock(&g_pq_mu);
        if (!g_fg_have_held) { pthread_mutex_unlock(&g_pq_mu); return 1; }
        if (fb == 1 || fb < 0) { if (g_fg_plan_left > 1) g_fg_plan_left--; pthread_mutex_unlock(&g_pq_mu); return 1; }
        g_fg_plan_left = 1;
    }
    pq_item hit = g_fg_held;
    uint64_t hticket = g_fg_held_ticket;
    double adj = g_fg_held_target - update.targetPresentationTimestamp;
    g_fg_have_held = 0;
    g_fg_plan_left = 0;
    if (adj < -fg_tick_sec() * (g_fg_plan_k + 4)) {
        g_pres[hticket % PRING] = (pres_ent){hticket, -1};
        g_link_dropped++;
        g_fg_last_slot = -1;
        mtl_tex_unpin(hit.t.serial);
        if (hticket > g_pq_done) g_pq_done = hticket;
        pthread_cond_broadcast(&g_pq_cv);
        if (g_pq_read < g_pq_in) return 0;
        pthread_mutex_unlock(&g_pq_mu);
        return 1;
    }
    {
        link_ent le = g_link_ring[hticket % PRING];
        le.target = update.targetPresentationTimestamp;
        le.lead_ms = (update.targetPresentationTimestamp - cb) * 1e3;
        g_link_ring[hticket % PRING] = le;
    }
    pthread_mutex_unlock(&g_pq_mu);
    int hsubmitted;
    g_fg_tls_pres_adj = adj;
    @autoreleasepool {
        hsubmitted = present_now(&hit.t, hit.period, hit.frame, hticket, hit.crop, update.drawable, update.targetPresentationTimestamp);
        mtl_tex_unpin(hit.t.serial);
    }
    g_link_hold_until = 0;
    if (!hsubmitted) {
        pthread_mutex_lock(&g_pq_mu);
        if (hticket > g_pq_done) g_pq_done = hticket;
        pthread_cond_broadcast(&g_pq_cv);
        pthread_mutex_unlock(&g_pq_mu);
    }
    return 1;
}

static int fg_take_or_hold(const pq_item *it, uint64_t ticket, CAMetalDisplayLinkUpdate *update, int fg_ticks) {
    int fg_rate = mtl_link_rate();
    int fg_mode_ok = (g_dm_present_link == 1 || g_dm_present_link == 2) && (fg_rate == 60 || fg_rate == 120);
    if (!fg_mode_ok) fg_backoff("the link mode changed");
    if (fg_mode_ok && !g_fg_engaged && g_fg_k_est >= 2 && g_fg_stable_since > 0 && fg_ticks + 1 >= g_fg_k_est && fg_ticks <= g_fg_k_est + 1) {
        double fg_now = CACurrentMediaTime();
        double fg_need = g_fg_warmed_once ? (g_fg_again_s > 0 ? g_fg_again_s : fg_warm_again_s) : fg_warm_first_s;
        if (fg_now - g_fg_stable_since >= fg_need) {
            g_fg_engaged = 1; g_fg_warmed_once = 1; g_fg_k = g_fg_k_est;
            g_fg_run = 0; g_fg_off = 0; g_fg_eng_t0 = 0; g_fg_st_t = fg_now; g_fg_st_plans = g_fg_st_off = 0;
            g_fg_base_s = fg_win_mean() * fg_tick_sec();
            MLOG("display link: frame generation engaged at k=%d (about %.0f real fps -> %d presented fps) after %.1f s of a settled cadence",
                 g_fg_k, g_fg_base_s > 0 ? 1.0 / g_fg_base_s : 0.0, fg_rate, fg_now - g_fg_stable_since);
        }
    }
    if (g_fg_engaged) {
        double fg_now = CACurrentMediaTime();
        if (fg_now - g_fg_st_t >= 5.0) {
            MLOG("display link: frame generation k=%d: %d planned, %d off the rhythm in %.0f s",
                 g_fg_k, g_fg_st_plans, g_fg_st_off, fg_now - g_fg_st_t);
            g_fg_st_t = fg_now;
            g_fg_st_plans = g_fg_st_off = 0;
        }
    }
    if (g_fg_engaged && (fg_ticks + 1 < g_fg_k || fg_ticks > g_fg_k + 1)) {
        g_fg_last_slot = -1;
        g_fg_st_off++;
        return 0;
    }
    if (!g_fg_engaged) return 0;
    g_fg_run++;
    g_fg_st_plans++;
    int slot = g_fg_last_slot < 0 ? 0 : g_fg_last_slot ^ 1;
    double fg_t0 = CACurrentMediaTime();
    g_fg_late = 0;
    if (fg_copy(&it->t, it->crop, slot)) {
        int seeded = g_fg_last_slot < 0;
        int blended = seeded ? 0 : fg_present_blend(update.drawable, g_fg_hist[g_fg_last_slot], g_fg_hist[slot], 1.0f / (float)g_fg_k);
        g_fg_last_slot = slot;
        fg_watch(seeded ? 0 : fg_t0);
        if (blended == 1 || blended < 0) {
            pthread_mutex_lock(&g_pq_mu);
            g_fg_held = *it;
            g_fg_held_ticket = ticket;
            g_fg_held_target = update.targetPresentationTimestamp;
            g_fg_have_held = 1;
            g_fg_plan_k = g_fg_k;
            g_fg_plan_left = g_fg_engaged ? g_fg_k - 1 : 1;
            pthread_mutex_unlock(&g_pq_mu);
            return 1;
        }
    } else {
        g_fg_last_slot = -1;
    }
    return 0;
}

#endif // OOT_ENH_FRAMEGEN
