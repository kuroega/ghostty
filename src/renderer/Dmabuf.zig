//! A DMABUF frame produced by exporting a GPU texture.
//! This may be used on apprts like GTK that require us to manually
//! export each frame and import them as textures in their UI scene graphs.
//!
//! Note that DMABUFs are independent of the graphics API used:
//! the OpenGL renderer allocates them with GBM, and Vulkan can
//! export them with a KHR external memory implementation. Therefore
//! this struct has to be placed parallel to the renderer
//! implementations.
pub const Dmabuf = @This();
pub const std = @import("std");
const builtin = @import("builtin");

/// The maximum number of planes in a DMABUF that we support.
/// This matches the maximum found in apprts such as GTK.
pub const max_planes = 4;

/// Width of the texture in device pixels.
width: u32,

/// Height of the texture in device pixels.
height: u32,

/// DRM fourcc of the pixel format.
/// Ghostty renders RGBA/BGRA8 premultiplied.
fourcc: u32,

/// DRM modifier of the format.
modifier: u64,

/// Whether the data is premultiplied.
/// Ghostty's GL renderers output premultiplied alpha.
premultiplied: bool,

/// The DMABUF planes for a presented frame. The DMABUF owns the fds
/// and must either call `deinit` manually, or pass them to an apprt
/// that consumes them.
planes: Planes,

pub const Planes = struct {
    /// Number of planes. Valid planes are `planes[0..count]`.
    count: u8,

    /// File descriptor for each plane.
    /// On Windows this is never used (DMA-BUF is a Linux mechanism) but
    /// the type must compile; we use an int-sized placeholder so the
    /// sentinel value and comparisons below behave identically.
    fds: [max_planes]Fd = @splat(invalid_fd),

    /// Offset into the DMABUF where each plane starts, in bytes.
    offsets: [max_planes]c_int = @splat(0),

    /// Strides of each plane, in bytes.
    strides: [max_planes]c_int = @splat(0),

    /// The platform file descriptor type. On Windows, `std.posix.fd_t`
    /// is a HANDLE (pointer) so the integer sentinel/comparisons below
    /// don't compile. DMA-BUFs are never created on Windows so the
    /// value is never used there.
    pub const Fd = if (builtin.os.tag == .windows) i32 else std.posix.fd_t;

    /// The invalid sentinel value for `Fd`.
    pub const invalid_fd: Fd = if (builtin.os.tag == .windows) -1 else -1;

    /// Close an open fd.
    fn closeFd(fd: Fd) void {
        switch (builtin.os.tag) {
            // DMA-BUF planes are never created or closed on Windows.
            .windows => unreachable,
            else => _ = std.posix.system.close(fd),
        }
    }

    /// Close all valid fds.
    pub fn deinit(self: Planes) void {
        for (self.fds[0..self.count]) |fd| {
            if (fd >= 0) closeFd(fd);
        }
    }

    /// Validate the current planes. If any plane failed to export
    /// and has an invalid FD, we close all the known valid FDs
    /// and bail.
    pub fn validate(self: Planes) error{BadDmabuf}!void {
        var n_valid: usize = 0;
        while (n_valid < self.count) : (n_valid += 1) {
            if (self.fds[n_valid] < 0) {
                for (self.fds[0..n_valid]) |bad| closeFd(bad);
                return error.BadDmabuf;
            }
        }
    }
};

pub fn deinit(self: Dmabuf) void {
    self.planes.deinit();
}
