#include "whisper_shim.h"
#include "whisper/whisper.h"

#include <stdlib.h>
#include <string.h>

OscWhisperContext* osc_whisper_init(const char *path_model) {
    if (!path_model) return NULL;
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    return (OscWhisperContext*)whisper_init_from_file_with_params(path_model, cparams);
}

void osc_whisper_free(OscWhisperContext *ctx) {
    if (ctx) {
        whisper_free((struct whisper_context*)ctx);
    }
}

int osc_whisper_process(
    OscWhisperContext *ctx,
    const float *samples,
    int n_samples,
    int n_threads,
    int enable_token_timestamps,
    const char *language
) {
    if (!ctx || !samples || n_samples <= 0) return -1;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = n_threads > 0 ? n_threads : 4;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.token_timestamps = (enable_token_timestamps != 0);
    params.max_len = 0;
    params.split_on_word = true;

    if (language && strlen(language) > 0) {
        params.language = language;
        params.detect_language = false;
    } else {
        params.language = "en";
        params.detect_language = false;
    }

    return whisper_full((struct whisper_context*)ctx, params, samples, n_samples);
}

int osc_whisper_n_segments(OscWhisperContext *ctx) {
    if (!ctx) return 0;
    return whisper_full_n_segments((struct whisper_context*)ctx);
}

int64_t osc_whisper_segment_t0(OscWhisperContext *ctx, int i_segment) {
    if (!ctx) return 0;
    return (int64_t)whisper_full_get_segment_t0((struct whisper_context*)ctx, i_segment) * 10; /* to ms */
}

int64_t osc_whisper_segment_t1(OscWhisperContext *ctx, int i_segment) {
    if (!ctx) return 0;
    return (int64_t)whisper_full_get_segment_t1((struct whisper_context*)ctx, i_segment) * 10; /* to ms */
}

const char* osc_whisper_segment_text(OscWhisperContext *ctx, int i_segment) {
    if (!ctx) return "";
    const char *txt = whisper_full_get_segment_text((struct whisper_context*)ctx, i_segment);
    return txt ? txt : "";
}

int osc_whisper_n_tokens(OscWhisperContext *ctx, int i_segment) {
    if (!ctx) return 0;
    return whisper_full_n_tokens((struct whisper_context*)ctx, i_segment);
}

const char* osc_whisper_token_text(OscWhisperContext *ctx, int i_segment, int i_token) {
    if (!ctx) return "";
    const char *txt = whisper_full_get_token_text((struct whisper_context*)ctx, i_segment, i_token);
    return txt ? txt : "";
}

int64_t osc_whisper_token_t0(OscWhisperContext *ctx, int i_segment, int i_token) {
    if (!ctx) return 0;
    whisper_token_data data = whisper_full_get_token_data((struct whisper_context*)ctx, i_segment, i_token);
    return (int64_t)data.t0 * 10; /* to ms */
}

int64_t osc_whisper_token_t1(OscWhisperContext *ctx, int i_segment, int i_token) {
    if (!ctx) return 0;
    whisper_token_data data = whisper_full_get_token_data((struct whisper_context*)ctx, i_segment, i_token);
    return (int64_t)data.t1 * 10; /* to ms */
}

float osc_whisper_token_p(OscWhisperContext *ctx, int i_segment, int i_token) {
    if (!ctx) return 0.0f;
    whisper_token_data data = whisper_full_get_token_data((struct whisper_context*)ctx, i_segment, i_token);
    return data.p;
}
