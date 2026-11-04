// Software decoding of BC1–BC7 textures (bc_soft.h). Formats follow the BCn specification (Direct3D 11 / Vulkan "BC" formats):
//   BC1 / BC2 / BC3: 565 endpoint colours with 2-bit indices; BC2 adds explicit 4-bit alpha, BC3 a BC4 alpha block
//   BC4 / BC5: one / two 8-bit channels, 3-bit indices, unsigned or signed
//   BC6H: HDR RGB, 14 modes of 1 or 2 subsets with endpoints of 6 to 16 bits (deltas in the transformed modes), unsigned or signed half floats
//   BC7: 8 modes of 1 to 3 subsets, optional rotation, 2 / 3 / 4-bit indices
// Checked against a reference decoder (Pillow's) block by block: win/tests/test_win.py builds this file for the PC and compares random blocks of every format and mode.
#include "bc_soft.h"
#include <string.h>
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif

int nvn_bc_soft;
int nvn_bc_astc = 1;   // BC1 / BC2 / BC3 / BC7 into ASTC 4x4 instead of RGBA8, BC6H unsigned into RG11B10F instead of RGBA16F (DM_BC_ASTC=0: the uncompressed formats)

enum { BC1 = 130, BC1_S = 131, BC2 = 132, BC2_S = 133, BC3 = 134, BC3_S = 135, BC4_U = 140, BC4_S = 141, BC5_U = 142, BC5_S = 143, BC6H_S = 150, BC6H_U = 151, BC7 = 152, BC7_S = 153 };
enum { R8U = 10, R8S = 12, RG8U = 30, RG8S = 32, RGBA8 = 70, RGBA8_S = 71, RG11B10F = 92, RGBA16F = 115, ASTC4_S = 186, ASTC4 = 204 };

uint32_t bc_soft_target(uint32_t pf, int *bpp) {
    uint32_t o; int b;
    switch (pf) {
        // ASTC 4x4: 16 bytes per 4x4 block, 1 byte a pixel instead of RGBA8's 4 (BC1's 0.5 grew 8 times); b = 4 keeps the row pitch the callers compute ((w + 3) / 4 * 4 * b = 16 bytes per block),
        // bc_soft_rows gives the rows: one per block row
        case BC1: case BC2: case BC3: case BC7: o = nvn_bc_astc ? ASTC4 : RGBA8; b = 4; break;
        case BC1_S: case BC2_S: case BC3_S: case BC7_S: o = nvn_bc_astc ? ASTC4_S : RGBA8_S; b = 4; break;
        case BC4_U: o = R8U; b = 1; break;
        case BC4_S: o = R8S; b = 1; break;
        case BC5_U: o = RG8U; b = 2; break;
        case BC5_S: o = RG8S; b = 2; break;
        case BC6H_U: o = nvn_bc_astc ? RG11B10F : RGBA16F; b = nvn_bc_astc ? 4 : 8; break;   // BC6H has no alpha and an unsigned one no sign: RG11B10F holds it in half the memory
        case BC6H_S: o = RGBA16F; b = 8; break;
        default: return 0;
    }
    if (bpp) *bpp = b;
    return o;
}
size_t bc_soft_rows(uint32_t pf, uint32_t h) { uint32_t o = bc_soft_target(pf, NULL); return o == ASTC4 || o == ASTC4_S ? (h + 3) / 4 : (size_t)(h + 3) / 4 * 4; }

// ---- bit reading, LSB first over 128 bits ----
typedef struct { uint64_t lo, hi; int pos; } bits_t;
static void bits_init(bits_t *b, const uint8_t *p) { memcpy(&b->lo, p, 8); memcpy(&b->hi, p + 8, 8); b->pos = 0; }
static uint32_t bits_get(bits_t *b, int n) {   // n ≤ 32
    if (n <= 0) return 0;
    int p = b->pos; b->pos += n;
    if (p >= 128) return 0;
    uint64_t v = p >= 64 ? b->hi >> (p - 64) : p == 0 ? b->lo : (b->lo >> p) | (b->hi << (64 - p));
    return (uint32_t)(v & ((1ull << n) - 1));
}

