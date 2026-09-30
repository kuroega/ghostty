//! Offscreen WGL OpenGL context for Windows.
//!
//! Ghostty's OpenGL renderer draws entirely offscreen (framebuffer
//! objects) and exports frames to the apprt; the window system only
//! needs to provide a current GL context, not a visible surface. This
//! mirrors the EGL surfaceless platform used on Linux.
//!
//! On Windows there is no "surfaceless" WGL, so we create a hidden
//! helper window, pick a hardware-accelerated pixel format on its DC,
//! and create a core-profile context via WGL_ARB_create_context. The
//! DC must remain valid for the lifetime of the context.

const std = @import("std");
const win32 = @import("wgl.zig");
const windows = std.os.windows;

const LPCWSTR = win32.LPCWSTR;

const log = std.log.scoped(.opengl_wgl);

pub const Error = error{
    RegisterClassFailed,
    CreateWindowFailed,
    GetDCFailed,
    ChoosePixelFormatFailed,
    SetPixelFormatFailed,
    WglCreateContextFailed,
    WglGetProcAddressFailed,
    WglMakeCurrentFailed,
};

pub const WglContext = @This();

hwnd: win32.HWND,
hdc: win32.HDC,
hglrc: win32.HGLRC,

/// The WGL_ARB_create_context extension function, resolved off the
/// legacy context during `init`.
const CreateContextAttribsFn = *const fn (
    hDC: win32.HDC,
    hshareContext: ?win32.HGLRC,
    attribList: [*]const c_int,
) callconv(.winapi) ?win32.HGLRC;

