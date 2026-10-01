//! Launch the packaged headless console host without GUI startup feedback.
//! Mirrors Microsoft terminal's winconpty/DeviceHandle creation protocol
//! (Copyright Microsoft Corporation, MIT), using ConptyPackPseudoConsole to
//! retain the packaged DLL's ownership, resize and shutdown implementation.
//! Microsoft license text: vendor/conpty/LICENSE. No DLL binaries are patched.
const std = @import("std");
const w = @import("windows.zig");
const k = w.exp.kernel32;

pub const Pack = *const fn (w.HANDLE, w.HANDLE, w.HANDLE, *w.HPCON) callconv(.winapi) w.HRESULT;
const extra = struct {
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
    extern "kernel32" fn DuplicateHandle(w.HANDLE, w.HANDLE, w.HANDLE, *w.HANDLE, w.DWORD, w.BOOL, w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(w.LPPROC_THREAD_ATTRIBUTE_LIST) callconv(.winapi) void;
    extern "kernel32" fn TerminateProcess(w.HANDLE, w.UINT) callconv(.winapi) w.BOOL;
    extern "ntdll" fn NtSetSystemInformation(u32, *anyopaque, u32) callconv(.winapi) w.NTSTATUS;
};

fn openDevice(name: []const u16, parent: ?w.HANDLE, inherit: bool, access: u32, options: u32) !w.HANDLE {
    var unicode: w.UNICODE_STRING = .init(name);
    var attrs: w.OBJECT_ATTRIBUTES = .{
        .ObjectName = &unicode,
        .RootDirectory = parent,
        .Attributes = .{ .INHERIT = inherit },
    };
    var io_status: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const status = w.exp.ntdll.NtOpenFile(&handle, @bitCast(access), &attrs, &io_status, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, options);
    if (status != .SUCCESS) return w.unexpectedStatus(status);
    return handle;
}

fn duplicate(handle: w.HANDLE) !w.HANDLE {
    var result: w.HANDLE = undefined;
    const current = extra.GetCurrentProcess();
    if (extra.DuplicateHandle(current, handle, current, &result, 0, w.TRUE, 2) == w.FALSE)
        return w.unexpectedError(w.GetLastError());
    return result;
}

pub fn create(host: [:0]const u16, pack: Pack, size: w.COORD, input: w.HANDLE, output: w.HANDLE) !w.HPCON {
    if (size.X <= 0 or size.Y <= 0) return error.InvalidSize;
    const alloc = std.heap.page_allocator;
    const server = openDevice(std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\ConDrv\\Server"), null, true, 0x10000000, 0) catch blk: {
        // Same lazy ConDrv loading used by the packaged creation function.
        var driver_loaded: u32 = 1;
        _ = extra.NtSetSystemInformation(132, &driver_loaded, @sizeOf(u32));
        break :blk try openDevice(std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\ConDrv\\Server"), null, true, 0x10000000, 0);
    };
    defer _ = k.CloseHandle(server);
    const reference = try openDevice(std.unicode.utf8ToUtf16LeStringLiteral("\\Reference"), server, false, 0x80000000 | 0x40000000 | w.SYNCHRONIZE, w.FILE_SYNCHRONOUS_IO_NONALERT);
    errdefer _ = k.CloseHandle(reference);

    var signal_host: w.HANDLE = undefined;
    var signal_us: w.HANDLE = undefined;
    if (k.CreatePipe(&signal_host, &signal_us, null, 0) == w.FALSE)
        return w.unexpectedError(w.GetLastError());
    defer _ = k.CloseHandle(signal_host);
    errdefer _ = k.CloseHandle(signal_us);
    if (k.SetHandleInformation(signal_host, w.HANDLE_FLAG_INHERIT, w.HANDLE_FLAG_INHERIT) == w.FALSE)
        return w.unexpectedError(w.GetLastError());
    const in_copy = try duplicate(input);
    defer _ = k.CloseHandle(in_copy);
    const out_copy = try duplicate(output);
    defer _ = k.CloseHandle(out_copy);

    // The explicit application path and quoted command line avoid PATH/CWD
    // searches. Only these four inheritable handles reach OpenConsole.
    const host_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, host);
    defer alloc.free(host_utf8);
    const command = try std.fmt.allocPrint(alloc, "\"{s}\" --headless --width {d} --height {d} --signal 0x{x} --server 0x{x}", .{ host_utf8, size.X, size.Y, @intFromPtr(signal_host), @intFromPtr(server) });
    defer alloc.free(command);
    const command_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, command);
    defer alloc.free(command_w);

    var bytes: usize = 0;
    _ = k.InitializeProcThreadAttributeList(null, 1, 0, &bytes);
    const attributes = try alloc.alloc(u8, bytes);
    defer alloc.free(attributes);
    if (k.InitializeProcThreadAttributeList(attributes.ptr, 1, 0, &bytes) == w.FALSE)
        return w.unexpectedError(w.GetLastError());
    defer extra.DeleteProcThreadAttributeList(attributes.ptr);
    var inherited = [_]w.HANDLE{ server, in_copy, out_copy, signal_host };
    if (k.UpdateProcThreadAttribute(attributes.ptr, 0, 0x00020002, &inherited, @sizeOf(@TypeOf(inherited)), null, null) == w.FALSE)
        return w.unexpectedError(w.GetLastError());
    var startup: w.STARTUPINFOEX = .{
        .StartupInfo = std.mem.zeroes(w.STARTUPINFOW),
        .lpAttributeList = attributes.ptr,
    };
    startup.StartupInfo.cb = @sizeOf(w.STARTUPINFOEX);
    startup.StartupInfo.hStdInput = in_copy;
    startup.StartupInfo.hStdOutput = out_copy;
    startup.StartupInfo.hStdError = out_copy;
    startup.StartupInfo.dwFlags = w.STARTF_USESTDHANDLES | w.STARTF_FORCEOFFFEEDBACK;
    var process: w.PROCESS_INFORMATION = undefined;
    if (k.CreateProcessW(host.ptr, command_w.ptr, null, null, w.TRUE, w.EXTENDED_STARTUPINFO_PRESENT, null, null, &startup.StartupInfo, &process) == w.FALSE)
        return w.unexpectedError(w.GetLastError());
    defer _ = k.CloseHandle(process.hThread);
    errdefer {
        _ = extra.TerminateProcess(process.hProcess, 1);
        _ = k.CloseHandle(process.hProcess);
    }
    var console: w.HPCON = undefined;
    if (pack(process.hProcess, reference, signal_us, &console) != w.S_OK)
        return error.PackPseudoConsoleFailed;
    // Ownership of all three handles transfers to the DLL's HPCON.
    return console;
}

test "native ConPTY host rejects invalid size before opening handles" {
    const unused: w.HANDLE = @ptrFromInt(1);
    const mock = struct {
        fn pack(_: w.HANDLE, _: w.HANDLE, _: w.HANDLE, _: *w.HPCON) callconv(.winapi) w.HRESULT {
            unreachable;
        }
    };
    try std.testing.expectError(error.InvalidSize, create(std.unicode.utf8ToUtf16LeStringLiteral("unused.exe"), mock.pack, .{ .X = 0, .Y = 24 }, unused, unused));
    try std.testing.expectError(error.InvalidSize, create(std.unicode.utf8ToUtf16LeStringLiteral("unused.exe"), mock.pack, .{ .X = 80, .Y = -1 }, unused, unused));
}
