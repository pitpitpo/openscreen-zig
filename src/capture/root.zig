pub const capture = @import("capture.zig");
pub const audio_capture = @import("audio_capture.zig");
pub const webcam_capture = @import("webcam_capture.zig");
pub const shim = @import("ffi").capture;

pub const CaptureSession = capture.CaptureSession;
pub const sleepMs = capture.sleepMs;
pub const CaptureOptions = capture.CaptureOptions;
pub const SessionState = capture.SessionState;
pub const CursorSidecarEvent = capture.CursorSidecarEvent;
pub const AudioCapture = audio_capture.AudioCapture;
pub const WebcamCapture = webcam_capture.WebcamCapture;

test {
    _ = capture;
    _ = audio_capture;
    _ = webcam_capture;
}