/// GetDC with a null window returns the screen DC, but a window DC with
/// CS_OWNDC is the most compatible with SetPixelFormat (which can only
/// be called once per window). We create a tiny hidden window for this.
pub fn init() Error!@This() {
    // Get our own module handle (the exe) for the window class.
    var hinstance: *anyopaque = undefined;
    if (win32.exp.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @as(LPCWSTR, @ptrFromInt(@intFromPtr(&init))),
        &hinstance,
    ) == win32.FALSE) {
        log.err("GetModuleHandleExW failed err={}", .{windows.GetLastError()});
        return error.RegisterClassFailed;
    }
    const hinstance_h: win32.HINSTANCE = @ptrCast(hinstance);

    // Register our window class. RegisterClassW fails with 0 if already
    // registered, which is fine (another renderer instance did it).
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGLContext");
    const wc: win32.WNDCLASSW = .{
        .style = win32.CS_OWNDC,
        .lpfnWndProc = dummyWndProc,
        .hInstance = hinstance_h,
        .lpszClassName = class_name.ptr,
    };
    _ = win32.exp.RegisterClassW(&wc);

    const hwnd = win32.exp.CreateWindowExW(
        0, // extended style
        class_name.ptr,
        class_name.ptr,
        win32.WS_POPUP, // hidden popup window
        0,
        0,
        1,
        1,
        null,
        null,
        hinstance_h,
        null,
    ) orelse {
        log.err("CreateWindowExW failed err={}", .{windows.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = win32.exp.DestroyWindow(hwnd);

    const hdc = win32.exp.GetDC(hwnd) orelse {
        log.err("GetDC failed err={}", .{windows.GetLastError()});
        return error.GetDCFailed;
    };
    errdefer _ = win32.exp.ReleaseDC(hwnd, hdc);

    // Choose a hardware-accelerated RGBA pixel format.
    const pfd: win32.PIXELFORMATDESCRIPTOR = .{
        .dwFlags = win32.PFD_DRAW_TO_WINDOW | win32.PFD_SUPPORT_OPENGL,
        .iPixelType = win32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cAlphaBits = 8,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .iLayerType = win32.PFD_MAIN_PLANE,
    };
    const format = win32.exp.ChoosePixelFormat(hdc, &pfd);
    if (format == 0) {
        log.err("ChoosePixelFormat failed err={}", .{windows.GetLastError()});
        return error.ChoosePixelFormatFailed;
    }
    if (win32.exp.SetPixelFormat(hdc, format, null) == win32.FALSE) {
        log.err("SetPixelFormat failed err={}", .{windows.GetLastError()});
        return error.SetPixelFormatFailed;
    }

    // Create a throwaway legacy context so we can resolve
    // wglCreateContextAttribsARB (WGL entry points are only valid with
    // a current context).
    const legacy = win32.exp.wglCreateContext(hdc) orelse {
        log.err("wglCreateContext failed err={}", .{windows.GetLastError()});
        return error.WglCreateContextFailed;
    };
    defer _ = win32.exp.wglDeleteContext(legacy);

    if (win32.exp.wglMakeCurrent(hdc, legacy) == win32.FALSE) {
        log.err("wglMakeCurrent (legacy) failed err={}", .{windows.GetLastError()});
        return error.WglMakeCurrentFailed;
    }
    defer _ = win32.exp.wglMakeCurrent(null, null);

    const create_attribs_fn: CreateContextAttribsFn = create: {
        const proc = win32.exp.wglGetProcAddress(win32.wglCreateContextAttribsARB_name) orelse {
            log.err("wglGetProcAddress(wglCreateContextAttribsARB) failed", .{});
            return error.WglGetProcAddressFailed;
        };
        break :create @ptrCast(@alignCast(proc));
    };

    // Core profile context, at least OpenGL 4.3 (matches the renderer's
    // MIN_VERSION).
    const attribs = [_]c_int{
        win32.WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
        win32.WGL_CONTEXT_MINOR_VERSION_ARB, 3,
        win32.WGL_CONTEXT_PROFILE_MASK_ARB,  win32.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        win32.WGL_NONE,
    };

    const hglrc = create_attribs_fn(hdc, null, &attribs) orelse {
        log.err("wglCreateContextAttribsARB failed err={}", .{windows.GetLastError()});
        return error.WglCreateContextFailed;
    };
    errdefer _ = win32.exp.wglDeleteContext(hglrc);

    return .{
        .hwnd = hwnd,
        .hdc = hdc,
        .hglrc = hglrc,
    };
}

pub fn deinit(self: @This()) void {
    _ = win32.exp.wglMakeCurrent(null, null);
    _ = win32.exp.wglDeleteContext(self.hglrc);
    _ = win32.exp.ReleaseDC(self.hwnd, self.hdc);
    _ = win32.exp.DestroyWindow(self.hwnd);
}

/// Make the context current on the calling thread.
pub fn makeCurrent(self: @This()) Error!void {
    if (win32.exp.wglMakeCurrent(self.hdc, self.hglrc) == win32.FALSE) {
        log.err("wglMakeCurrent failed err={}", .{windows.GetLastError()});
        return error.WglMakeCurrentFailed;
    }
}

/// Release the context from the calling thread.
pub fn releaseCurrent(self: @This()) void {
    _ = self;
    _ = win32.exp.wglMakeCurrent(null, null);
}

/// GL proc address resolver for glad, using wglGetProcAddress. Note
/// wglGetProcAddress returns null for OpenGL 1.x functions; those are
/// exported directly by opengl32.dll. glad's dlopen-based fallback
/// loader handles both cases, but our resolver must handle 1.x names
/// that the core profile needs, so we also check opengl32.dll.
pub fn getProcAddress(name: [*:0]const u8) ?*const anyopaque {
    if (win32.exp.wglGetProcAddress(name)) |proc| return proc;

    // Fall back to opengl32.dll exports (GL 1.0/1.1 functions).
    var opengl32: *anyopaque = undefined;
    if (win32.exp.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll").ptr,
        &opengl32,
    ) == win32.FALSE) return null;
    const far = win32.exp.GetProcAddress(opengl32, name) orelse return null;
    return @ptrCast(far);
}

fn dummyWndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    return win32.exp.DefWindowProcW(hwnd, msg, wParam, lParam);
}
