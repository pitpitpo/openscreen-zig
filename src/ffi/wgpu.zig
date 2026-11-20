const std = @import("std");

// Clean Zig 0.17 extern declarations for WebGPU / wgpu-native (NO @cImport)

pub const WGPUInstance = ?*anyopaque;
pub const WGPUAdapter = ?*anyopaque;
pub const WGPUDevice = ?*anyopaque;
pub const WGPUQueue = ?*anyopaque;
pub const WGPUShaderModule = ?*anyopaque;
pub const WGPUBindGroupLayout = ?*anyopaque;
pub const WGPUBindGroup = ?*anyopaque;
pub const WGPUPipelineLayout = ?*anyopaque;
pub const WGPURenderPipeline = ?*anyopaque;
pub const WGPUTexture = ?*anyopaque;
pub const WGPUTextureView = ?*anyopaque;
pub const WGPUSampler = ?*anyopaque;
pub const WGPUBuffer = ?*anyopaque;
pub const WGPUCommandEncoder = ?*anyopaque;
pub const WGPURenderPassEncoder = ?*anyopaque;
pub const WGPUCommandBuffer = ?*anyopaque;
pub const WGPUSurface = ?*anyopaque;
pub const WGPUQuerySet = ?*anyopaque;

pub const WGPUStringView = extern struct {
    data: ?[*]const u8 = null,
    length: usize = 0,

    pub fn fromSlice(s: []const u8) WGPUStringView {
        return .{
            .data = s.ptr,
            .length = s.len,
        };
    }
};

pub const WGPUChainedStruct = extern struct {
    next: ?*const WGPUChainedStruct = null,
    sType: u32 = 0,
};

pub const WGPUFuture = extern struct {
    id: u64 = 0,
};

pub const WGPUFutureWaitInfo = extern struct {
    future: WGPUFuture,
    completed: u32 = 0,
};

pub const WGPUSType = struct {
    pub const Invalid: u32 = 0x00000000;
    pub const ShaderSourceSPIRV: u32 = 0x00000001;
    pub const ShaderSourceWGSL: u32 = 0x00000002;
    pub const RenderPipelineDescriptor: u32 = 0x00000003;
    pub const SurfaceDescriptorFromMetalLayer: u32 = 0x00000004;
    pub const SurfaceDescriptorFromWindowsHWND: u32 = 0x00000005;
    pub const SurfaceDescriptorFromXlibWindow: u32 = 0x00000006;
    pub const SurfaceDescriptorFromCanvasHTMLSelector: u32 = 0x00000007;
    pub const SurfaceDescriptorFromWaylandSurface: u32 = 0x00000008;
    pub const SurfaceDescriptorFromAndroidNativeWindow: u32 = 0x00000009;
    pub const SurfaceDescriptorFromXcbWindow: u32 = 0x0000000A;
};

pub const WGPUTextureFormat = struct {
    pub const Undefined: u32 = 0x00000000;
    pub const R8Unorm: u32 = 0x00000001;
    pub const R8Snorm: u32 = 0x00000002;
    pub const R8Uint: u32 = 0x00000003;
    pub const R8Sint: u32 = 0x00000004;
    pub const R16Uint: u32 = 0x00000005;
    pub const R16Sint: u32 = 0x00000006;
    pub const R16Float: u32 = 0x00000007;
    pub const RG8Unorm: u32 = 0x00000008;
    pub const RG8Snorm: u32 = 0x00000009;
    pub const RG8Uint: u32 = 0x0000000A;
    pub const RG8Sint: u32 = 0x0000000B;
    pub const R32Float: u32 = 0x0000000C;
    pub const R32Uint: u32 = 0x0000000D;
    pub const R32Sint: u32 = 0x0000000E;
    pub const RG16Uint: u32 = 0x0000000F;
    pub const RG16Sint: u32 = 0x00000010;
    pub const RG16Float: u32 = 0x00000011;
    pub const RGBA8Unorm: u32 = 0x00000016;
    pub const RGBA8UnormSrgb: u32 = 0x00000017;
    pub const RGBA8Snorm: u32 = 0x00000018;
    pub const RGBA8Uint: u32 = 0x00000019;
    pub const RGBA8Sint: u32 = 0x0000001A;
    pub const BGRA8Unorm: u32 = 0x0000001C;
    pub const BGRA8UnormSrgb: u32 = 0x0000001D;
};