// ---- BC1–BC5 ----
static void rgb565(uint16_t c, int *r, int *g, int *b) {
    *r = (c >> 11) & 31; *g = (c >> 5) & 63; *b = c & 31;
    *r = (*r << 3) | (*r >> 2); *g = (*g << 2) | (*g >> 4); *b = (*b << 3) | (*b >> 2);
}
static void color_block(const uint8_t *p, uint8_t *out, size_t pitch, int four_only) {   // out: RGBA8; four_only: BC2 / BC3 (always four colours)
    uint16_t c0 = (uint16_t)(p[0] | p[1] << 8), c1 = (uint16_t)(p[2] | p[3] << 8);
    uint32_t idx = (uint32_t)p[4] | (uint32_t)p[5] << 8 | (uint32_t)p[6] << 16 | (uint32_t)p[7] << 24;
    int r[4], g[4], b[4], a[4] = {255, 255, 255, 255};
    rgb565(c0, &r[0], &g[0], &b[0]); rgb565(c1, &r[1], &g[1], &b[1]);
    if (four_only || c0 > c1) {
        r[2] = (2 * r[0] + r[1] + 1) / 3; g[2] = (2 * g[0] + g[1] + 1) / 3; b[2] = (2 * b[0] + b[1] + 1) / 3;
        r[3] = (r[0] + 2 * r[1] + 1) / 3; g[3] = (g[0] + 2 * g[1] + 1) / 3; b[3] = (b[0] + 2 * b[1] + 1) / 3;
    } else {
        r[2] = (r[0] + r[1] + 1) / 2; g[2] = (g[0] + g[1] + 1) / 2; b[2] = (b[0] + b[1] + 1) / 2;
        r[3] = g[3] = b[3] = 0; a[3] = 0;   // transparent black
    }
    for (int i = 0; i < 16; i++) {
        int k = (idx >> (2 * i)) & 3; uint8_t *o = out + (i >> 2) * pitch + (i & 3) * 4;
        o[0] = (uint8_t)r[k]; o[1] = (uint8_t)g[k]; o[2] = (uint8_t)b[k]; o[3] = (uint8_t)a[k];
    }
}
static int div7(int x) { return x >= 0 ? (x + 3) / 7 : -((-x + 3) / 7); }   // round half away from zero
static int div5(int x) { return x >= 0 ? (x + 2) / 5 : -((-x + 2) / 5); }
// One BC4 channel block into 16 bytes at out (step bytes apart within a row, pitch between rows); sgn: signed (-127..127)
static void bc4_block(const uint8_t *p, uint8_t *out, size_t pitch, int step, int sgn) {
    int e0 = sgn ? (int8_t)p[0] : p[0], e1 = sgn ? (int8_t)p[1] : p[1], v[8];
    if (sgn) { if (e0 < -127) e0 = -127; if (e1 < -127) e1 = -127; }
    v[0] = e0; v[1] = e1;
    if (e0 > e1) for (int i = 1; i < 7; i++) v[i + 1] = div7((7 - i) * e0 + i * e1);
    else { for (int i = 1; i < 5; i++) v[i + 1] = div5((5 - i) * e0 + i * e1); v[6] = sgn ? -127 : 0; v[7] = sgn ? 127 : 255; }
    uint64_t idx = 0; for (int i = 0; i < 6; i++) idx |= (uint64_t)p[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++) out[(i >> 2) * pitch + (i & 3) * step] = (uint8_t)v[(idx >> (3 * i)) & 7];
}

// ---- BC7 ----
#include "bc_tables.inc"
static const uint8_t W2[4] = {0, 21, 43, 64}, W3[8] = {0, 9, 18, 27, 37, 46, 55, 64}, W4[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};
static const uint8_t *weights(int bits) { return bits == 2 ? W2 : bits == 3 ? W3 : W4; }
static int interp(int a, int b, int w) { return ((64 - w) * a + w * b + 32) >> 6; }
static int subset_of(int ns, int part, int i) { return ns == 1 ? 0 : ns == 2 ? (BC_P2[part] >> i) & 1 : (int)(BC_P3[part] >> (2 * i)) & 3; }
static int is_anchor(int ns, int part, int i) {
    if (i == 0) return 1;
    if (ns == 2) return i == BC_A2[part];
    if (ns == 3) return i == BC_A3A[part] || i == BC_A3B[part];
    return 0;
}
typedef struct { uint8_t ns, pb, rb, isb, cb, ab, epb, spb, ib, ib2; } bc7_mode;
static const bc7_mode M7[8] = {
    {3, 4, 0, 0, 4, 0, 1, 0, 3, 0}, {2, 6, 0, 0, 6, 0, 0, 1, 3, 0}, {3, 6, 0, 0, 5, 0, 0, 0, 2, 0}, {2, 6, 0, 0, 7, 0, 1, 0, 2, 0},
    {1, 0, 2, 1, 5, 6, 0, 0, 2, 3}, {1, 0, 2, 0, 7, 8, 0, 0, 2, 2}, {1, 0, 0, 0, 7, 7, 1, 0, 4, 0}, {2, 6, 0, 0, 5, 5, 1, 0, 2, 0}};
