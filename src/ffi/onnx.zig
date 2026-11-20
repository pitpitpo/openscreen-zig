const std = @import("std");

pub const OscOnnxSession = opaque {};

pub extern "c" fn osc_onnx_session_create(
    lib_path: ?[*:0]const u8,
    model_path: [*:0]const u8,
    out_session: *?*OscOnnxSession,
) c_int;

pub extern "c" fn osc_onnx_session_free(session: ?*OscOnnxSession) void;

pub extern "c" fn osc_onnx_run_segmentation(
    session: ?*OscOnnxSession,
    input_rgb_nhwc: [*]const f32,
    output_mask: [*]f32,
) c_int;

pub const OnnxSession = struct {
    handle: *OscOnnxSession,

    pub fn init(lib_path: ?[]const u8, model_path: []const u8) !OnnxSession {
        var lib_z: [1024]u8 = undefined;
        var lib_ptr: ?[*:0]const u8 = null;
        if (lib_path) |lp| {
            if (lp.len >= lib_z.len) return error.PathTooLong;
            @memcpy(lib_z[0..lp.len], lp);
            lib_z[lp.len] = 0;
            lib_ptr = @ptrCast(&lib_z);
        }

        var model_z: [1024]u8 = undefined;
        if (model_path.len >= model_z.len) return error.PathTooLong;
        @memcpy(model_z[0..model_path.len], model_path);
        model_z[model_path.len] = 0;

        var handle: ?*OscOnnxSession = null;
        const ret = osc_onnx_session_create(lib_ptr, @ptrCast(&model_z), &handle);
        if (ret != 0 or handle == null) {
            return error.OnnxSessionInitFailed;
        }

        return OnnxSession{ .handle = handle.? };
    }

    pub fn deinit(self: *OnnxSession) void {
        osc_onnx_session_free(self.handle);
    }

    pub fn runSegmentation(self: *OnnxSession, input_rgb_256x144: []const f32, output_mask_256x144: []f32) !void {
        if (input_rgb_256x144.len != 144 * 256 * 3 or output_mask_256x144.len != 144 * 256) {
            return error.InvalidTensorDimensions;
        }

        const ret = osc_onnx_run_segmentation(
            self.handle,
            input_rgb_256x144.ptr,
            output_mask_256x144.ptr,
        );
        if (ret != 0) {
            return error.InferenceFailed;
        }
    }
};
