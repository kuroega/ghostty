//! Win32 API bindings for the win32 apprt (windowing, input, clipboard,
//! GDI frame presentation). Only what the apprt uses is declared.
//!
//! Note `src/os/windows.zig` holds the kernel32/ntdll bindings used by
//! the core (PTY, IO); this file holds the user32/gdi32 side.

const std = @import("std");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const UINT = windows.UINT;
pub const WORD = windows.WORD;
pub const LONG = windows.LONG;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPVOID = windows.LPVOID;
pub const HANDLE = windows.HANDLE;
pub const WPARAM = windows.ULONG_PTR;
pub const LPARAM = windows.LONG_PTR;
pub const LRESULT = windows.LONG_PTR;
pub const HWND = windows.HWND;
pub const HDC = windows.HDC;
pub const HINSTANCE = windows.HINSTANCE;
pub const HICON = windows.HICON;
pub const HCURSOR = windows.HCURSOR;
pub const HBRUSH = windows.HBRUSH;
pub const HMENU = windows.HMENU;
pub const FALSE: BOOL = .fromBool(false);
pub const TRUE: BOOL = .fromBool(true);

pub const FARPROC = *const fn () callconv(.winapi) isize;

pub const WM_NCCALCSIZE: UINT = 0x0083;
pub const WM_NCHITTEST: UINT = 0x0084;
pub const WM_NCMOUSEMOVE: UINT = 0x00A0;
pub const WM_NCMOUSELEAVE: UINT = 0x02A2;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SYSCOMMAND: UINT = 0x0112;
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTMINBUTTON: LRESULT = 8;
pub const HTMAXBUTTON: LRESULT = 9;
pub const HTCLOSE: LRESULT = 20;
pub const SC_MINIMIZE: WPARAM = 0xF020;
pub const SC_MAXIMIZE: WPARAM = 0xF030;
pub const SC_RESTORE: WPARAM = 0xF120;
pub const NULL_PEN: c_int = 8;
pub const TRANSPARENT: c_int = 1;
pub const DT_SINGLELINE: UINT = 0x20;
pub const DT_VCENTER: UINT = 0x4;
pub const DT_END_ELLIPSIS: UINT = 0x8000;
pub const DT_NOPREFIX: UINT = 0x800;
pub const TME_LEAVE: DWORD = 0x2;
pub const TME_NONCLIENT: DWORD = 0x10;
pub const MF_STRING: UINT = 0;
pub const MF_SEPARATOR: UINT = 0x800;
pub const TPM_RETURNCMD: UINT = 0x100;
pub const DI_NORMAL: UINT = 0x3;

pub const MINMAXINFO = extern struct {
    reserved: POINT,
    max_size: POINT,
    max_position: POINT,
    min_track_size: POINT,
    max_track_size: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

// ---------- Messages ----------

pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_NCDESTROY: UINT = 0x0082;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_NOTIFY: UINT = 0x004E;
pub const WM_SETFONT: UINT = 0x0030;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_DPICHANGED: UINT = 0x02E0;
/// Application-reserved wake message for the event loop.
pub const WM_GHOSTTY_WAKE: UINT = 0x8000; // WM_APP

// ---------- Window/class styles and misc constants ----------

pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const TCS_FIXEDWIDTH: DWORD = 0x0400;
pub const ICC_TAB_CLASSES: DWORD = 0x00000008;
pub const TCIF_TEXT: UINT = 0x0001;
pub const TCM_GETCURSEL: UINT = 0x130B;
pub const TCM_SETCURSEL: UINT = 0x130C;
pub const TCM_DELETEALLITEMS: UINT = 0x1309;
pub const TCM_SETITEMSIZE: UINT = 0x1329;
pub const TCM_INSERTITEMW: UINT = 0x133E;
pub const TCM_SETITEMW: UINT = 0x133D;
pub const TCN_SELCHANGE: UINT = @bitCast(@as(i32, -551));
pub const DEFAULT_GUI_FONT: c_int = 17;
pub const COLOR_BTNFACE: usize = 15;

pub const SW_SHOW: c_int = 5;
pub const SW_HIDE: c_int = 0;

pub const CW_USEDEFAULT: c_int = -2147483648; // 0x80000000

pub const GWLP_USERDATA: c_int = -21;

pub const PM_NOREMOVE: UINT = 0x0000;

/// SystemParametersInfo action: retrieve the work area (screen minus taskbar).
pub const SPI_GETWORKAREA: UINT = 0x0030;

/// Pre-defined DPI awareness value (DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
/// as passed to `SetProcessDpiAwarenessContext` (a pseudo HANDLE of -4).
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;

pub const WHEEL_DELTA: i32 = 120;

pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// ---------- Structures ----------

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD = @sizeOf(INITCOMMONCONTROLSEX),
    dwICC: DWORD = ICC_TAB_CLASSES,
};

