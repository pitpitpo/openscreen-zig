const std = @import("std");
const ffi = @import("ffi");
const shim = ffi.capture;

pub const WebcamFrame = struct {
    rgba: []u8,
    width: u32,
    height: u32,
    pts_ns: i64,

    pub fn deinit(self: *WebcamFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
    }
};

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const WebcamCapture = struct {
    allocator: std.mem.Allocator,
    width: u32 = 0,
    height: u32 = 0,
    latest_frame: ?WebcamFrame = null,
    mutex: SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator) WebcamCapture {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebcamCapture) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.latest_frame) |*f| {
            f.deinit(self.allocator);
            self.latest_frame = null;
        }
    }

    pub fn handleFrame(self: *WebcamCapture, data: []const u8, w: u32, h: u32, pts_ns: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.latest_frame) |*old| {
            old.deinit(self.allocator);
            self.latest_frame = null;
        }

        const buf = try self.allocator.alloc(u8, data.len);
        @memcpy(buf, data);

        self.width = w;
        self.height = h;
        self.latest_frame = .{
            .rgba = buf,
            .width = w,
            .height = h,
            .pts_ns = pts_ns,
        };
    }

    pub fn copyLatestFrame(self: *WebcamCapture, out_rgba: []u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.latest_frame) |f| {
            if (out_rgba.len >= f.rgba.len) {
                @memcpy(out_rgba[0..f.rgba.len], f.rgba);
                return true;
            }
        }
        return false;
    }
};