pub const WGPUTextureUsage = struct {
    pub const None: u64 = 0x00000000;
    pub const CopySrc: u64 = 0x00000001;
    pub const CopyDst: u64 = 0x00000002;
    pub const TextureBinding: u64 = 0x00000004;
    pub const StorageBinding: u64 = 0x00000008;
    pub const RenderAttachment: u64 = 0x00000010;
};

pub const WGPUBufferUsage = struct {
    pub const None: u64 = 0x00000000;
    pub const MapRead: u64 = 0x00000001;
    pub const MapWrite: u64 = 0x00000002;
    pub const CopySrc: u64 = 0x00000004;
    pub const CopyDst: u64 = 0x00000008;
    pub const Index: u64 = 0x00000010;
    pub const Vertex: u64 = 0x00000020;
    pub const Uniform: u64 = 0x00000040;
    pub const Storage: u64 = 0x00000080;
    pub const Indirect: u64 = 0x00000100;
    pub const QueryResolve: u64 = 0x00000200;
};

pub const WGPULoadOp = struct {
    pub const Undefined: u32 = 0x00000000;
    pub const Load: u32 = 0x00000001;
    pub const Clear: u32 = 0x00000002;
};

pub const WGPUStoreOp = struct {
    pub const Undefined: u32 = 0x00000000;
    pub const Store: u32 = 0x00000001;
    pub const Discard: u32 = 0x00000002;
};

pub const WGPUPrimitiveTopology = struct {
    pub const PointList: u32 = 0x00000001;
    pub const LineList: u32 = 0x00000002;
    pub const LineStrip: u32 = 0x00000003;
    pub const TriangleList: u32 = 0x00000004;
    pub const TriangleStrip: u32 = 0x00000005;
};

pub const WGPUFilterMode = struct {
    pub const Nearest: u32 = 0x00000001;
    pub const Linear: u32 = 0x00000002;
};

pub const WGPUAddressMode = struct {
    pub const ClampToEdge: u32 = 0x00000001;
    pub const Repeat: u32 = 0x00000002;
    pub const MirrorRepeat: u32 = 0x00000003;
};

pub const WGPUShaderStage = struct {
    pub const None: u64 = 0x00000000;
    pub const Vertex: u64 = 0x00000001;
    pub const Fragment: u64 = 0x00000002;
    pub const Compute: u64 = 0x00000004;
};

pub const WGPUBlendFactor = struct {
    pub const Zero: u32 = 0x00000001;
    pub const One: u32 = 0x00000002;
    pub const Src: u32 = 0x00000003;
    pub const OneMinusSrc: u32 = 0x00000004;
    pub const SrcAlpha: u32 = 0x00000005;
    pub const OneMinusSrcAlpha: u32 = 0x00000006;
    pub const Dst: u32 = 0x00000007;
    pub const OneMinusDst: u32 = 0x00000008;
    pub const DstAlpha: u32 = 0x00000009;
    pub const OneMinusDstAlpha: u32 = 0x0000000A;
};

pub const WGPUBlendOperation = struct {
    pub const Add: u32 = 0x00000001;
    pub const Subtract: u32 = 0x00000002;
    pub const ReverseSubtract: u32 = 0x00000003;
    pub const Min: u32 = 0x00000004;
    pub const Max: u32 = 0x00000005;
};

pub const WGPUColorWriteMask = struct {
    pub const None: u64 = 0x00000000;
    pub const Red: u64 = 0x00000001;
    pub const Green: u64 = 0x00000002;
    pub const Blue: u64 = 0x00000004;
    pub const Alpha: u64 = 0x00000008;
    pub const All: u64 = 0x0000000F;
};

pub const WGPUMapMode = struct {
    pub const None: u64 = 0x00000000;
    pub const Read: u64 = 0x00000001;
    pub const Write: u64 = 0x00000002;
};

