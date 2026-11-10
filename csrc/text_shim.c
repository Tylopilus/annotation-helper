// Word-wrapped text into a BGRA buffer with stb_truetype (Linux build: the request
// banner; Windows uses GDI). Fonts are loaded from files found at runtime.
#define STB_TRUETYPE_IMPLEMENTATION
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "stb_truetype.h"

typedef struct {
    unsigned char *data;
    stbtt_fontinfo info;
} font_t;

static font_t g_fonts[4];
static int g_nfonts;

// Returns a font handle (>= 0) or -1.
int ah_font_load(const char *path) {
    if (g_nfonts == 4) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return -1; }
    unsigned char *d = (unsigned char *)malloc((size_t)n);
    if (!d || fread(d, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(d); return -1; }
    fclose(f);
    font_t *ft = &g_fonts[g_nfonts];
    if (!stbtt_InitFont(&ft->info, d, stbtt_GetFontOffsetForIndex(d, 0))) { free(d); return -1; }
    ft->data = d;
    return g_nfonts++;
}

static int next_cp(const char **s) {
    const unsigned char *p = (const unsigned char *)*s;
    int c = p[0], n = 1;
    if (c < 0x80) {
    } else if ((c & 0xE0) == 0xC0) { c &= 0x1F; n = 2; }
    else if ((c & 0xF0) == 0xE0) { c &= 0x0F; n = 3; }
    else if ((c & 0xF8) == 0xF0) { c &= 0x07; n = 4; }
    else { *s += 1; return 0xFFFD; }
    for (int i = 1; i < n; i++) {
        if ((p[i] & 0xC0) != 0x80) { *s += i; return 0xFFFD; }
        c = (c << 6) | (p[i] & 0x3F);
    }
    *s += n;
    return c;
}

static float word_width(font_t *f, float scale, const char *s, const char *end) {
    float w = 0;
    int prev = 0;
    while (s < end) {
        int cp = next_cp(&s);
        int adv, lsb;
        stbtt_GetCodepointHMetrics(&f->info, cp, &adv, &lsb);
        if (prev) w += scale * stbtt_GetCodepointKernAdvance(&f->info, prev, cp);
        w += scale * adv;
        prev = cp;
    }
    return w;
}

static void draw_glyph(font_t *f, float scale, int cp, float x, int baseline, uint8_t *bgra, int bw, int bh, uint32_t rgb) {
    int x0, y0, x1, y1;
    stbtt_GetCodepointBitmapBoxSubpixel(&f->info, cp, scale, scale, x - (int)x, 0, &x0, &y0, &x1, &y1);
    int gw = x1 - x0, gh = y1 - y0;
    if (gw <= 0 || gh <= 0) return;
    unsigned char *m = (unsigned char *)malloc((size_t)gw * gh);
    if (!m) return;
    stbtt_MakeCodepointBitmapSubpixel(&f->info, m, gw, gh, gw, scale, scale, x - (int)x, 0, cp);
    int ox = (int)x + x0, oy = baseline + y0;
    uint8_t r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
    for (int j = 0; j < gh; j++) {
        int py = oy + j;
        if (py < 0 || py >= bh) continue;
        for (int i = 0; i < gw; i++) {
            int px = ox + i;
            if (px < 0 || px >= bw) continue;
            unsigned a = m[j * gw + i];
            if (!a) continue;
            uint8_t *d = bgra + ((size_t)py * bw + px) * 4;
            d[0] = (uint8_t)((b * a + d[0] * (255 - a)) / 255);
            d[1] = (uint8_t)((g * a + d[1] * (255 - a)) / 255);
            d[2] = (uint8_t)((r * a + d[2] * (255 - a)) / 255);
        }
    }
    free(m);
}

// Lays out `text` wrapped at `max_w` pixels; draws it at (x, y) into `bgra` when non-NULL.
// Returns the height used; the widest line goes to *out_w.
int ah_text(int font, float px, const char *text, int max_w, uint8_t *bgra, int bw, int bh, int x, int y, uint32_t rgb, int *out_w) {
    if (font < 0 || font >= g_nfonts) return 0;
    font_t *f = &g_fonts[font];
    float scale = stbtt_ScaleForPixelHeight(&f->info, px);
    int asc, desc, gap;
    stbtt_GetFontVMetrics(&f->info, &asc, &desc, &gap);
    int line_h = (int)(scale * (asc - desc + gap) + 0.99f);
    float space = word_width(f, scale, " ", " " + 1);
    const char *s = text, *end = text + strlen(text);
    int lines = 0, widest = 0;
    while (s < end) {
        // Collect words for one line.
        const char *line_start = s, *line_end = s;
        float w = 0;
        const char *p = s;
        while (p < end) {
            const char *ws = p;
            while (ws < end && *ws == ' ') ws++;
            const char *we = ws;
            while (we < end && *we != ' ') we++;
            if (we == ws) { p = we; break; }
            float ww = word_width(f, scale, ws, we);
            float add = (line_end == line_start ? 0 : space) + ww;
            if (line_end != line_start && w + add > max_w) break;
            w += add;
            line_end = we;
            p = we;
        }
        if (line_end == line_start) { // single word wider than max_w, or only spaces
            if (p >= end) break;
            line_end = p;
        }
        if (bgra) {
            int baseline = y + lines * line_h + (int)(scale * asc + 0.5f);
            float cx = (float)x;
            int prev = 0;
            const char *q = line_start;
            while (q < line_end && *q == ' ') q++;
            while (q < line_end) {
                int cp = next_cp(&q);
                if (prev) cx += scale * stbtt_GetCodepointKernAdvance(&f->info, prev, cp);
                if (cp != ' ') draw_glyph(f, scale, cp, cx, baseline, bgra, bw, bh, rgb);
                int adv, lsb;
                stbtt_GetCodepointHMetrics(&f->info, cp, &adv, &lsb);
                cx += scale * adv;
                prev = cp;
            }
        }
        if ((int)(w + 0.99f) > widest) widest = (int)(w + 0.99f);
        lines++;
        s = line_end;
        while (s < end && *s == ' ') s++;
    }
    if (out_w) *out_w = widest;
    return lines * line_h;
}
