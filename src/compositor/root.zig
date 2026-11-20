pub const layer = @import("layer.zig");
pub const compositor = @import("compositor.zig");
pub const cpu_fallback = @import("cpu_fallback.zig");
pub const gpu_wgpu = @import("gpu_wgpu.zig");
pub const segmentation = @import("segmentation.zig");

pub const LayerCB = layer.LayerCB;
pub const LayerUniform = layer.LayerUniform;
pub const Modes = layer.Modes;

pub const FrameGraph = compositor.FrameGraph;
pub const SceneConfig = compositor.SceneConfig;
pub const PipPosition = compositor.PipPosition;
pub const PrivacyBlurRegion = compositor.PrivacyBlurRegion;
pub const planFrame = compositor.planFrame;

pub const CpuCompositor = cpu_fallback.CpuCompositor;
pub const writeP6Ppm = cpu_fallback.writeP6Ppm;
pub const GpuCompositor = gpu_wgpu.GpuCompositor;

pub const MattingMode = segmentation.MattingMode;
pub const MattingOptions = segmentation.MattingOptions;
pub const SegmentationEngine = segmentation.SegmentationEngine;

test {
    _ = layer;
    _ = compositor;
    _ = cpu_fallback;
    _ = gpu_wgpu;
    _ = segmentation;
}