pub const WGPUCallbackMode = struct {
    pub const WaitAnyOnly: u32 = 0x00000001;
    pub const AllowProcessEvents: u32 = 0x00000002;
    pub const AllowSpontaneous: u32 = 0x00000003;
};

pub const WGPUAdapterType = struct {
    pub const DiscreteGPU: u32 = 0x00000001;
    pub const IntegratedGPU: u32 = 0x00000002;
    pub const CPU: u32 = 0x00000003;
    pub const Unknown: u32 = 0x00000004;
};

pub const WGPUColor = extern struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,
    a: f64 = 0,
};

pub const WGPUExtent3D = extern struct {
    width: u32 = 1,
    height: u32 = 1,
    depthOrArrayLayers: u32 = 1,
};

pub const WGPUOrigin3D = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

pub const WGPUShaderSourceWGSL = extern struct {
    chain: WGPUChainedStruct = .{ .sType = WGPUSType.ShaderSourceWGSL },
    code: WGPUStringView,
};

pub const WGPUShaderModuleDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
};

pub const WGPURenderPassColorAttachment = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    view: WGPUTextureView = null,
    depthSlice: u32 = 0xFFFFFFFF,
    resolveTarget: WGPUTextureView = null,
    loadOp: u32 = WGPULoadOp.Clear,
    storeOp: u32 = WGPUStoreOp.Store,
    clearValue: WGPUColor = .{},
};

pub const WGPURenderPassDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    colorAttachmentCount: usize = 0,
    colorAttachments: [*]const WGPURenderPassColorAttachment,
    depthStencilAttachment: ?*const anyopaque = null,
    occlusionQuerySet: WGPUQuerySet = null,
    timestampWrites: ?*const anyopaque = null,
};

pub const WGPUBlendComponent = extern struct {
    operation: u32 = WGPUBlendOperation.Add,
    srcFactor: u32 = WGPUBlendFactor.One,
    dstFactor: u32 = WGPUBlendFactor.Zero,
};

pub const WGPUBlendState = extern struct {
    color: WGPUBlendComponent = .{},
    alpha: WGPUBlendComponent = .{},
};

pub const WGPUColorTargetState = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    format: u32 = WGPUTextureFormat.RGBA8Unorm,
    blend: ?*const WGPUBlendState = null,
    writeMask: u64 = WGPUColorWriteMask.All,
};

pub const WGPUFragmentState = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    module: WGPUShaderModule = null,
    entryPoint: WGPUStringView = .{},
    constantCount: usize = 0,
    constants: ?*const anyopaque = null,
    targetCount: usize = 0,
    targets: [*]const WGPUColorTargetState,
};

pub const WGPUVertexState = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    module: WGPUShaderModule = null,
    entryPoint: WGPUStringView = .{},
    constantCount: usize = 0,
    constants: ?*const anyopaque = null,
    bufferCount: usize = 0,
    buffers: ?*const anyopaque = null,
};

pub const WGPUPrimitiveState = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    topology: u32 = WGPUPrimitiveTopology.TriangleStrip,
    stripIndexFormat: u32 = 0,
    frontFace: u32 = 1, // CCW
    cullMode: u32 = 0, // None
    unclippedDepth: u32 = 0,
};

pub const WGPUMultisampleState = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    count: u32 = 1,
    mask: u32 = 0xFFFFFFFF,
    alphaToCoverageEnabled: u32 = 0,
};

pub const WGPURenderPipelineDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    layout: WGPUPipelineLayout = null,
    vertex: WGPUVertexState,
    primitive: WGPUPrimitiveState = .{},
    depthStencil: ?*const anyopaque = null,
    multisample: WGPUMultisampleState = .{},
    fragment: ?*const WGPUFragmentState = null,
};

pub const WGPUBufferDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    usage: u64 = 0,
    size: u64 = 0,
    mappedAtCreation: u32 = 0,
};

pub const WGPUTextureDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    usage: u64 = 0,
    dimension: u32 = 2, // 2D
    size: WGPUExtent3D,
    format: u32 = WGPUTextureFormat.RGBA8Unorm,
    mipLevelCount: u32 = 1,
    sampleCount: u32 = 1,
    viewFormatCount: usize = 0,
    viewFormats: ?[*]const u32 = null,
};

