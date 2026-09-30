//! Minimal Win32 + WGL bindings for creating an offscreen OpenGL context
//! on Windows. Only what the OpenGL renderer needs is declared; drop down
//! to `std.os.windows` for everything else.

const std = @import("std");
const windows = std.os.windows;

pub const HWND = windows.HWND;
pub const HDC = windows.HDC;
pub const HGLRC = windows.HGLRC;
pub const HINSTANCE = windows.HINSTANCE;
pub const HBRUSH = windows.HBRUSH;
pub const HICON = windows.HICON;
pub const HCURSOR = windows.HCURSOR;
pub const HMENU = windows.HMENU;
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const UINT = windows.UINT;
pub const WORD = windows.WORD;
pub const LONG = windows.LONG;
pub const ULONG = windows.ULONG;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPVOID = windows.LPVOID;
pub const WPARAM = windows.ULONG_PTR;
pub const LPARAM = windows.LONG_PTR;
pub const LRESULT = windows.LONG_PTR;
pub const COLORREF = u32;
pub const FALSE: BOOL = .fromBool(false);
pub const TRUE: BOOL = .fromBool(true);

pub const FARPROC = *const fn () callconv(.winapi) isize;

/// HGLRC proc type returned by wglGetProcAddress.
pub const WGLPROC = *const anyopaque;

// Window styles for the offscreen helper window.
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;

// ShowWindow commands.
pub const SW_HIDE: c_int = 0;

// GetDC constants.
pub const WGL_SWAP_MAIN_PLANE: UINT = 0;

/// PIXELFORMATDESCRIPTOR, see wingdi.h.
pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: WORD = 1,
    dwFlags: DWORD,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8 = 0,
    iLayerType: u8,
    bReserved: u8 = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_TYPE_RGBA: u8 = 0;
pub const PFD_MAIN_PLANE: u8 = 0;

/// WNDCLASSW, see winuser.h.
pub const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const COLOR_WINDOW: UINT = 5;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;

/// Registry and constants for WGL_ARB_create_context.
pub const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
pub const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
pub const WGL_CONTEXT_FLAGS_ARB: c_int = 0x2094;
pub const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x0001;
/// Attribute list terminator.
pub const WGL_NONE: c_int = 0;

/// The name of the wglCreateContextAttribsARB function.
pub const wglCreateContextAttribsARB_name = "wglCreateContextAttribsARB";

pub const exp = struct {
    pub extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) callconv(.winapi) WORD;
    pub extern "user32" fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: LPCWSTR,
        lpWindowName: LPCWSTR,
        dwStyle: DWORD,
        X: c_int,
        Y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: ?HWND,
        hMenu: ?HMENU,
        hInstance: ?HINSTANCE,
        lpParam: ?LPVOID,
    ) callconv(.winapi) ?HWND;
    pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn DefWindowProcW(
        hWnd: HWND,
        Msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(.winapi) LRESULT;

    pub extern "gdi32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
    pub extern "gdi32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;
    pub extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
    pub extern "gdi32" fn SetPixelFormat(hdc: HDC, iPixelFormat: c_int, ppfd: ?*const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;

    pub extern "opengl32" fn wglCreateContext(hdc: ?HDC) callconv(.winapi) ?HGLRC;
    pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
    pub extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
    pub extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?WGLPROC;

    pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?FARPROC;
    pub extern "kernel32" fn GetModuleHandleExW(
        dwFlags: DWORD,
        lpModuleName: ?LPCWSTR,
        phModule: **anyopaque,
    ) callconv(.winapi) BOOL;
};

pub const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: DWORD = 0x00000004;
pub const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: DWORD = 0x00000002;
