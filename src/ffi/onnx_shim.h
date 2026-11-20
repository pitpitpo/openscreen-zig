#ifndef OPENSCREEN_ONNX_SHIM_H
#define OPENSCREEN_ONNX_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OscOnnxSession OscOnnxSession;

int osc_onnx_session_create(
    const char *lib_path,
    const char *model_path,
    OscOnnxSession **out_session
);

void osc_onnx_session_free(OscOnnxSession *session);

int osc_onnx_run_segmentation(
    OscOnnxSession *session,
    const float *input_rgb_nhwc, /* 1 * 144 * 256 * 3 floats */
    float *output_mask          /* 1 * 144 * 256 * 1 floats */
);

#ifdef __cplusplus
}
#endif

#endif /* OPENSCREEN_ONNX_SHIM_H */