static void bc7_block(const uint8_t *p, uint8_t *out, size_t pitch) {
    int mode = 0; while (mode < 8 && !(p[0] >> mode & 1)) mode++;
    if (mode == 8) { for (int y = 0; y < 4; y++) memset(out + y * pitch, 0, 16); return; }   // reserved: transparent black
    const bc7_mode *m = &M7[mode];
    bits_t b; bits_init(&b, p); bits_get(&b, mode + 1);
    int part = (int)bits_get(&b, m->pb), rot = (int)bits_get(&b, m->rb), isel = (int)bits_get(&b, m->isb);
    int ep[6][4] = {{0}};   // endpoints, RGBA (zeroed: a subset's pair is always read whole)
    int ne = m->ns * 2;
    for (int c = 0; c < 3; c++) for (int e = 0; e < ne; e++) ep[e][c] = (int)bits_get(&b, m->cb);
    for (int e = 0; e < ne; e++) ep[e][3] = m->ab ? (int)bits_get(&b, m->ab) : 255;
    int pbit[6] = {0};
    if (m->epb) for (int e = 0; e < ne; e++) pbit[e] = (int)bits_get(&b, 1);
    if (m->spb) for (int s = 0; s < m->ns; s++) { int v = (int)bits_get(&b, 1); pbit[2 * s] = pbit[2 * s + 1] = v; }
    for (int e = 0; e < ne; e++) for (int c = 0; c < 4; c++) {   // unquantize to 8 bits
        int bits = c < 3 ? m->cb : m->ab;
        if (c == 3 && !m->ab) continue;
        int v = ep[e][c];
        if (m->epb || m->spb) { v = v << 1 | pbit[e]; bits++; }
        v <<= 8 - bits; v |= v >> bits;
        ep[e][c] = v;
    }
    int i1[16] = {0}, i2[16] = {0};
    for (int i = 0; i < 16; i++) i1[i] = (int)bits_get(&b, m->ib - is_anchor(m->ns, part, i));
    if (m->ib2) for (int i = 0; i < 16; i++) i2[i] = (int)bits_get(&b, m->ib2 - (i == 0));
    for (int i = 0; i < 16; i++) {
        int s = subset_of(m->ns, part, i), px[4];
        int ci = i1[i], cbits = m->ib, ai = i1[i], abits = m->ib;
        if (m->ib2) { if (isel) { ci = i2[i]; cbits = m->ib2; } else { ai = i2[i]; abits = m->ib2; } }
        for (int c = 0; c < 3; c++) px[c] = interp(ep[2 * s][c], ep[2 * s + 1][c], weights(cbits)[ci]);
        px[3] = interp(ep[2 * s][3], ep[2 * s + 1][3], weights(abits)[ai]);
        if (rot) { int t = px[3]; px[3] = px[rot - 1]; px[rot - 1] = t; }
        uint8_t *o = out + (i >> 2) * pitch + (i & 3) * 4;
        o[0] = (uint8_t)px[0]; o[1] = (uint8_t)px[1]; o[2] = (uint8_t)px[2]; o[3] = (uint8_t)px[3];
    }
}