pub const NMHDR = extern struct {
    hwndFrom: HWND,
    idFrom: usize,
    code: UINT,
};

pub const TCITEMW = extern struct {
    mask: UINT = TCIF_TEXT,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    pszText: ?[*:0]u16,
    cchTextMax: c_int = 0,
    iImage: c_int = 0,
    lParam: LPARAM = 0,
};

pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD = 0,
};

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?LPVOID,
    hInstance: HINSTANCE,
    hMenu: ?HMENU,
    hWndParent: ?HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: LONG,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: DWORD,
};

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

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: c_int,
    biHeight: c_int,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]DWORD = .{0},
};

pub const BI_RGB: DWORD = 0;
pub const DIB_RGB_COLORS: UINT = 0;
pub const SRCCOPY: DWORD = 0x00CC0020;

// ---------- Exported functions ----------

pub const exp = struct {
    // user32
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
    pub extern "comctl32" fn InitCommonControlsEx(init: *const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
    pub extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
    pub extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
    pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
    pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn DefWindowProcW(
        hWnd: HWND,
        Msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(.winapi) LRESULT;
    pub extern "user32" fn GetMessageW(
        lpMsg: *MSG,
        hWnd: ?HWND,
        wMsgFilterMin: UINT,
        wMsgFilterMax: UINT,
    ) callconv(.winapi) BOOL;
    pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
    pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
    pub extern "user32" fn PostMessageW(
        hWnd: ?HWND,
        Msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(.winapi) BOOL;
    /// Post a message to a specific thread's message queue. This is how
    /// worker threads (renderer, io) wake the main loop: `PostMessageW`
    /// with a null window posts to the /calling/ thread, which is not
    /// what we want across threads.
    pub extern "user32" fn PostThreadMessageW(
        idThread: DWORD,
        Msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(.winapi) BOOL;
    /// Non-destructive message peek. We use this once at startup to
    /// force creation of the calling thread's message queue so that
    /// `PostThreadMessageW` can target it reliably.
    pub extern "user32" fn PeekMessageW(
        lpMsg: *MSG,
        hWnd: ?HWND,
        wMsgFilterMin: UINT,
        wMsgFilterMax: UINT,
        wRemoveMsg: UINT,
    ) callconv(.winapi) BOOL;
    pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
    pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
    pub extern "user32" fn SetWindowPos(
        hWnd: HWND,
        hWndInsertAfter: ?HWND,
        X: c_int,
        Y: c_int,
        cx: c_int,
        cy: c_int,
        uFlags: UINT,
    ) callconv(.winapi) BOOL;
    pub extern "user32" fn ValidateRect(hWnd: HWND, lpRect: ?*const RECT) callconv(.winapi) BOOL;
    pub extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
    pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
    pub extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
    pub extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
    pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
    pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
    pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
    pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) LONG_PTR;
    pub extern "user32" fn IsWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn SystemParametersInfoW(
        uiAction: UINT,
        uiParam: UINT,
        pvParam: *anyopaque,
        fWinIni: UINT,
    ) callconv(.winapi) BOOL;
    pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
    pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
    pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?HANDLE;
    pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?HANDLE) callconv(.winapi) ?HANDLE;
    pub extern "user32" fn GetDpiForSystem() callconv(.winapi) UINT;
    pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
    /// Set the process DPI awareness. Passing a pseudo-handle value (e.g.
    /// -4 for PER_MONITOR_AWARE_V2) opts the process out of DPI
    /// virtualization, which is required for crisp rendering at the
    /// correct physical resolution.
    pub extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) BOOL;
    /// Legacy (Vista+) system-DPI-awareness opt-in, used as a fallback if
    /// the per-monitor API above is unavailable.
    pub extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
    pub extern "user32" fn GetKeyState(vKey: c_int) callconv(.winapi) i16;
    pub extern "user32" fn GetAsyncKeyState(vKey: c_int) callconv(.winapi) i16;
    pub extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.winapi) BOOL;
    pub extern "user32" fn ToUnicode(
        wVirtKey: UINT,
        wScanCode: UINT,
        lpKeyState: ?*const [256]u8,
        pwszBuff: [*]u16,
        cchBuff: c_int,
        wFlags: UINT,
    ) callconv(.winapi) c_int;

    // gdi32
    pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
    pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
    pub extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
    pub extern "user32" fn ScreenToClient(hwnd: HWND, point: *POINT) callconv(.winapi) BOOL;
    pub extern "user32" fn ClientToScreen(hwnd: HWND, point: *POINT) callconv(.winapi) BOOL;
    pub extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn TrackMouseEvent(event: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
    pub extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) c_int;
    pub extern "user32" fn DrawTextW(hdc: HDC, text: LPCWSTR, count: c_int, rect: *RECT, format: UINT) callconv(.winapi) c_int;
    pub extern "user32" fn DrawIconEx(hdc: HDC, x: c_int, y: c_int, icon: HICON, width: c_int, height: c_int, step: UINT, brush: ?HBRUSH, flags: UINT) callconv(.winapi) BOOL;
    pub extern "user32" fn DestroyIcon(icon: HICON) callconv(.winapi) BOOL;
    pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
    pub extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, id: usize, text: ?LPCWSTR) callconv(.winapi) BOOL;
    pub extern "user32" fn TrackPopupMenuEx(menu: HMENU, flags: UINT, x: c_int, y: c_int, hwnd: HWND, params: ?LPVOID) callconv(.winapi) UINT;
    pub extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetWindowsDirectoryW(buffer: [*]u16, size: UINT) callconv(.winapi) UINT;
    pub extern "shell32" fn ExtractIconExW(path: LPCWSTR, index: c_int, large: ?*?HICON, small: ?*?HICON, count: UINT) callconv(.winapi) UINT;
    pub extern "gdi32" fn CreateFontW(height: c_int, width: c_int, escapement: c_int, orientation: c_int, weight: c_int, italic: DWORD, underline: DWORD, strikeout: DWORD, charset: DWORD, precision: DWORD, clip_precision: DWORD, quality: DWORD, pitch: DWORD, face: LPCWSTR) callconv(.winapi) ?HANDLE;
    pub extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(.winapi) ?HBRUSH;
    pub extern "gdi32" fn CreatePen(style: c_int, width: c_int, color: DWORD) callconv(.winapi) ?HANDLE;
    pub extern "gdi32" fn SelectObject(hdc: HDC, object: HANDLE) callconv(.winapi) ?HANDLE;
    pub extern "gdi32" fn DeleteObject(object: HANDLE) callconv(.winapi) BOOL;
    pub extern "gdi32" fn SetTextColor(hdc: HDC, color: DWORD) callconv(.winapi) DWORD;
    pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
    pub extern "gdi32" fn RoundRect(hdc: HDC, left: c_int, top: c_int, right: c_int, bottom: c_int, ellipse_width: c_int, ellipse_height: c_int) callconv(.winapi) BOOL;
    pub extern "gdi32" fn MoveToEx(hdc: HDC, x: c_int, y: c_int, old: ?*POINT) callconv(.winapi) BOOL;
    pub extern "gdi32" fn LineTo(hdc: HDC, x: c_int, y: c_int) callconv(.winapi) BOOL;
    pub extern "gdi32" fn GetStockObject(index: c_int) callconv(.winapi) ?HANDLE;
    pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
    pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
    pub extern "gdi32" fn StretchDIBits(
        hdc: HDC,
        XDestDest: c_int,
        YDest: c_int,
        nDestWidth: c_int,
        nDestHeight: c_int,
        XSrc: c_int,
        YSrc: c_int,
        nSrcWidth: c_int,
        nSrcHeight: c_int,
        lpBits: [*]const u8,
        lpBitsInfo: *const BITMAPINFO,
        iUsage: UINT,
        dwRop: DWORD,
    ) callconv(.winapi) c_int;

    // kernel32
    pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
    pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?LPVOID;
    pub extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
};

pub const LONG_PTR = windows.LONG_PTR;
