#ifndef OPENSCREEN_WHISPER_SHIM_H
#define OPENSCREEN_WHISPER_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct whisper_context OscWhisperContext;

OscWhisperContext* osc_whisper_init(const char *path_model);
void osc_whisper_free(OscWhisperContext *ctx);

int osc_whisper_process(
    OscWhisperContext *ctx,
    const float *samples,
    int n_samples,
    int n_threads,
    int enable_token_timestamps,
    const char *language
);

int osc_whisper_n_segments(OscWhisperContext *ctx);
int64_t osc_whisper_segment_t0(OscWhisperContext *ctx, int i_segment);
int64_t osc_whisper_segment_t1(OscWhisperContext *ctx, int i_segment);
const char* osc_whisper_segment_text(OscWhisperContext *ctx, int i_segment);

int osc_whisper_n_tokens(OscWhisperContext *ctx, int i_segment);
const char* osc_whisper_token_text(OscWhisperContext *ctx, int i_segment, int i_token);
int64_t osc_whisper_token_t0(OscWhisperContext *ctx, int i_segment, int i_token);
int64_t osc_whisper_token_t1(OscWhisperContext *ctx, int i_segment, int i_token);
float osc_whisper_token_p(OscWhisperContext *ctx, int i_segment, int i_token);

#ifdef __cplusplus
}
#endif

#endif /* OPENSCREEN_WHISPER_SHIM_H */