// ---- BC6H ----
// Each mode's fields in the order its bits follow the mode bits: (field, first bit, count, reversed). Fields: 0..3 = rw gw bw rx; 4..7 = gx bx ry gy; 8..11 = by rz gz bz; 12 = d
enum { RW, GW, BW, RX, GX, BX, RY, GY, BY, RZ, GZ, BZ, D };
typedef struct { uint8_t f, lo, n, rev; } fld;
typedef struct { uint8_t ns, tr, epb, dr, dg, db; const fld *f; uint8_t nf; } bc6_mode;
#define F(f, hi, lo) {f, lo, (uint8_t)((hi) - (lo) + 1), 0}
#define B(f, bit) {f, bit, 1, 0}
static const fld m0[] = {B(GY,4), B(BY,4), B(BZ,4), F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,4,0), B(GZ,4), F(GY,3,0), F(GX,4,0), B(BZ,0), F(GZ,3,0), F(BX,4,0), B(BZ,1), F(BY,3,0), F(RY,4,0), B(BZ,2), F(RZ,4,0), B(BZ,3), F(D,4,0)};
static const fld m1[] = {B(GY,5), B(GZ,4), B(GZ,5), F(RW,6,0), B(BZ,0), B(BZ,1), B(BY,4), F(GW,6,0), B(BY,5), B(BZ,2), B(GY,4), F(BW,6,0), B(BZ,3), B(BZ,5), B(BZ,4), F(RX,5,0), F(GY,3,0), F(GX,5,0), F(GZ,3,0), F(BX,5,0), F(BY,3,0), F(RY,5,0), F(RZ,5,0), F(D,4,0)};
static const fld m2[] = {F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,4,0), B(RW,10), F(GY,3,0), F(GX,3,0), B(GW,10), B(BZ,0), F(GZ,3,0), F(BX,3,0), B(BW,10), B(BZ,1), F(BY,3,0), F(RY,4,0), B(BZ,2), F(RZ,4,0), B(BZ,3), F(D,4,0)};
static const fld m3[] = {F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,3,0), B(RW,10), B(GZ,4), F(GY,3,0), F(GX,4,0), B(GW,10), F(GZ,3,0), F(BX,3,0), B(BW,10), B(BZ,1), F(BY,3,0), F(RY,3,0), B(BZ,0), B(BZ,2), F(RZ,3,0), B(GY,4), B(BZ,3), F(D,4,0)};
static const fld m4[] = {F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,3,0), B(RW,10), B(BY,4), F(GY,3,0), F(GX,3,0), B(GW,10), B(BZ,0), F(GZ,3,0), F(BX,4,0), B(BW,10), F(BY,3,0), F(RY,3,0), B(BZ,1), B(BZ,2), F(RZ,3,0), B(BZ,4), B(BZ,3), F(D,4,0)};
static const fld m5[] = {F(RW,8,0), B(BY,4), F(GW,8,0), B(GY,4), F(BW,8,0), B(BZ,4), F(RX,4,0), B(GZ,4), F(GY,3,0), F(GX,4,0), B(BZ,0), F(GZ,3,0), F(BX,4,0), B(BZ,1), F(BY,3,0), F(RY,4,0), B(BZ,2), F(RZ,4,0), B(BZ,3), F(D,4,0)};
static const fld m6[] = {F(RW,7,0), B(GZ,4), B(BY,4), F(GW,7,0), B(BZ,2), B(GY,4), F(BW,7,0), B(BZ,3), B(BZ,4), F(RX,5,0), F(GY,3,0), F(GX,4,0), B(BZ,0), F(GZ,3,0), F(BX,4,0), B(BZ,1), F(BY,3,0), F(RY,5,0), F(RZ,5,0), F(D,4,0)};
static const fld m7[] = {F(RW,7,0), B(BZ,0), B(BY,4), F(GW,7,0), B(GY,5), B(GY,4), F(BW,7,0), B(GZ,5), B(BZ,4), F(RX,4,0), B(GZ,4), F(GY,3,0), F(GX,5,0), F(GZ,3,0), F(BX,4,0), B(BZ,1), F(BY,3,0), F(RY,4,0), B(BZ,2), F(RZ,4,0), B(BZ,3), F(D,4,0)};
static const fld m8[] = {F(RW,7,0), B(BZ,1), B(BY,4), F(GW,7,0), B(BY,5), B(GY,4), F(BW,7,0), B(BZ,5), B(BZ,4), F(RX,4,0), B(GZ,4), F(GY,3,0), F(GX,4,0), B(BZ,0), F(GZ,3,0), F(BX,5,0), F(BY,3,0), F(RY,4,0), B(BZ,2), F(RZ,4,0), B(BZ,3), F(D,4,0)};
static const fld m9[] = {F(RW,5,0), B(GZ,4), B(BZ,0), B(BZ,1), B(BY,4), F(GW,5,0), B(GY,5), B(BY,5), B(BZ,2), B(GY,4), F(BW,5,0), B(GZ,5), B(BZ,3), B(BZ,5), B(BZ,4), F(RX,5,0), F(GY,3,0), F(GX,5,0), F(GZ,3,0), F(BX,5,0), F(BY,3,0), F(RY,5,0), F(RZ,5,0), F(D,4,0)};
static const fld m10[] = {F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,9,0), F(GX,9,0), F(BX,9,0)};
static const fld m11[] = {F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,8,0), B(RW,10), F(GX,8,0), B(GW,10), F(BX,8,0), B(BW,10)};
static const fld m12[] = {F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,7,0), {RW,10,2,1}, F(GX,7,0), {GW,10,2,1}, F(BX,7,0), {BW,10,2,1}};
static const fld m13[] = {F(RW,9,0), F(GW,9,0), F(BW,9,0), F(RX,3,0), {RW,10,6,1}, F(GX,3,0), {GW,10,6,1}, F(BX,3,0), {BW,10,6,1}};
#undef F
#undef B
#define N(a) a, (uint8_t)(sizeof a / sizeof *a)
// ns, transformed, endpoint bits, delta bits r g b
static const bc6_mode M6[14] = {
    {2, 1, 10, 5, 5, 5, N(m0)}, {2, 1, 7, 6, 6, 6, N(m1)}, {2, 1, 11, 5, 4, 4, N(m2)}, {2, 1, 11, 4, 5, 4, N(m3)}, {2, 1, 11, 4, 4, 5, N(m4)},
    {2, 1, 9, 5, 5, 5, N(m5)}, {2, 1, 8, 6, 5, 5, N(m6)}, {2, 1, 8, 5, 6, 5, N(m7)}, {2, 1, 8, 5, 5, 6, N(m8)}, {2, 0, 6, 6, 6, 6, N(m9)},
    {1, 0, 10, 10, 10, 10, N(m10)}, {1, 1, 11, 9, 9, 9, N(m11)}, {1, 1, 12, 8, 8, 8, N(m12)}, {1, 1, 16, 4, 4, 4, N(m13)}};