pub const WGPUTextureViewDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    format: u32 = WGPUTextureFormat.Undefined,
    dimension: u32 = 2, // 2D
    baseMipLevel: u32 = 0,
    mipLevelCount: u32 = 1,
    baseArrayLayer: u32 = 0,
    arrayLayerCount: u32 = 1,
    aspect: u32 = 1, // All
};

pub const WGPUSamplerDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    addressModeU: u32 = WGPUAddressMode.ClampToEdge,
    addressModeV: u32 = WGPUAddressMode.ClampToEdge,
    addressModeW: u32 = WGPUAddressMode.ClampToEdge,
    magFilter: u32 = WGPUFilterMode.Linear,
    minFilter: u32 = WGPUFilterMode.Linear,
    mipmapFilter: u32 = WGPUFilterMode.Nearest,
    lodMinClamp: f32 = 0,
    lodMaxClamp: f32 = 32,
    compare: u32 = 0,
    maxAnisotropy: u16 = 1,
};

pub const WGPUBufferBindingLayout = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    type: u32 = 0, // BindingNotUsed = 0, Uniform = 2
    hasDynamicOffset: u32 = 0,
    minBindingSize: u64 = 0,
};

pub const WGPUSamplerBindingLayout = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    type: u32 = 0, // BindingNotUsed = 0, Filtering = 2
};

pub const WGPUTextureBindingLayout = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    sampleType: u32 = 0, // BindingNotUsed = 0, Float = 2
    viewDimension: u32 = 0, // 2D = 2
    multisampled: u32 = 0,
};

pub const WGPUStorageTextureBindingLayout = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    access: u32 = 0, // BindingNotUsed = 0
    format: u32 = 0,
    viewDimension: u32 = 0,
};

pub const WGPUBindGroupLayoutEntry = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    binding: u32 = 0,
    visibility: u64 = WGPUShaderStage.Fragment,
    bindingArraySize: u32 = 0,
    buffer: WGPUBufferBindingLayout = .{ .minBindingSize = 0 },
    sampler: WGPUSamplerBindingLayout = .{},
    texture: WGPUTextureBindingLayout = .{},
    storageTexture: WGPUStorageTextureBindingLayout = .{},
};

pub const WGPUBindGroupLayoutDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    entryCount: usize = 0,
    entries: [*]const WGPUBindGroupLayoutEntry,
};

pub const WGPUBindGroupEntry = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    binding: u32 = 0,
    buffer: WGPUBuffer = null,
    offset: u64 = 0,
    size: u64 = 0,
    sampler: WGPUSampler = null,
    textureView: WGPUTextureView = null,
};

pub const WGPUBindGroupDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    layout: WGPUBindGroupLayout,
    entryCount: usize = 0,
    entries: [*]const WGPUBindGroupEntry,
};

pub const WGPUPipelineLayoutDescriptor = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    label: WGPUStringView = .{},
    bindGroupLayoutCount: usize = 0,
    bindGroupLayouts: [*]const WGPUBindGroupLayout,
};

pub const WGPUTexelCopyBufferLayout = extern struct {
    offset: u64 = 0,
    bytesPerRow: u32 = 0,
    rowsPerImage: u32 = 0,
};
pub const WGPUTextureDataLayout = WGPUTexelCopyBufferLayout;

pub const WGPUTexelCopyTextureInfo = extern struct {
    texture: WGPUTexture = null,
    mipLevel: u32 = 0,
    origin: WGPUOrigin3D = .{},
    aspect: u32 = 1, // All
};
pub const WGPUImageCopyTexture = WGPUTexelCopyTextureInfo;

pub const WGPUTexelCopyBufferInfo = extern struct {
    layout: WGPUTexelCopyBufferLayout = .{},
    buffer: WGPUBuffer = null,
};
pub const WGPUImageCopyBuffer = WGPUTexelCopyBufferInfo;

pub const WGPURequestAdapterOptions = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    featureLevel: u32 = 0,
    powerPreference: u32 = 0,
    forceFallbackAdapter: u32 = 0,
    backendType: u32 = 0,
    compatibleSurface: WGPUSurface = null,
};

