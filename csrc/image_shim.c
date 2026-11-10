// PNG load → downscale → PNG encode for MCP images in the Linux build (Windows uses WIC).
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
