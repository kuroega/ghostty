//! Native ConPTY feasibility probe. No Ghostty, Pi patches, JS preload, or
//! image renderer is involved. A native console client writes valid Kitty
//! commands to CONOUT$; the parent inspects the actual ConPTY output pipe.
//! Build: zig build-exe test/windows/conpty-images.zig -O ReleaseSafe
//! Run: conpty-images.exe [flags, default 0] [absolute conpty.dll path]
//! Keep the matching OpenConsole.exe next to the DLL for the packaged backend.
const std = @import("std");
const w = std.os.windows;
const H = w.HANDLE;

const k = struct {
    extern "kernel32" fn CreatePipe(*H, *H, ?*anyopaque, u32) callconv(.winapi) i32;
    extern "kernel32" fn CreatePseudoConsole(w.COORD, H, H, u32, *H) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(H) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) i32;
    extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, u32, usize, *anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) i32;
    extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(?[*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*anyopaque, ?[*:0]const u16, *Startup, *Process) callconv(.winapi) i32;
    extern "kernel32" fn ReadFile(H, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(H) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(H, u32) callconv(.winapi) u32;
    extern "kernel32" fn TerminateProcess(H, u32) callconv(.winapi) i32;
    extern "kernel32" fn GetExitCodeProcess(H, *u32) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn CreateEventW(?*anyopaque, i32, i32, [*:0]const u16) callconv(.winapi) ?H;
    extern "kernel32" fn OpenEventW(u32, i32, [*:0]const u16) callconv(.winapi) ?H;
    extern "kernel32" fn SetEvent(H) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(H, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?H, u32) callconv(.winapi) ?H;
    extern "kernel32" fn GetProcAddress(H, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(H) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?H) callconv(.winapi) H;
    extern "kernel32" fn GetConsoleMode(H, *u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(H, u32) callconv(.winapi) i32;
    extern "kernel32" fn WriteConsoleW(H, [*]const u16, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
};
const Startup = extern struct { si: w.STARTUPINFOW, attrs: *anyopaque };
const Process = extern struct { process: H, thread: H, pid: u32, tid: u32 };

const simple = "\x1b_Ga=T,f=24,s=1,v=1,i=123,q=2,C=1;/wAA\x1b\\";
const query = "\x1b_Ga=q,i=124,f=24,s=1,v=1;AAAA\x1b\\";
const delete = "\x1b_Ga=d,d=A,q=2\x1b\\";
const before = "BEFORE_IMAGE";
const after = "AFTER_IMAGE";
const done = "AFTER_QUERY_AND_DELETE";
const reply = "\x1b_Gi=124;OK\x1b\\";
const reply_marker = "QUERY_REPLY_PRESERVED";
const payload = before ++ "\x1b[?2026h" ++ simple ++ after ++
    "\x1b_Ga=T,f=24,s=32,v=32,i=125,q=2,C=1,m=1;" ++ ("A" ** 2048) ++ "\x1b\\" ++
    "\x1b_Gm=0;" ++ ("A" ** 2048) ++ "\x1b\\" ++ query ++ delete ++ "\x1b[?2026l" ++ done ++ "\r\n";

fn check(result: i32) !void {
    if (result == 0) return error.Win32CallFailed;
}

fn child(alloc: std.mem.Allocator, ready_name: []const u8) !void {
    // Explicitly open the attached console: inherited redirected parent
    // stdout handles must not let the child bypass ConPTY accidentally.
    const output = k.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"), 0xc0000000, 3, null, 3, 0x80, null);
    if (output == w.INVALID_HANDLE_VALUE) return error.NoAttachedConsole;
    defer _ = k.CloseHandle(output);
    var mode: u32 = 0;
    try check(k.GetConsoleMode(output, &mode));
    try check(k.SetConsoleMode(output, mode | 0x0004)); // ENABLE_VIRTUAL_TERMINAL_PROCESSING
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, payload);
    var written: u32 = 0;
    try check(k.WriteConsoleW(output, wide.ptr, @intCast(wide.len), &written, null));
    if (written != wide.len) return error.ShortConsoleWrite;
    const input = k.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"), 0xc0000000, 3, null, 3, 0x80, null);
    if (input == w.INVALID_HANDLE_VALUE) return error.NoAttachedConsoleInput;
    defer _ = k.CloseHandle(input);
    try check(k.SetConsoleMode(input, 0x0200)); // raw VT input, no echo/line processing
    const event_name = try std.unicode.utf8ToUtf16LeAllocZ(alloc, ready_name);
    const ready = k.OpenEventW(0x0002, 0, event_name.ptr) orelse return error.OpenReadyEventFailed;
    defer _ = k.CloseHandle(ready);
    try check(k.SetEvent(ready));
    var response: [reply.len]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        var count: u32 = 0;
        try check(k.ReadFile(input, response[used..].ptr, @intCast(response.len - used), &count, null));
        if (count == 0) return error.QueryReplyReadFailed;
        used += count;
    }
    if (!std.mem.eql(u8, &response, reply)) return error.QueryReplyChanged;
    const reply_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, reply_marker);
    try check(k.WriteConsoleW(output, reply_wide.ptr, @intCast(reply_wide.len), &written, null));
}

