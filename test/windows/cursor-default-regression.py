"""Isolate DefWindowProc cursor behavior for Ghostty's old/new class settings.

Runs on its own GUI thread with hidden windows. Seeds that thread's cursor
with IDC_APPSTARTING, sends WM_SETCURSOR for the client area, and checks
GetCursor. This is a controlled mechanism test, not a reproduction of the
user's original launch timing. Cursor state is restored before exit.
"""
import ctypes as C
from ctypes import wintypes as W
import json

u = C.WinDLL('user32', use_last_error=True)
k = C.WinDLL('kernel32', use_last_error=True)
proc_type = C.WINFUNCTYPE(W.LPARAM, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
u.DefWindowProcW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
u.DefWindowProcW.restype = W.LPARAM
u.DestroyWindow.argtypes = [W.HWND]
u.LoadCursorW.argtypes = [W.HINSTANCE, C.c_void_p]
u.LoadCursorW.restype = W.HANDLE
u.GetCursor.restype = W.HANDLE
u.SetCursor.argtypes = [W.HANDLE]
u.SetCursor.restype = W.HANDLE
u.SendMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
u.SendMessageW.restype = W.LPARAM
k.GetModuleHandleW.argtypes = [W.LPCWSTR]
k.GetModuleHandleW.restype = W.HINSTANCE

@proc_type
def wndproc(hwnd, msg, wp, lp):
    return u.DefWindowProcW(hwnd, msg, wp, lp)

class WindowClass(C.Structure):
    _fields_ = [('style', W.UINT), ('lpfnWndProc', proc_type), ('cbClsExtra', C.c_int),
                ('cbWndExtra', C.c_int), ('hInstance', W.HINSTANCE), ('hIcon', W.HICON),
                ('hCursor', W.HANDLE), ('hbrBackground', W.HBRUSH),
                ('lpszMenuName', W.LPCWSTR), ('lpszClassName', W.LPCWSTR)]
u.RegisterClassW.argtypes = [C.POINTER(WindowClass)]
u.UnregisterClassW.argtypes = [W.LPCWSTR, W.HINSTANCE]
u.CreateWindowExW.argtypes = [W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD,
                             C.c_int, C.c_int, C.c_int, C.c_int,
                             W.HWND, W.HMENU, W.HINSTANCE, C.c_void_p]
u.CreateWindowExW.restype = W.HWND

instance = k.GetModuleHandleW(None)
arrow = u.LoadCursorW(None, C.c_void_p(32512))
busy = u.LoadCursorW(None, C.c_void_p(32650))
original = u.GetCursor()
rows = []
try:
    for name, cursor in [('OldNullCursor', None), ('FixedArrowCursor', arrow)]:
        wc = WindowClass(lpfnWndProc=wndproc, hInstance=instance,
                         hCursor=cursor, lpszClassName=name)
        assert u.RegisterClassW(C.byref(wc)), C.WinError(C.get_last_error())
        parent = u.CreateWindowExW(0, name, '', 0x00CF0000,
                                   0, 0, 100, 100, None, None, instance, None)
        child = u.CreateWindowExW(0, name, '', 0x40000000,
                                  0, 0, 100, 100, parent, None, instance, None)
        assert parent and child, C.WinError(C.get_last_error())
        try:
            for kind, h in [('host', parent), ('terminal', child)]:
                u.SetCursor(busy)
                assert u.GetCursor() == busy, 'Unable to seed cursor state'
                u.SendMessageW(h, 0x20, h, 1 | (0x200 << 16))
                after = u.GetCursor()
                rows.append({'configuration': name, 'window': kind,
                             'retains_busy': after == busy, 'sets_arrow': after == arrow})
                expected = busy if cursor is None else arrow
                assert after == expected, (name, kind, after, expected)
        finally:
            u.DestroyWindow(child)
            u.DestroyWindow(parent)
            u.UnregisterClassW(name, instance)
finally:
    u.SetCursor(original)
print(json.dumps(rows, indent=2))
