"""Negative control for windows-startup.py: a GUI process delaying its first window.
Run via pythonw.exe and --force-on. The verifier must reject a multi-second
app-starting cursor; this fixture is not Ghostty and is not a performance test.
"""
import ctypes as C
from ctypes import wintypes as W
import time

u = C.WinDLL('user32', use_last_error=True)
k = C.WinDLL('kernel32', use_last_error=True)
proc_type = C.WINFUNCTYPE(W.LPARAM, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
u.DefWindowProcW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
u.DefWindowProcW.restype = W.LPARAM
u.DestroyWindow.argtypes = [W.HWND]
u.LoadCursorW.argtypes = [W.HINSTANCE, C.c_void_p]
u.LoadCursorW.restype = W.HANDLE
k.GetModuleHandleW.argtypes = [W.LPCWSTR]
k.GetModuleHandleW.restype = W.HINSTANCE

@proc_type
def wndproc(hwnd, msg, wp, lp):
    if msg == 0x10:
        u.DestroyWindow(hwnd)
        return 0
    if msg == 2:
        u.PostQuitMessage(0)
        return 0
    return u.DefWindowProcW(hwnd, msg, wp, lp)

class WindowClass(C.Structure):
    _fields_ = [('style', W.UINT), ('lpfnWndProc', proc_type), ('cbClsExtra', C.c_int),
                ('cbWndExtra', C.c_int), ('hInstance', W.HINSTANCE), ('hIcon', W.HICON),
                ('hCursor', W.HANDLE), ('hbrBackground', W.HBRUSH),
                ('lpszMenuName', W.LPCWSTR), ('lpszClassName', W.LPCWSTR)]
u.RegisterClassW.argtypes = [C.POINTER(WindowClass)]
u.CreateWindowExW.argtypes = [W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD,
                             C.c_int, C.c_int, C.c_int, C.c_int,
                             W.HWND, W.HMENU, W.HINSTANCE, C.c_void_p]
u.CreateWindowExW.restype = W.HWND
u.ShowWindow.argtypes = [W.HWND, C.c_int]
u.GetMessageW.argtypes = [C.POINTER(W.MSG), W.HWND, W.UINT, W.UINT]
u.DispatchMessageW.argtypes = [C.POINTER(W.MSG)]
u.DispatchMessageW.restype = W.LPARAM

# Deliberately do not create a GUI/message queue until after the delay.
time.sleep(4)
instance = k.GetModuleHandleW(None)
wc = WindowClass(lpfnWndProc=wndproc, hInstance=instance,
                 hCursor=u.LoadCursorW(None, C.c_void_p(32512)),
                 lpszClassName='GhosttyWindow')
assert u.RegisterClassW(C.byref(wc)), C.WinError(C.get_last_error())
h = u.CreateWindowExW(0, 'GhosttyWindow', 'Startup feedback negative control',
                       0x00CF0000, 100, 100, 400, 200, None, None, instance, None)
assert h, C.WinError(C.get_last_error())
u.ShowWindow(h, 1)
msg = W.MSG()
while u.GetMessageW(C.byref(msg), None, 0, 0) > 0:
    u.TranslateMessage(C.byref(msg))
    u.DispatchMessageW(C.byref(msg))