const Capture = struct {
    bytes: [64 * 1024]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    fn read(self: *@This(), pipe: H) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            var n: u32 = 0;
            if (k.ReadFile(pipe, &buf, buf.len, &n, null) == 0 or n == 0) return;
            const keep = @min(n, self.bytes.len - self.len);
            @memcpy(self.bytes[self.len..][0..keep], buf[0..keep]);
            self.len += keep;
            if (keep != n) self.overflow = true;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    if (comptime @import("builtin").os.tag != .windows) return error.WindowsOnly;
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len > 2 and std.mem.eql(u8, args[1], "--child")) return child(alloc, args[2]);
    const flags = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 0) else 0;
    const Create = *const fn (w.COORD, H, H, u32, *H) callconv(.winapi) i32;
    const Close = *const fn (H) callconv(.winapi) void;
    var create: Create = &k.CreatePseudoConsole;
    var close: Close = &k.ClosePseudoConsole;
    var library: ?H = null;
    defer if (library) |lib| {
        _ = k.FreeLibrary(lib);
    };
    if (args.len > 2) {
        const path = try std.unicode.utf8ToUtf16LeAllocZ(alloc, args[2]);
        library = k.LoadLibraryExW(path.ptr, null, 0x00000100 | 0x00000800) orelse return error.LoadBackendFailed;
        create = @ptrCast(k.GetProcAddress(library.?, "ConptyCreatePseudoConsole") orelse return error.MissingCreateExport);
        close = @ptrCast(k.GetProcAddress(library.?, "ConptyClosePseudoConsole") orelse return error.MissingCloseExport);
    }

    var input_read: H = undefined;
    var input_write: H = undefined;
    var output_read: H = undefined;
    var output_write: H = undefined;
    try check(k.CreatePipe(&input_read, &input_write, null, 0));
    defer _ = k.CloseHandle(input_read);
    defer _ = k.CloseHandle(input_write);
    try check(k.CreatePipe(&output_read, &output_write, null, 0));
    defer _ = k.CloseHandle(output_read);
    var pc: H = undefined;
    const hr = create(.{ .X = 80, .Y = 24 }, input_read, output_write, flags, &pc);
    _ = k.CloseHandle(output_write);
    if (hr != 0) {
        std.debug.print("CreatePseudoConsole flags=0x{x}: HRESULT=0x{x}\n", .{ flags, @as(u32, @bitCast(hr)) });
        return error.PseudoConsoleCreationFailed;
    }

    // Drain concurrently: ClosePseudoConsole may wait for output consumption.
    var capture: Capture = .{};
    const reader = std.Thread.spawn(.{}, Capture.read, .{ &capture, output_read }) catch |err| {
        close(pc);
        return err;
    };
    var closed = false;
    var joined = false;
    defer {
        if (!closed) close(pc);
        if (!joined) reader.join();
    }
    var attr_size: usize = 0;
    _ = k.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attrs = try alloc.alignedAlloc(u8, .of(usize), attr_size);
    try check(k.InitializeProcThreadAttributeList(attrs.ptr, 1, 0, &attr_size));
    defer k.DeleteProcThreadAttributeList(attrs.ptr);
    try check(k.UpdateProcThreadAttribute(attrs.ptr, 0, 0x00020016, pc, @sizeOf(H), null, null));
    var startup: Startup = .{ .si = std.mem.zeroes(w.STARTUPINFOW), .attrs = attrs.ptr };
    startup.si.cb = @sizeOf(Startup);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(init.io, &exe_buf);
    const ready_name = try std.fmt.allocPrint(alloc, "Local\\ghostty-native-query-{d}", .{k.GetCurrentProcessId()});
    const ready_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, ready_name);
    const ready = k.CreateEventW(null, 1, 0, ready_wide.ptr) orelse return error.CreateReadyEventFailed;
    defer _ = k.CloseHandle(ready);
    const command = try std.fmt.allocPrint(alloc, "\"{s}\" --child \"{s}\"", .{ exe_buf[0..exe_len], ready_name });
    const command_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, command);
    var process: Process = undefined;
    try check(k.CreateProcessW(null, command_w.ptr, null, null, 0, 0x00080000, null, null, &startup, &process));
    defer _ = k.CloseHandle(process.process);
    defer _ = k.CloseHandle(process.thread);
    if (k.WaitForSingleObject(ready, 5_000) != 0) {
        _ = k.TerminateProcess(process.process, 1);
        return error.ChildNotReady;
    }
    var written: u32 = 0;
    if (k.WriteFile(input_write, reply.ptr, reply.len, &written, null) == 0 or written != reply.len) {
        _ = k.TerminateProcess(process.process, 1);
        return error.QueryReplyWriteFailed;
    }
    const wait = k.WaitForSingleObject(process.process, 10_000);
    if (wait != 0) {
        _ = k.TerminateProcess(process.process, 1);
        return error.ChildWaitFailed;
    }
    var exit_code: u32 = 0;
    try check(k.GetExitCodeProcess(process.process, &exit_code));
    if (exit_code != 0) return error.NativeClientFailed;
    // Close now, then join, before inspecting the capture.
    close(pc);
    closed = true;
    reader.join();
    joined = true;
    const output = capture.bytes[0..capture.len];
    const markers = std.mem.indexOf(u8, output, before) != null and
        std.mem.indexOf(u8, output, after) != null and std.mem.indexOf(u8, output, done) != null;
    const commands = std.mem.count(u8, output, "\x1b_G");
    const ordered = std.mem.indexOf(u8, output, payload) != null;
    const reply_preserved = std.mem.indexOf(u8, output, reply_marker) != null;
    if (!reply_preserved) return error.QueryReplyDropped;
    std.debug.print("flags=0x{x} console-client=true markers={} Kitty_commands_sent=5 received={d} ordered={} query_reply={} captured_bytes={d}\n", .{ flags, markers, commands, ordered, reply_preserved, output.len });
    if (!markers or capture.overflow) return error.InconclusiveCapture;
    if (commands != 5) {
        std.debug.print("BLOCKED: ConPTY removed native-client graphics before any Ghostty parser/renderer.\n", .{});
        if (library != null) return error.GraphicsDropped;
    } else {
        if (!ordered) return error.VtOrderChanged;
        std.debug.print("PRESERVED: original graphics and surrounding VT/text order verified.\n", .{});
    }
}
