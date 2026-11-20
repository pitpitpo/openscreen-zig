const std = @import("std");
pub const wgpu = @import("ffi");
pub const compositor = @import("compositor.zig");
pub const layer = @import("layer.zig");
pub const cpu_fallback = @import("cpu_fallback.zig");

pub const FrameGraph = compositor.FrameGraph;
pub const LayerCB = compositor.LayerCB;
pub const LayerUniform = layer.LayerUniform;
pub const CpuCompositor = cpu_fallback.CpuCompositor;

const LAYER_WGSL_RAW = @embedFile("shaders/layer.wgsl");

pub const GpuCompositor = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    instance: wgpu.WGPUInstance = null,
    adapter: wgpu.WGPUAdapter = null,
    device: wgpu.WGPUDevice = null,
    queue: wgpu.WGPUQueue = null,
    shader_module: wgpu.WGPUShaderModule = null,
    pipeline_flat: wgpu.WGPURenderPipeline = null,
    pipeline_layout: wgpu.WGPUPipelineLayout = null,
    bind_group_layout: wgpu.WGPUBindGroupLayout = null,
    uniform_buffer: wgpu.WGPUBuffer = null,
    prism_buffer: wgpu.WGPUBuffer = null,
    staging_buffer: wgpu.WGPUBuffer = null,
    render_target: wgpu.WGPUTexture = null,
    render_view: wgpu.WGPUTextureView = null,
    sampler: wgpu.WGPUSampler = null,
    dummy_texture: wgpu.WGPUTexture = null,
    dummy_view: wgpu.WGPUTextureView = null,
    bind_group: wgpu.WGPUBindGroup = null,
    cpu_fallback_engine: ?CpuCompositor = null,
    output_buffer: []u8 = &[_]u8{},
    has_active_gpu: bool = false,

    const DeviceContext = struct {
        device: wgpu.WGPUDevice = null,
    };

    fn onDeviceCallback(status: u32, dev: wgpu.WGPUDevice, msg: wgpu.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
        _ = msg;
        _ = ud2;
        if (status == 1) {
            const ctx: *DeviceContext = @ptrCast(@alignCast(ud1));
            ctx.device = dev;
        }
    }

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !GpuCompositor {
        const output_buffer = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
        errdefer allocator.free(output_buffer);

        var comp = GpuCompositor{
            .allocator = allocator,
            .width = width,
            .height = height,
            .output_buffer = output_buffer,
        };

        const init_res = comp.initGpuPipeline();
        if (init_res) |_| {
            comp.has_active_gpu = true;
        } else |_| {
            // Initialize deterministic CPU engine as transparent fallback
            comp.cpu_fallback_engine = try CpuCompositor.init(allocator, width, height);
            comp.has_active_gpu = false;
        }

        return comp;
    }

    fn initGpuPipeline(self: *GpuCompositor) !void {
        self.instance = wgpu.wgpuCreateInstance(null);
        if (self.instance == null) return error.InstanceCreationFailed;

        var adapters = [_]wgpu.WGPUAdapter{
            null, null, null, null, null, null, null, null,
            null, null, null, null, null, null, null, null,
        };
        const count = wgpu.wgpuInstanceEnumerateAdapters(self.instance, null, &adapters);
        if (count == 0) return error.NoAdaptersFound;

        // Choose adapter: prefer CPU / Lavapipe / WARP if headless test mode requested
        var selected_adapter: wgpu.WGPUAdapter = adapters[0];
        const is_headless = blk: {
            if (std.c.getenv("OPENSCREEN_TEST_HEADLESS")) |val| {
                break :blk std.mem.orderZ(u8, val, "1") == .eq;
            }
            break :blk false;
        };

        var i: usize = 0;
        while (i < count) : (i += 1) {
            var info: wgpu.WGPUAdapterInfo = .{};
            wgpu.wgpuAdapterGetInfo(adapters[i], &info);
            if (is_headless and info.adapterType == wgpu.WGPUAdapterType.CPU) {
                selected_adapter = adapters[i];
                break;
            }
        }
        self.adapter = selected_adapter;

        // Request device
        var dev_ctx = DeviceContext{};
        _ = wgpu.wgpuAdapterRequestDevice(self.adapter, null, .{
            .mode = wgpu.WGPUCallbackMode.AllowProcessEvents,
            .callback = onDeviceCallback,
            .userdata1 = &dev_ctx,
        });
        wgpu.wgpuInstanceProcessEvents(self.instance);
        if (dev_ctx.device == null) return error.DeviceRequestFailed;
        self.device = dev_ctx.device;

        self.queue = wgpu.wgpuDeviceGetQueue(self.device);
        if (self.queue == null) return error.QueueAcquisitionFailed;

        // Compile layer.wgsl
        const prefix = "const LAYER_MODELS: bool = false;\n";
        const wgsl_code = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, LAYER_WGSL_RAW });
        defer self.allocator.free(wgsl_code);

        const wgsl_source = wgpu.WGPUShaderSourceWGSL{
            .code = .{
                .data = wgsl_code.ptr,
                .length = wgsl_code.len,
            },
        };
        const shader_desc = wgpu.WGPUShaderModuleDescriptor{
            .nextInChain = &wgsl_source.chain,
            .label = .{ .data = "layer_wgsl", .length = 10 },
        };
        self.shader_module = wgpu.wgpuDeviceCreateShaderModule(self.device, &shader_desc);
        if (self.shader_module == null) return error.ShaderCompilationFailed;

        // Create uniform buffer for layers (16384 bytes, 64 layers * 256 bytes)
        const ubuf_desc = wgpu.WGPUBufferDescriptor{
            .label = .{ .data = "layer_uniform", .length = 13 },
            .usage = wgpu.WGPUBufferUsage.Uniform | wgpu.WGPUBufferUsage.CopyDst,
            .size = 16384,
        };
        self.uniform_buffer = wgpu.wgpuDeviceCreateBuffer(self.device, &ubuf_desc);
        if (self.uniform_buffer == null) return error.BufferCreationFailed;

        // Create prism uniform buffer (12768 bytes)
        const prism_buf_size: u64 = 12768;
        const pbuf_desc = wgpu.WGPUBufferDescriptor{
            .label = .{ .data = "prism_uniform", .length = 13 },
            .usage = wgpu.WGPUBufferUsage.Uniform | wgpu.WGPUBufferUsage.CopyDst,
            .size = prism_buf_size,
        };
        self.prism_buffer = wgpu.wgpuDeviceCreateBuffer(self.device, &pbuf_desc);
        if (self.prism_buffer == null) return error.PrismBufferCreationFailed;

        // Create staging readback buffer
        const buf_size = @as(u64, self.width) * @as(u64, self.height) * 4;
        const sbuf_desc = wgpu.WGPUBufferDescriptor{
            .label = .{ .data = "staging_readback", .length = 16 },
            .usage = wgpu.WGPUBufferUsage.MapRead | wgpu.WGPUBufferUsage.CopyDst,
            .size = buf_size,
        };
        self.staging_buffer = wgpu.wgpuDeviceCreateBuffer(self.device, &sbuf_desc);
        if (self.staging_buffer == null) return error.StagingBufferCreationFailed;

        // Create offscreen render target texture
        const tex_desc = wgpu.WGPUTextureDescriptor{
            .label = .{ .data = "render_target", .length = 13 },
            .usage = wgpu.WGPUTextureUsage.RenderAttachment | wgpu.WGPUTextureUsage.CopySrc,
            .size = .{ .width = self.width, .height = self.height, .depthOrArrayLayers = 1 },
            .format = wgpu.WGPUTextureFormat.RGBA8Unorm,
        };
        self.render_target = wgpu.wgpuDeviceCreateTexture(self.device, &tex_desc);
        if (self.render_target == null) return error.RenderTargetCreationFailed;

        self.render_view = wgpu.wgpuTextureCreateView(self.render_target, null);
        if (self.render_view == null) return error.RenderViewCreationFailed;

        // Sampler
        const samp_desc = wgpu.WGPUSamplerDescriptor{
            .label = .{ .data = "linear_sampler", .length = 14 },
            .magFilter = wgpu.WGPUFilterMode.Linear,
            .minFilter = wgpu.WGPUFilterMode.Linear,
        };
        self.sampler = wgpu.wgpuDeviceCreateSampler(self.device, &samp_desc);

        // Dummy 1x1 texture for unused bindings (texY, texU, texMask, texV, texDof)
        const dummy_desc = wgpu.WGPUTextureDescriptor{
            .label = .{ .data = "dummy_1x1", .length = 9 },
            .usage = wgpu.WGPUTextureUsage.TextureBinding | wgpu.WGPUTextureUsage.CopyDst,
            .size = .{ .width = 1, .height = 1, .depthOrArrayLayers = 1 },
            .format = wgpu.WGPUTextureFormat.RGBA8Unorm,
        };
        self.dummy_texture = wgpu.wgpuDeviceCreateTexture(self.device, &dummy_desc);
        self.dummy_view = wgpu.wgpuTextureCreateView(self.dummy_texture, null);

        // Populate dummy pixel
        const white_pixel = [4]u8{ 255, 255, 255, 255 };
        const copy_tex = wgpu.WGPUImageCopyTexture{
            .texture = self.dummy_texture,
        };
        const data_layout = wgpu.WGPUTextureDataLayout{
            .bytesPerRow = 256,
            .rowsPerImage = 1,
        };
        wgpu.wgpuQueueWriteTexture(self.queue, &copy_tex, &white_pixel, 4, &data_layout, &.{ .width = 1, .height = 1, .depthOrArrayLayers = 1 });

        // Bind group layout (bindings 0..7)
        const entries = [_]wgpu.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.WGPUShaderStage.Fragment | wgpu.WGPUShaderStage.Vertex,
                .buffer = .{
                    .type = 2,
                    .hasDynamicOffset = 1,
                    .minBindingSize = @sizeOf(LayerUniform),
                },
            },
            .{
                .binding = 1,
                .visibility = wgpu.WGPUShaderStage.Fragment,
                .texture = .{ .sampleType = 2, .viewDimension = 2 }, // Float = 2, 2D = 2
            },
            .{
                .binding = 2,
                .visibility = wgpu.WGPUShaderStage.Fragment,
                .texture = .{ .sampleType = 2, .viewDimension = 2 },
            },
            .{
                .binding = 3,
                .visibility = wgpu.WGPUShaderStage.Fragment,
                .sampler = .{ .type = 2 }, // Filtering = 2
            },
            .{
                .binding = 4,
                .visibility = wgpu.WGPUShaderStage.Fragment,
                .texture = .{ .sampleType = 2, .viewDimension = 2 },
            },
            .{
                .binding = 5,
                .visibility = wgpu.WGPUShaderStage.Fragment,
                .texture = .{ .sampleType = 2, .viewDimension = 2 },
            },
            .{
                .binding = 6,
                .visibility = wgpu.WGPUShaderStage.Fragment,
                .texture = .{ .sampleType = 2, .viewDimension = 2 },
            },
            .{
                .binding = 7,
                .visibility = wgpu.WGPUShaderStage.Fragment,
                .buffer = .{ .type = 2, .minBindingSize = 12768 },
            },
        };

        const bgl_desc = wgpu.WGPUBindGroupLayoutDescriptor{
            .label = .{ .data = "layer_bgl", .length = 9 },
            .entryCount = entries.len,
            .entries = &entries,
        };
        self.bind_group_layout = wgpu.wgpuDeviceCreateBindGroupLayout(self.device, &bgl_desc);
        if (self.bind_group_layout == null) return error.BglCreationFailed;

        // Pipeline layout
        const bgl_list = [_]wgpu.WGPUBindGroupLayout{self.bind_group_layout};
        const pl_desc = wgpu.WGPUPipelineLayoutDescriptor{
            .label = .{ .data = "layer_pipeline_layout", .length = 21 },
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &bgl_list,
        };
        self.pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(self.device, &pl_desc);
        if (self.pipeline_layout == null) return error.PipelineLayoutCreationFailed;

        // Bind group
        const bg_entries = [_]wgpu.WGPUBindGroupEntry{
            .{ .binding = 0, .buffer = self.uniform_buffer, .size = @sizeOf(LayerUniform) },
            .{ .binding = 1, .textureView = self.dummy_view },
            .{ .binding = 2, .textureView = self.dummy_view },
            .{ .binding = 3, .sampler = self.sampler },
            .{ .binding = 4, .textureView = self.dummy_view },
            .{ .binding = 5, .textureView = self.dummy_view },
            .{ .binding = 6, .textureView = self.dummy_view },
            .{ .binding = 7, .buffer = self.prism_buffer, .size = 12768 },
        };
        const bg_desc = wgpu.WGPUBindGroupDescriptor{
            .label = .{ .data = "layer_bg", .length = 8 },
            .layout = self.bind_group_layout,
            .entryCount = bg_entries.len,
            .entries = &bg_entries,
        };
        self.bind_group = wgpu.wgpuDeviceCreateBindGroup(self.device, &bg_desc);
        if (self.bind_group == null) return error.BindGroupCreationFailed;

        // Create RenderPipeline
        const blend_state = wgpu.WGPUBlendState{
            .color = .{
                .operation = wgpu.WGPUBlendOperation.Add,
                .srcFactor = wgpu.WGPUBlendFactor.One,
                .dstFactor = wgpu.WGPUBlendFactor.OneMinusSrcAlpha,
            },
            .alpha = .{
                .operation = wgpu.WGPUBlendOperation.Add,
                .srcFactor = wgpu.WGPUBlendFactor.One,
                .dstFactor = wgpu.WGPUBlendFactor.OneMinusSrcAlpha,
            },
        };
        const color_target = wgpu.WGPUColorTargetState{
            .format = wgpu.WGPUTextureFormat.RGBA8Unorm,
            .blend = &blend_state,
            .writeMask = wgpu.WGPUColorWriteMask.All,
        };
        const fragment_state = wgpu.WGPUFragmentState{
            .module = self.shader_module,
            .entryPoint = .{ .data = "fs_main", .length = 7 },
            .targetCount = 1,
            .targets = &[_]wgpu.WGPUColorTargetState{color_target},
        };

        const pipe_desc = wgpu.WGPURenderPipelineDescriptor{
            .label = .{ .data = "layer_pipeline", .length = 14 },
            .layout = self.pipeline_layout,
            .vertex = .{
                .module = self.shader_module,
                .entryPoint = .{ .data = "vs_main", .length = 7 },
            },
            .primitive = .{
                .topology = wgpu.WGPUPrimitiveTopology.TriangleStrip,
            },
            .fragment = &fragment_state,
        };
        self.pipeline_flat = wgpu.wgpuDeviceCreateRenderPipeline(self.device, &pipe_desc);
        if (self.pipeline_flat == null) return error.RenderPipelineCreationFailed;
    }

    pub fn deinit(self: *GpuCompositor) void {
        if (self.output_buffer.len > 0) {
            self.allocator.free(self.output_buffer);
        }

        if (self.cpu_fallback_engine) |*cpu| {
            cpu.deinit();
        }

        if (self.bind_group) |bg| wgpu.wgpuBindGroupRelease(bg);
        if (self.pipeline_flat) |p| wgpu.wgpuRenderPipelineRelease(p);
        if (self.pipeline_layout) |pl| wgpu.wgpuPipelineLayoutRelease(pl);
        if (self.bind_group_layout) |bgl| wgpu.wgpuBindGroupLayoutRelease(bgl);
        if (self.dummy_view) |v| wgpu.wgpuTextureViewRelease(v);
        if (self.dummy_texture) |t| wgpu.wgpuTextureRelease(t);
        if (self.sampler) |s| wgpu.wgpuSamplerRelease(s);
        if (self.render_view) |v| wgpu.wgpuTextureViewRelease(v);
        if (self.render_target) |t| wgpu.wgpuTextureRelease(t);
        if (self.staging_buffer) |b| wgpu.wgpuBufferRelease(b);
        if (self.prism_buffer) |b| wgpu.wgpuBufferRelease(b);
        if (self.uniform_buffer) |b| wgpu.wgpuBufferRelease(b);
        if (self.shader_module) |m| wgpu.wgpuShaderModuleRelease(m);
        if (self.queue) |_| {} // Queue released with device
        if (self.device) |d| wgpu.wgpuDeviceRelease(d);
        if (self.adapter) |a| wgpu.wgpuAdapterRelease(a);
        if (self.instance) |inst| wgpu.wgpuInstanceRelease(inst);
    }

    pub fn render(self: *GpuCompositor, fg: *const FrameGraph) ![]const u8 {
        if (!self.has_active_gpu or self.pipeline_flat == null) {
            if (self.cpu_fallback_engine) |*cpu| {
                return cpu.render(fg);
            }
            return error.NoAvailableCompositor;
        }

        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null);
        if (encoder == null) return error.EncoderCreationFailed;
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        const color_attachment = wgpu.WGPURenderPassColorAttachment{
            .view = self.render_view,
            .loadOp = wgpu.WGPULoadOp.Clear,
            .storeOp = wgpu.WGPUStoreOp.Store,
            .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        };
        const pass_desc = wgpu.WGPURenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = &[_]wgpu.WGPURenderPassColorAttachment{color_attachment},
        };

        // Write all layer uniforms before pass
        for (fg.layers.items, 0..) |layer_cb, i| {
            if (i >= 64) break;
            const uniform = LayerUniform{ .cb = layer_cb };
            const offset = @as(u64, @intCast(i * 256));
            wgpu.wgpuQueueWriteBuffer(self.queue, self.uniform_buffer, offset, &uniform, @sizeOf(LayerUniform));
        }

        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);
        if (pass == null) return error.PassCreationFailed;

        wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline_flat);

        // Draw each layer with dynamic offset
        for (fg.layers.items, 0..) |_, i| {
            if (i >= 64) break;
            const dynamic_offset = @as(u32, @intCast(i * 256));
            const offsets = [_]u32{dynamic_offset};
            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 1, &offsets);
            // Draw 4 vertices with TriangleStrip
            wgpu.wgpuRenderPassEncoderDraw(pass, 4, 1, 0, 0);
        }

        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);

        // Copy render target to staging buffer
        const copy_src = wgpu.WGPUImageCopyTexture{ .texture = self.render_target };
        const copy_dst = wgpu.WGPUImageCopyBuffer{
            .layout = .{
                .offset = 0,
                .bytesPerRow = self.width * 4,
                .rowsPerImage = self.height,
            },
            .buffer = self.staging_buffer,
        };
        wgpu.wgpuCommandEncoderCopyTextureToBuffer(encoder, &copy_src, &copy_dst, &.{
            .width = self.width,
            .height = self.height,
            .depthOrArrayLayers = 1,
        });

        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null);
        if (cmd == null) return error.CommandFinishFailed;
        defer wgpu.wgpuCommandBufferRelease(cmd);

        wgpu.wgpuQueueSubmit(self.queue, 1, &[_]wgpu.WGPUCommandBuffer{cmd});
        _ = wgpu.wgpuDevicePoll(self.device, 1, null);

        // Map buffer to read back
        const MapContext = struct {
            done: bool = false,
        };
        const onMap = struct {
            fn callback(status: u32, msg: wgpu.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
                _ = msg;
                _ = ud2;
                if (status == 1) {
                    const ctx: *MapContext = @ptrCast(@alignCast(ud1));
                    ctx.done = true;
                }
            }
        }.callback;

        var map_ctx = MapContext{};
        const buf_size = @as(usize, self.width) * @as(usize, self.height) * 4;
        _ = wgpu.wgpuBufferMapAsync(self.staging_buffer, 1, 0, buf_size, .{
            .mode = wgpu.WGPUCallbackMode.AllowProcessEvents,
            .callback = onMap,
            .userdata1 = &map_ctx,
        });

        var wait_count: u32 = 0;
        while (!map_ctx.done and wait_count < 1000) : (wait_count += 1) {
            _ = wgpu.wgpuDevicePoll(self.device, 1, null);
            wgpu.wgpuInstanceProcessEvents(self.instance);
        }

        const mapped_ptr = wgpu.wgpuBufferGetConstMappedRange(self.staging_buffer, 0, buf_size);
        if (mapped_ptr == null) {
            // Fallback to CPU renderer if readback fails
            if (self.cpu_fallback_engine) |*cpu| {
                return cpu.render(fg);
            }
            return error.MappedRangeNull;
        }

        const bytes: [*]const u8 = @ptrCast(mapped_ptr);
        @memcpy(self.output_buffer, bytes[0..buf_size]);
        wgpu.wgpuBufferUnmap(self.staging_buffer);

        return self.output_buffer;
    }
};
