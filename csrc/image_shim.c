// PNG handling for the Linux build with stb (Windows uses WIC): downscaled PNGs for MCP,
// writing screenshots, and loading the PNG a desktop portal hands us.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include <stdint.h>
#include <stdlib.h>
#include "stb_image.h"
#include "stb_image_write.h"
#include "stb_image_resize2.h"

// Returns a malloc'ed PNG (free with ah_png_free) fitting `max_edge`, or NULL.
unsigned char *ah_png_fit(const char *path, int max_edge, int *out_len) {
    int w, h, comp;
    unsigned char *px = stbi_load(path, &w, &h, &comp, 3);
    if (!px) return NULL;
    int nw = w, nh = h, longest = w > h ? w : h;
    if (longest > max_edge) {
        nw = (int)((long long)w * max_edge / longest);
        nh = (int)((long long)h * max_edge / longest);
        if (nw < 1) nw = 1;
        if (nh < 1) nh = 1;
        unsigned char *small = stbir_resize_uint8_srgb(px, w, h, 0, NULL, nw, nh, 0, STBIR_RGB);
        stbi_image_free(px);
        if (!small) return NULL;
        px = small;
    }
    unsigned char *png = stbi_write_png_to_mem(px, nw * 3, nw, nh, 3, out_len);
    free(px);
    return png;
}

void ah_png_free(void *p) { free(p); }

// Writes opaque BGRA pixels as an RGB PNG. Returns 0 on success.
int ah_png_write_bgra(const char *path, const uint8_t *bgra, int w, int h) {
    unsigned char *rgb = (unsigned char *)malloc((size_t)w * h * 3);
    if (!rgb) return 1;
    for (size_t i = 0, n = (size_t)w * h; i < n; i++) {
        rgb[i * 3 + 0] = bgra[i * 4 + 2];
        rgb[i * 3 + 1] = bgra[i * 4 + 1];
        rgb[i * 3 + 2] = bgra[i * 4 + 0];
    }
    stbi_write_png_compression_level = 6;
    int ok = stbi_write_png(path, w, h, 3, rgb, w * 3);
    free(rgb);
    return ok ? 0 : 2;
}

// Loads a PNG as opaque BGRA (free with ah_png_free), or NULL.
uint8_t *ah_png_load_bgra(const char *path, int *w, int *h) {
    int comp;
    unsigned char *px = stbi_load(path, w, h, &comp, 4);
    if (!px) return NULL;
    for (size_t i = 0, n = (size_t)*w * *h; i < n; i++) {
        unsigned char r = px[i * 4];
        px[i * 4] = px[i * 4 + 2];
        px[i * 4 + 2] = r;
        px[i * 4 + 3] = 255;
    }
    return px;
}
