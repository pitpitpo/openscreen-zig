#include "onnx_shim.h"
#include "onnx/onnxruntime_c_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
typedef HMODULE dl_handle_t;
#define DL_OPEN(path) LoadLibraryA(path)
#define DL_SYM(h, name) (void*)GetProcAddress(h, name)
#define DL_CLOSE(h) FreeLibrary(h)
#else
#include <dlfcn.h>
typedef void* dl_handle_t;
#define DL_OPEN(path) dlopen(path, RTLD_NOW | RTLD_LOCAL)
#define DL_SYM(h, name) dlsym(h, name)
#define DL_CLOSE(h) dlclose(h)
#endif

typedef const OrtApiBase* (*OrtGetApiBaseFn)(void);

struct OscOnnxSession {
    dl_handle_t lib_handle;
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *mem_info;
};

int osc_onnx_session_create(
    const char *lib_path,
    const char *model_path,
    OscOnnxSession **out_session
) {
    if (!model_path || !out_session) return -1;
    *out_session = NULL;

    dl_handle_t lib = NULL;
    if (lib_path && strlen(lib_path) > 0) {
        lib = DL_OPEN(lib_path);
    }
    if (!lib) {
        static const char *default_libs[] = {
            "tests/fixtures/onnx/libonnxruntime.so",
            "libonnxruntime.so",
            "libonnxruntime.so.1",
            "libonnxruntime.dylib",
            "onnxruntime.dll",
            NULL
        };
        for (int i = 0; default_libs[i] != NULL; ++i) {
            lib = DL_OPEN(default_libs[i]);
            if (lib) break;
        }
    }
    if (!lib) {
        return -1;
    }

    OrtGetApiBaseFn get_base = (OrtGetApiBaseFn)DL_SYM(lib, "OrtGetApiBase");
    if (!get_base) {
        DL_CLOSE(lib);
        return -1;
    }

    const OrtApiBase *base = get_base();
    if (!base) {
        DL_CLOSE(lib);
        return -1;
    }

    /* Try latest API version (up to 27 or lower) */
    const OrtApi *api = NULL;
    for (uint32_t ver = ORT_API_VERSION; ver >= 1; --ver) {
        api = base->GetApi(ver);
        if (api) break;
    }
    if (!api) {
        DL_CLOSE(lib);
        return -1;
    }

    OscOnnxSession *s = (OscOnnxSession *)calloc(1, sizeof(OscOnnxSession));
    if (!s) {
        DL_CLOSE(lib);
        return -1;
    }
    s->lib_handle = lib;
    s->api = api;

    OrtStatus *status = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "openscreen_matting", &s->env);
    if (status != NULL) {
        api->ReleaseStatus(status);
        osc_onnx_session_free(s);
        return -1;
    }

    OrtSessionOptions *opts = NULL;
    status = api->CreateSessionOptions(&opts);
    if (status != NULL) {
        api->ReleaseStatus(status);
        osc_onnx_session_free(s);
        return -1;
    }
    status = api->SetIntraOpNumThreads(opts, 2);
    if (status != NULL) api->ReleaseStatus(status);
    status = api->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL);
    if (status != NULL) api->ReleaseStatus(status);

#if defined(_WIN32)
    wchar_t model_path_w[1024];
    MultiByteToWideChar(CP_UTF8, 0, model_path, -1, model_path_w, 1024);
    status = api->CreateSession(s->env, model_path_w, opts, &s->session);
#else
    status = api->CreateSession(s->env, model_path, opts, &s->session);
#endif

    api->ReleaseSessionOptions(opts);
    if (status != NULL) {
        api->ReleaseStatus(status);
        osc_onnx_session_free(s);
        return -1;
    }

    status = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->mem_info);
    if (status != NULL) {
        api->ReleaseStatus(status);
        osc_onnx_session_free(s);
        return -1;
    }

    *out_session = s;
    return 0;
}

void osc_onnx_session_free(OscOnnxSession *s) {
    if (!s) return;
    if (s->api) {
        if (s->mem_info) s->api->ReleaseMemoryInfo(s->mem_info);
        if (s->session) s->api->ReleaseSession(s->session);
        if (s->env) s->api->ReleaseEnv(s->env);
    }
    if (s->lib_handle) {
        DL_CLOSE(s->lib_handle);
    }
    free(s);
}

int osc_onnx_run_segmentation(
    OscOnnxSession *s,
    const float *input_rgb_nhwc,
    float *output_mask
) {
    if (!s || !s->session || !s->api || !input_rgb_nhwc || !output_mask) return -1;

    int64_t in_shape[4] = { 1, 144, 256, 3 };
    OrtValue *in_tensor = NULL;
    OrtStatus *status = s->api->CreateTensorWithDataAsOrtValue(
        s->mem_info,
        (void*)input_rgb_nhwc,
        1 * 144 * 256 * 3 * sizeof(float),
        in_shape,
        4,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &in_tensor
    );
    if (status != NULL) {
        s->api->ReleaseStatus(status);
        return -1;
    }

    const char *in_names[] = { "input_1" };
    const char *out_names[] = { "segment_back" };
    OrtValue *out_tensor = NULL;

    status = s->api->Run(
        s->session,
        NULL,
        in_names,
        (const OrtValue* const*)&in_tensor,
        1,
        out_names,
        1,
        &out_tensor
    );

    s->api->ReleaseValue(in_tensor);

    if (status != NULL) {
        s->api->ReleaseStatus(status);
        return -1;
    }

    float *out_data = NULL;
    status = s->api->GetTensorMutableData(out_tensor, (void**)&out_data);
    if (status != NULL || !out_data) {
        if (status) s->api->ReleaseStatus(status);
        s->api->ReleaseValue(out_tensor);
        return -1;
    }

    memcpy(output_mask, out_data, 1 * 144 * 256 * 1 * sizeof(float));
    s->api->ReleaseValue(out_tensor);
    return 0;
}