#undef N
static int bc6_mode_of(const uint8_t *p, int *mbits) {
    int m2 = p[0] & 3;
    if (m2 == 0) { *mbits = 2; return 0; }
    if (m2 == 1) { *mbits = 2; return 1; }
    *mbits = 5;
    switch (p[0] & 31) { case 0x02: return 2; case 0x06: return 3; case 0x0a: return 4; case 0x0e: return 5; case 0x12: return 6; case 0x16: return 7; case 0x1a: return 8; case 0x1e: return 9;
                         case 0x03: return 10; case 0x07: return 11; case 0x0b: return 12; case 0x0f: return 13; }
    return -1;   // reserved
}
static int sext(int v, int bits) { return bits < 32 && (v >> (bits - 1) & 1) ? v - (1 << bits) : v; }
static int unq(int x, int bits, int sgn) {
    if (!sgn) {
        if (bits >= 15) return x;
        if (x == 0) return 0;
        if (x == (1 << bits) - 1) return 0xffff;
        return ((x << 16) + 0x8000) >> bits;
    }
    if (bits >= 16) return x;
    int s = x < 0; if (s) x = -x;
    int q;
    if (x == 0) q = 0;
    else if (x >= (1 << (bits - 1)) - 1) q = 0x7fff;
    else q = ((x << 15) + 0x4000) >> (bits - 1);
    return s ? -q : q;
}
static uint16_t finish(int v, int sgn) {
    if (!sgn) return (uint16_t)((v * 31) >> 6);
    return v < 0 ? (uint16_t)(0x8000 | ((-v * 31) >> 5)) : (uint16_t)((v * 31) >> 5);
}
static void bc6_block(const uint8_t *p, uint8_t *out, size_t pitch, int sgn) {
    int mbits, mode = bc6_mode_of(p, &mbits);
    if (mode < 0) { for (int y = 0; y < 4; y++) memset(out + y * pitch, 0, 32); return; }   // reserved mode: zeros
    const bc6_mode *m = &M6[mode];
    bits_t b; bits_init(&b, p); bits_get(&b, mbits);
    int v[13] = {0};
    for (int i = 0; i < m->nf; i++) {
        const fld *f = &m->f[i];
        uint32_t x = bits_get(&b, f->n);
        if (f->rev) { uint32_t r = 0; for (int k = 0; k < f->n; k++) r |= (x >> k & 1) << (f->n - 1 - k); x = r; }
        v[f->f] |= (int)(x << f->lo);
    }
    int part = v[D], ne = m->ns * 2, e[4][3] = {{0}};   // endpoints: 0,1 = subset 0 (w, x), 2,3 = subset 1 (y, z)
    static const int map[4][3] = {{RW, GW, BW}, {RX, GX, BX}, {RY, GY, BY}, {RZ, GZ, BZ}};
    const int db[3] = {m->dr, m->dg, m->db};
    for (int k = 0; k < ne; k++) for (int c = 0; c < 3; c++) e[k][c] = v[map[k][c]];
    int mask = (1 << m->epb) - 1;
    if (sgn) for (int c = 0; c < 3; c++) e[0][c] = sext(e[0][c], m->epb);
    if (m->tr) {
        for (int k = 1; k < ne; k++) for (int c = 0; c < 3; c++) {
            int d = sext(e[k][c], db[c]);
            e[k][c] = (e[0][c] + d) & mask;
            if (sgn) e[k][c] = sext(e[k][c], m->epb);
        }
    } else if (sgn) for (int k = 1; k < ne; k++) for (int c = 0; c < 3; c++) e[k][c] = sext(e[k][c], m->epb);
    for (int k = 0; k < ne; k++) for (int c = 0; c < 3; c++) e[k][c] = unq(e[k][c], m->epb, sgn);
    int ib = m->ns == 2 ? 3 : 4;
    const uint8_t *w = weights(ib);
    for (int i = 0; i < 16; i++) {
        int anchor = i == 0 || (m->ns == 2 && i == BC_A2[part]);
        int idx = (int)bits_get(&b, ib - anchor);
        int s = m->ns == 2 ? (BC_P2[part] >> i) & 1 : 0;
        uint16_t *o = (uint16_t *)(out + (i >> 2) * pitch + (i & 3) * 8);
        for (int c = 0; c < 3; c++) o[c] = finish(interp(e[2 * s][c], e[2 * s + 1][c], w[idx]), sgn);
        o[3] = 0x3c00;   // 1.0
    }
}

