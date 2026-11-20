#include "font_shim.h"
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include <stdlib.h>

struct OscFontHandle {
    stbtt_fontinfo info;
    const uint8_t* data;
};

OscFontHandle* osc_font_create(const uint8_t* ttf_bytes, size_t size) {
    if (!ttf_bytes || size == 0) return NULL;
    OscFontHandle* font = (OscFontHandle*)calloc(1, sizeof(OscFontHandle));
    if (!font) return NULL;
    font->data = ttf_bytes;
    if (!stbtt_InitFont(&font->info, ttf_bytes, 0)) {
        free(font);
        return NULL;
    }
    return font;
}

void osc_font_destroy(OscFontHandle* font) {
    if (font) {
        free(font);
    }
}

uint8_t* osc_font_render_glyph(
    OscFontHandle* font,
    uint32_t codepoint,
    float font_size_px,
    int* out_width,
    int* out_height,
    int* out_xoff,
    int* out_yoff,
    int* out_advance
) {
    if (!font) return NULL;
    float scale = stbtt_ScaleForPixelHeight(&font->info, font_size_px);

    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&font->info, (int)codepoint, &adv, &lsb);
    if (out_advance) *out_advance = (int)(adv * scale);

    int w = 0, h = 0, xoff = 0, yoff = 0;
    unsigned char* bitmap = stbtt_GetCodepointBitmap(
        &font->info,
        scale, scale,
        (int)codepoint,
        &w, &h,
        &xoff, &yoff
    );

    if (out_width) *out_width = w;
    if (out_height) *out_height = h;
    if (out_xoff) *out_xoff = xoff;
    if (out_yoff) *out_yoff = yoff;

    return bitmap;
}

void osc_font_free_bitmap(uint8_t* bitmap) {
    if (bitmap) {
        stbtt_FreeBitmap(bitmap, NULL);
    }
}
