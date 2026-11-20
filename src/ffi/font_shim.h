#ifndef OPENSCREEN_FONT_SHIM_H
#define OPENSCREEN_FONT_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OscFontHandle OscFontHandle;

/* Initialize font from in-memory TTF/OTF data */
OscFontHandle* osc_font_create(const uint8_t* ttf_bytes, size_t size);
void osc_font_destroy(OscFontHandle* font);

/* Render a single codepoint to an 8-bit alpha mask with subpixel antialiasing */
/* Returns pointer to width * height alpha bytes (caller frees with osc_font_free_bitmap) */
uint8_t* osc_font_render_glyph(
    OscFontHandle* font,
    uint32_t codepoint,
    float font_size_px,
    int* out_width,
    int* out_height,
    int* out_xoff,
    int* out_yoff,
    int* out_advance
);

void osc_font_free_bitmap(uint8_t* bitmap);

#ifdef __cplusplus
}
#endif

#endif /* OPENSCREEN_FONT_SHIM_H */