int bc_soft_block(uint32_t pf, const uint8_t *p, uint8_t *out, size_t pitch) {
    switch (pf) {
        case BC1: case BC1_S: color_block(p, out, pitch, 0); return 0;
        case BC2: case BC2_S:
            color_block(p + 8, out, pitch, 1);
            for (int i = 0; i < 16; i++) { int a = (p[i >> 1] >> (4 * (i & 1))) & 15; out[(i >> 2) * pitch + (i & 3) * 4 + 3] = (uint8_t)(a | a << 4); }
            return 0;
        case BC3: case BC3_S: color_block(p + 8, out, pitch, 1); bc4_block(p, out + 3, pitch, 4, 0); return 0;
        case BC4_U: case BC4_S: bc4_block(p, out, pitch, 1, pf == BC4_S); return 0;
        case BC5_U: case BC5_S: bc4_block(p, out, pitch, 2, pf == BC5_S); bc4_block(p + 8, out + 1, pitch, 2, pf == BC5_S); return 0;
        case BC6H_U: case BC6H_S: bc6_block(p, out, pitch, pf == BC6H_S); return 0;
        case BC7: case BC7_S: bc7_block(p, out, pitch); return 0;
    }
    return -1;
}


// ---- ASTC 4x4 encoding of a decoded block (nvn_bc_astc) ----
// One partition, a 4x4 weight grid, endpoints quantized to 8 bits (so no trit / quint packing anywhere):
//   opaque: CEM 8 (LDR RGB direct), 3-bit weights   17 + 48 + 48 = 113 bits
//   alpha:  CEM 12 (LDR RGBA direct), 2-bit weights  17 + 64 + 32 = 113 bits
//   BC1 four-colour blocks: CEM 8 with 2-bit weights, its two colours as the endpoints: 1/3 and 2/3 are the weights 21 and 43 of 64, the same palette
// Block mode (ASTC spec "Block mode", bits 10:0): bits 1:0 and 4 give the weight range, 3:2 = 00 with B (8:7) = 0 and A (6:5) = 2 a 4x4 grid; 0x42 = 2-bit weights, 0x53 = 3-bit.
// Endpoint values from bit 17 up, v0 v1 ... = e0.r e1.r e0.g e1.g e0.b e1.b (e0.a e1.a); weights from bit 127 down, texel 0 first, each weight's bits LSB first.
// The decoder swaps to blue contraction when e1's RGB sum is below e0's: the endpoints are ordered so it never does (weights mirrored, the weight tables are symmetric)
static void put_bits(uint8_t *o, int pos, uint32_t v, int n) { for (int i = 0; i < n; i++) if (v >> i & 1) o[(pos + i) >> 3] |= (uint8_t)(1u << ((pos + i) & 7)); }
static void astc_write(uint8_t *o, int nc, int e[2][4], const uint8_t *wi, int wbits) {
    uint8_t m[16];
    if (e[1][0] + e[1][1] + e[1][2] < e[0][0] + e[0][1] + e[0][2]) {
        for (int c = 0; c < 4; c++) { int t = e[0][c]; e[0][c] = e[1][c]; e[1][c] = t; }
        for (int i = 0; i < 16; i++) m[i] = (uint8_t)((1 << wbits) - 1 - wi[i]);
        wi = m;
    }
    memset(o, 0, 16);
    put_bits(o, 0, wbits == 2 ? 0x42 : 0x53, 11); put_bits(o, 13, nc == 3 ? 8 : 12, 4);   // bits 12:11 = 0: one partition
    for (int c = 0; c < nc; c++) { put_bits(o, 17 + 16 * c, (uint32_t)e[0][c], 8); put_bits(o, 25 + 16 * c, (uint32_t)e[1][c], 8); }
    for (int i = 0; i < 16; i++)
        for (int k = 0; k < wbits; k++) if (wi[i] >> k & 1) { int b = 127 - (i * wbits + k); o[b >> 3] |= (uint8_t)(1u << (b & 7)); }
}
static int clamp255(float v) { int i = (int)(v + 0.5f); return i < 0 ? 0 : i > 255 ? 255 : i; }
// px: 16 texels RGBA8, row-major. Fit: the principal axis (power iteration from the bounding box diagonal), endpoints at the extreme projections, nearest weights, then one
// least-squares pass on the endpoints for those weights and the weights again
static void astc_encode(const uint8_t *px, uint8_t *o) {
    int opaque = 1; for (int i = 0; i < 16; i++) if (px[i * 4 + 3] != 255) { opaque = 0; break; }
    int nc = opaque ? 3 : 4, wbits = opaque ? 3 : 2, nl = 1 << wbits; const uint8_t *W = weights(wbits);
    float m[4] = {0}, lo[4] = {255, 255, 255, 255}, hi[4] = {0};
    for (int i = 0; i < 16; i++) for (int c = 0; c < nc; c++) { float v = px[i * 4 + c]; m[c] += v; if (v < lo[c]) lo[c] = v; if (v > hi[c]) hi[c] = v; }
    for (int c = 0; c < nc; c++) m[c] /= 16;
    float cv[4][4] = {{0}};
    for (int i = 0; i < 16; i++) for (int a = 0; a < nc; a++) for (int b = 0; b < nc; b++) cv[a][b] += (px[i * 4 + a] - m[a]) * (px[i * 4 + b] - m[b]);
    float ax[4] = {0}; for (int c = 0; c < nc; c++) ax[c] = hi[c] - lo[c];
    for (int it = 0; it < 4; it++) {
        float n[4] = {0}, l = 0;   // scaled by the largest component (no square root: the projections below divide by the axis's squared length)
        for (int a = 0; a < nc; a++) { for (int b = 0; b < nc; b++) n[a] += cv[a][b] * ax[b]; float q = n[a] < 0 ? -n[a] : n[a]; if (q > l) l = q; }
        if (l < 1e-12f) break;
        l = 1.0f / l; for (int a = 0; a < nc; a++) ax[a] = n[a] * l;
    }
    float al = 0; for (int c = 0; c < nc; c++) al += ax[c] * ax[c];
    int e[2][4] = {{0, 0, 0, 255}, {0, 0, 0, 255}}; uint8_t wi[16] = {0};
    if (al < 1e-12f) { for (int c = 0; c < nc; c++) e[0][c] = e[1][c] = clamp255(m[c]); astc_write(o, nc, e, wi, wbits); return; }   // one colour
    float tmin = 1e30f, tmax = -1e30f;
    for (int i = 0; i < 16; i++) { float d = 0; for (int c = 0; c < nc; c++) d += (px[i * 4 + c] - m[c]) * ax[c]; if (d < tmin) tmin = d; if (d > tmax) tmax = d; }
    for (int c = 0; c < nc; c++) { e[0][c] = clamp255(m[c] + ax[c] * tmin / al); e[1][c] = clamp255(m[c] + ax[c] * tmax / al); }
    for (int pass = 0; pass < 2; pass++) {
        float d[4], dd = 0; for (int c = 0; c < nc; c++) { d[c] = (float)(e[1][c] - e[0][c]); dd += d[c] * d[c]; }
        for (int i = 0; i < 16; i++) {
            float f = 0; if (dd > 0) { for (int c = 0; c < nc; c++) f += (px[i * 4 + c] - e[0][c]) * d[c]; f = f / dd * 64; }
            int best = 0; float bd = 1e30f; for (int k = 0; k < nl; k++) { float q = f - W[k]; q *= q; if (q < bd) { bd = q; best = k; } }
            wi[i] = (uint8_t)best;
        }
        if (pass) break;
        float aa = 0, ab = 0, bb = 0, ra[4] = {0}, rb[4] = {0};   // least squares: p ≈ (1 - w) e0 + w e1
        for (int i = 0; i < 16; i++) { float w = W[wi[i]] / 64.0f, u = 1 - w; aa += u * u; ab += u * w; bb += w * w; for (int c = 0; c < nc; c++) { ra[c] += u * px[i * 4 + c]; rb[c] += w * px[i * 4 + c]; } }
        float det = aa * bb - ab * ab;
        if (det < 1e-6f) break;
        for (int c = 0; c < nc; c++) { e[0][c] = clamp255((ra[c] * bb - rb[c] * ab) / det); e[1][c] = clamp255((rb[c] * aa - ra[c] * ab) / det); }
    }
    astc_write(o, nc, e, wi, wbits);
}
// BC1 four-colour block (c0 > c1): the same palette in ASTC, CEM 8 with 2-bit weights (indices 0 1 2 3 = weights 0 3 1 2)
static int bc1_astc(const uint8_t *p, uint8_t *o) {
    uint16_t c0 = (uint16_t)(p[0] | p[1] << 8), c1 = (uint16_t)(p[2] | p[3] << 8);
    if (c0 <= c1) return 0;
    int e[2][4]; rgb565(c0, &e[0][0], &e[0][1], &e[0][2]); rgb565(c1, &e[1][0], &e[1][1], &e[1][2]); e[0][3] = e[1][3] = 255;
    static const uint8_t map[4] = {0, 3, 1, 2}; uint8_t wi[16];
    uint32_t idx = (uint32_t)(p[4] | p[5] << 8 | p[6] << 16 | (uint32_t)p[7] << 24);
    for (int i = 0; i < 16; i++) wi[i] = map[idx >> (2 * i) & 3];
    astc_write(o, 3, e, wi, 2);
    return 1;
}
static uint32_t uf(uint16_t h, int mb) {   // a half float into an unsigned small float with mb mantissa bits (5-bit exponent, bias 15 for both): negatives and NaN to 0, rounded to nearest
    if (h & 0x8000) return 0;
    if ((h & 0x7c00) == 0x7c00) return (h & 0x3ff) ? 0 : 0x1fu << mb;
    uint32_t v = (uint32_t)h + (1u << (10 - mb - 1)); v >>= 10 - mb;
    return v > ((0x1fu << mb) - 1) ? ((0x1eu << mb) | ((1u << mb) - 1)) : v;   // rounding up into the infinity exponent: the largest finite value
}
static void block_out(uint32_t pf, const uint8_t *p, uint8_t *dst, size_t dst_pitch) {
    uint32_t o = bc_soft_target(pf, NULL);
    if (o == ASTC4 || o == ASTC4_S) {
        if ((pf == BC1 || pf == BC1_S) && bc1_astc(p, dst)) return;
        uint8_t px[64]; bc_soft_block(pf, p, px, 16); astc_encode(px, dst); return;
    }
    if (o == RG11B10F) {
        uint8_t hf[128]; bc6_block(p, hf, 32, 0);
        for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
            const uint8_t *q = hf + y * 32 + x * 8; uint16_t r = (uint16_t)(q[0] | q[1] << 8), g = (uint16_t)(q[2] | q[3] << 8), b = (uint16_t)(q[4] | q[5] << 8);
            uint32_t v = uf(r, 6) | uf(g, 6) << 11 | uf(b, 5) << 22; memcpy(dst + y * dst_pitch + x * 4, &v, 4);
        }
        return;
    }
    bc_soft_block(pf, p, dst, dst_pitch);
}
void bc_soft_astc_pixels(const uint8_t *rgba16, uint8_t *out) { astc_encode(rgba16, out); }   // for tests: 16 RGBA8 texels into one ASTC 4x4 block
int bc_soft_out_block(uint32_t pf, const uint8_t *block, uint8_t *out, size_t out_pitch) { if (!bc_soft_target(pf, NULL)) return -1; block_out(pf, block, out, out_pitch); return 0; }   // for tests: one block in the staging layout (16 bytes for ASTC)
static void decode_rows(uint32_t pf, const uint8_t *src, size_t src_pitch, uint32_t bw, uint32_t by0, uint32_t by1, uint8_t *dst, size_t dst_pitch, int bpp, size_t bsz) {
    uint32_t o = bc_soft_target(pf, NULL); int astc = o == ASTC4 || o == ASTC4_S;   // ASTC: one destination row per block row
    for (uint32_t by = by0; by < by1; by++)
        for (uint32_t bx = 0; bx < bw; bx++)
            block_out(pf, src + by * src_pitch + bx * bsz, dst + (size_t)by * (astc ? 1 : 4) * dst_pitch + (size_t)bx * 4 * bpp, dst_pitch);
}
int bc_soft_decode(uint32_t pf, const uint8_t *src, size_t src_pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dst_pitch) {
    int bpp; if (!bc_soft_target(pf, &bpp)) return -1;
    size_t bsz = (pf == BC1 || pf == BC1_S || pf == BC4_U || pf == BC4_S) ? 8 : 16;
    uint32_t bw = (w + 3) / 4, bh = (h + 3) / 4;
#ifdef __APPLE__
    if ((uint64_t)bw * bh >= 1024) {   // big levels on every core: block rows in bands of 8 (a 2048² level is 512 rows; the decode is otherwise the upload's longest step)
        uint32_t bands = (bh + 7) / 8;
        dispatch_apply(bands, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            uint32_t a = (uint32_t)i * 8, b = a + 8 < bh ? a + 8 : bh;
            decode_rows(pf, src, src_pitch, bw, a, b, dst, dst_pitch, bpp, bsz);
        });
        return 0;
    }
#endif
    decode_rows(pf, src, src_pitch, bw, 0, bh, dst, dst_pitch, bpp, bsz);
    return 0;
}
