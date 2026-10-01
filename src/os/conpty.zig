//! Side-by-side Microsoft ConPTY. The OS-inbox host discards Kitty APC;
//! the pinned packaged host forwards original VT output in order while
//! retaining native console/TTY APIs. Never silently fall back to inbox.
const std = @import("std");
const w = @import("windows.zig");
const log = std.log.scoped(.conpty);

const kernel32 = struct {
    extern "kernel32" fn GetModuleFileNameW(?w.HANDLE, [*]u16, w.DWORD) callconv(.winapi) w.DWORD;
    extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, [*]u16, w.DWORD) callconv(.winapi) w.DWORD;
    extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) w.DWORD;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
    extern "kernel32" fn IsWow64Process2(w.HANDLE, *u16, *u16) callconv(.winapi) w.BOOL;
    extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?w.HANDLE, w.DWORD) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn GetProcAddress(w.HANDLE, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(w.HANDLE) callconv(.winapi) w.BOOL;
};

pub const Api = struct {
    library: w.HANDLE,
    create_native: *const fn (w.COORD, w.HANDLE, w.HANDLE, w.DWORD, *w.HPCON) callconv(.winapi) w.HRESULT,
    pack: @import("conpty_host.zig").Pack,
    host_path: [:0]const u16,
    resize: *const fn (w.HPCON, w.COORD) callconv(.winapi) w.HRESULT,
    close: *const fn (w.HPCON) callconv(.winapi) void,

    pub const LoadError = error{
        PathTooLong,
        InvalidBackendDirectory,
        UnsupportedNativeArchitecture,
        MissingConsoleHost,
        LoadLibraryFailed,
        MissingExport,
        OutOfMemory,
    };

    pub fn load() LoadError!Api {
        var path: [32768]u16 = undefined;
        var len: usize = kernel32.GetEnvironmentVariableW(
            std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_CONPTY_DIR"),
            &path,
            path.len,
        );
        if (len >= path.len) return error.PathTooLong;
        if (len == 0) {
            len = kernel32.GetModuleFileNameW(null, &path, path.len);
            if (len == 0 or len >= path.len) return error.PathTooLong;
            len = std.mem.lastIndexOfScalar(u16, path[0..len], '\\') orelse return error.InvalidBackendDirectory;
            try append(&path, &len, std.unicode.utf8ToUtf16LeStringLiteral("\\conpty"));
        }
        // A developer/test override must also be absolute; never search PATH
        // or the working directory for executable code.
        if (!(len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) and
            !(len >= 2 and path[0] == '\\' and path[1] == '\\')) return error.InvalidBackendDirectory;
        const directory_len = len;

        // The DLL itself falls back to system conhost when OpenConsole is
        // missing. Reject that layout instead of silently losing graphics.
        var unused: u16 = 0;
        var native_machine: u16 = 0;
        if (kernel32.IsWow64Process2(kernel32.GetCurrentProcess(), &unused, &native_machine) == w.FALSE)
            return error.UnsupportedNativeArchitecture;
        const host_suffix = switch (native_machine) {
            0x014c => std.unicode.utf8ToUtf16LeStringLiteral("\\x86\\OpenConsole.exe"),
            0x8664 => std.unicode.utf8ToUtf16LeStringLiteral("\\x64\\OpenConsole.exe"),
            0xaa64 => std.unicode.utf8ToUtf16LeStringLiteral("\\arm64\\OpenConsole.exe"),
            else => return error.UnsupportedNativeArchitecture,
        };
        try append(&path, &len, std.unicode.utf8ToUtf16LeStringLiteral("\\OpenConsole.exe"));
        if (kernel32.GetFileAttributesW(path[0..len :0].ptr) == 0xffffffff) {
            len = directory_len;
            try append(&path, &len, host_suffix);
            if (kernel32.GetFileAttributesW(path[0..len :0].ptr) == 0xffffffff) return error.MissingConsoleHost;
        }
        const host_path = try std.heap.page_allocator.dupeZ(u16, path[0..len]);
        errdefer std.heap.page_allocator.free(host_path);
        len = directory_len;
        try append(&path, &len, std.unicode.utf8ToUtf16LeStringLiteral("\\conpty.dll"));
        // DLL_LOAD_DIR + SYSTEM32: dependent DLLs cannot be resolved from CWD.
        const library = kernel32.LoadLibraryExW(path[0..len :0].ptr, null, 0x100 | 0x800) orelse {
            log.err("failed to load packaged ConPTY err={}", .{w.GetLastError()});
            return error.LoadLibraryFailed;
        };
        errdefer _ = kernel32.FreeLibrary(library);
        return .{
            .library = library,
            .create_native = @ptrCast(kernel32.GetProcAddress(library, "ConptyCreatePseudoConsole") orelse return error.MissingExport),
            .pack = @ptrCast(kernel32.GetProcAddress(library, "ConptyPackPseudoConsole") orelse return error.MissingExport),
            .host_path = host_path,
            .resize = @ptrCast(kernel32.GetProcAddress(library, "ConptyResizePseudoConsole") orelse return error.MissingExport),
            .close = @ptrCast(kernel32.GetProcAddress(library, "ConptyClosePseudoConsole") orelse return error.MissingExport),
        };
    }

    /// The packaged factory launches headless OpenConsole without disabling
    /// Windows GUI startup feedback. Launch it explicitly for flags=0 (our
    /// terminal path), then let the DLL pack/own the native handles as usual.
    pub fn create(self: Api, size: w.COORD, input: w.HANDLE, output: w.HANDLE, flags: w.DWORD, console: *w.HPCON) w.HRESULT {
        if (flags != 0) return self.create_native(size, input, output, flags, console);
        console.* = @import("conpty_host.zig").create(self.host_path, self.pack, size, input, output) catch |err| {
            log.err("failed to start packaged console host without startup feedback err={}", .{err});
            return @bitCast(@as(u32, 0x80004005)); // E_FAIL
        };
        return w.S_OK;
    }

    /// Call only after every HPCON created through this API has been closed.
    pub fn deinit(self: Api) void {
        std.heap.page_allocator.free(self.host_path);
        _ = kernel32.FreeLibrary(self.library);
    }
};

fn append(buffer: []u16, len: *usize, suffix: []const u16) Api.LoadError!void {
    if (len.* + suffix.len >= buffer.len) return error.PathTooLong;
    @memcpy(buffer[len.*..][0..suffix.len], suffix);
    len.* += suffix.len;
    buffer[len.*] = 0;
}

test "native ConPTY path append is bounded" {
    var buffer: [8]u16 = undefined;
    var len: usize = 0;
    try append(&buffer, &len, &.{ 'C', ':', '\\' });
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqual(@as(u16, 0), buffer[len]);
    try std.testing.expectError(error.PathTooLong, append(&buffer, &len, &.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(@as(usize, 3), len);
}