pub const WGPUAdapterInfo = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    vendor: WGPUStringView = .{},
    architecture: WGPUStringView = .{},
    device: WGPUStringView = .{},
    description: WGPUStringView = .{},
    backendType: u32 = 0,
    adapterType: u32 = 0,
    vendorID: u32 = 0,
    deviceID: u32 = 0,
};

pub const WGPURequestDeviceCallbackInfo = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    mode: u32 = WGPUCallbackMode.AllowProcessEvents,
    callback: ?*const fn (status: u32, device: WGPUDevice, message: WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};

pub const WGPURequestAdapterCallbackInfo = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    mode: u32 = WGPUCallbackMode.AllowProcessEvents,
    callback: ?*const fn (status: u32, adapter: WGPUAdapter, message: WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};

pub const WGPUBufferMapCallbackInfo = extern struct {
    nextInChain: ?*const WGPUChainedStruct = null,
    mode: u32 = WGPUCallbackMode.AllowProcessEvents,
    callback: ?*const fn (status: u32, message: WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};

// C API functions exported by wgpu-native
pub extern fn wgpuCreateInstance(descriptor: ?*const anyopaque) WGPUInstance;
pub extern fn wgpuInstanceRelease(instance: WGPUInstance) void;
pub extern fn wgpuInstanceEnumerateAdapters(instance: WGPUInstance, options: ?*const anyopaque, adapters: ?[*]WGPUAdapter) usize;
pub extern fn wgpuInstanceProcessEvents(instance: WGPUInstance) void;
pub extern fn wgpuInstanceRequestAdapter(instance: WGPUInstance, options: ?*const WGPURequestAdapterOptions, callbackInfo: WGPURequestAdapterCallbackInfo) WGPUFuture;
pub extern fn wgpuAdapterGetInfo(adapter: WGPUAdapter, info: *WGPUAdapterInfo) void;
pub extern fn wgpuAdapterRequestDevice(adapter: WGPUAdapter, descriptor: ?*const anyopaque, callbackInfo: WGPURequestDeviceCallbackInfo) WGPUFuture;
pub extern fn wgpuAdapterRelease(adapter: WGPUAdapter) void;
pub extern fn wgpuDeviceGetQueue(device: WGPUDevice) WGPUQueue;
pub extern fn wgpuDeviceRelease(device: WGPUDevice) void;
pub extern fn wgpuDevicePoll(device: WGPUDevice, wait: u32, submissionIndex: ?*const anyopaque) u32;

pub extern fn wgpuDeviceCreateShaderModule(device: WGPUDevice, descriptor: *const WGPUShaderModuleDescriptor) WGPUShaderModule;
pub extern fn wgpuShaderModuleRelease(shaderModule: WGPUShaderModule) void;

pub extern fn wgpuDeviceCreatePipelineLayout(device: WGPUDevice, descriptor: *const WGPUPipelineLayoutDescriptor) WGPUPipelineLayout;
pub extern fn wgpuPipelineLayoutRelease(pipelineLayout: WGPUPipelineLayout) void;

pub extern fn wgpuDeviceCreateRenderPipeline(device: WGPUDevice, descriptor: *const WGPURenderPipelineDescriptor) WGPURenderPipeline;
pub extern fn wgpuRenderPipelineRelease(renderPipeline: WGPURenderPipeline) void;

pub extern fn wgpuDeviceCreateBuffer(device: WGPUDevice, descriptor: *const WGPUBufferDescriptor) WGPUBuffer;
pub extern fn wgpuBufferRelease(buffer: WGPUBuffer) void;
pub extern fn wgpuBufferMapAsync(buffer: WGPUBuffer, mode: u64, offset: usize, size: usize, callbackInfo: WGPUBufferMapCallbackInfo) WGPUFuture;
pub extern fn wgpuBufferGetConstMappedRange(buffer: WGPUBuffer, offset: usize, size: usize) ?*const anyopaque;
pub extern fn wgpuBufferUnmap(buffer: WGPUBuffer) void;

pub extern fn wgpuDeviceCreateTexture(device: WGPUDevice, descriptor: *const WGPUTextureDescriptor) WGPUTexture;
pub extern fn wgpuTextureRelease(texture: WGPUTexture) void;
pub extern fn wgpuTextureCreateView(texture: WGPUTexture, descriptor: ?*const WGPUTextureViewDescriptor) WGPUTextureView;
pub extern fn wgpuTextureViewRelease(textureView: WGPUTextureView) void;

pub extern fn wgpuDeviceCreateSampler(device: WGPUDevice, descriptor: *const WGPUSamplerDescriptor) WGPUSampler;
pub extern fn wgpuSamplerRelease(sampler: WGPUSampler) void;

pub extern fn wgpuDeviceCreateBindGroupLayout(device: WGPUDevice, descriptor: *const WGPUBindGroupLayoutDescriptor) WGPUBindGroupLayout;
pub extern fn wgpuBindGroupLayoutRelease(bindGroupLayout: WGPUBindGroupLayout) void;

pub extern fn wgpuDeviceCreateBindGroup(device: WGPUDevice, descriptor: *const WGPUBindGroupDescriptor) WGPUBindGroup;
pub extern fn wgpuBindGroupRelease(bindGroup: WGPUBindGroup) void;

pub extern fn wgpuDeviceCreateCommandEncoder(device: WGPUDevice, descriptor: ?*const anyopaque) WGPUCommandEncoder;
pub extern fn wgpuCommandEncoderRelease(commandEncoder: WGPUCommandEncoder) void;
pub extern fn wgpuCommandEncoderBeginRenderPass(commandEncoder: WGPUCommandEncoder, descriptor: *const WGPURenderPassDescriptor) WGPURenderPassEncoder;
pub extern fn wgpuCommandEncoderCopyTextureToBuffer(commandEncoder: WGPUCommandEncoder, source: *const WGPUImageCopyTexture, destination: *const WGPUImageCopyBuffer, copySize: *const WGPUExtent3D) void;
pub extern fn wgpuCommandEncoderFinish(commandEncoder: WGPUCommandEncoder, descriptor: ?*const anyopaque) WGPUCommandBuffer;
pub extern fn wgpuCommandBufferRelease(commandBuffer: WGPUCommandBuffer) void;

pub extern fn wgpuRenderPassEncoderSetPipeline(renderPassEncoder: WGPURenderPassEncoder, pipeline: WGPURenderPipeline) void;
pub extern fn wgpuRenderPassEncoderSetBindGroup(renderPassEncoder: WGPURenderPassEncoder, groupIndex: u32, group: WGPUBindGroup, dynamicOffsetCount: usize, dynamicOffsets: ?[*]const u32) void;
pub extern fn wgpuRenderPassEncoderDraw(renderPassEncoder: WGPURenderPassEncoder, vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32) void;
pub extern fn wgpuRenderPassEncoderEnd(renderPassEncoder: WGPURenderPassEncoder) void;
pub extern fn wgpuRenderPassEncoderRelease(renderPassEncoder: WGPURenderPassEncoder) void;

pub extern fn wgpuQueueWriteBuffer(queue: WGPUQueue, buffer: WGPUBuffer, bufferOffset: u64, data: *const anyopaque, size: usize) void;
pub extern fn wgpuQueueWriteTexture(queue: WGPUQueue, destination: *const WGPUImageCopyTexture, data: *const anyopaque, dataSize: usize, dataLayout: *const WGPUTextureDataLayout, writeSize: *const WGPUExtent3D) void;
pub extern fn wgpuQueueSubmit(queue: WGPUQueue, commandCount: usize, commands: [*]const WGPUCommandBuffer) void;

test "wgpu C ABI struct sizes" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(WGPUBufferDescriptor));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(WGPUTextureDescriptor));
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(WGPUBindGroupLayoutEntry));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(WGPUBindGroupEntry));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(WGPUTexelCopyBufferLayout));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(WGPUTexelCopyTextureInfo));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(WGPUTexelCopyBufferInfo));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(WGPUColorTargetState));
    try std.testing.expectEqual(@as(usize, 168), @sizeOf(WGPURenderPipelineDescriptor));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(WGPUPrimitiveState));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(WGPUVertexState));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(WGPUFragmentState));
}
