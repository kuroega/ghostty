"""Measure Windows startup feedback cursor and time to a responsive window.
Run with the pointer stationary outside Ghostty; do not move the mouse during sampling.
python test/windows-startup.py --exe zig-out/bin/ghostty.exe
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import json
from pathlib import Path
import subprocess
import time

class CursorInfo(C.Structure):
    _fields_ = [("cbSize", W.DWORD), ("flags", W.DWORD),
                ("hCursor", W.HANDLE), ("ptScreenPos", W.POINT)]

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--exe', default='zig-out/bin/ghostty.exe')
p.add_argument('--seconds', type=float, default=7)
p.add_argument('--shell-launch', action='store_true', help='Launch through ShellExecuteEx, like the desktop shortcut')
p.add_argument('--require-cursors', action='store_true', help='Fail if host or terminal window class has no cursor')
p.add_argument('--max-busy-ms', type=float, help='Fail if any observed wait/appstarting interval exceeds this duration')
p.add_argument('--require-known-cursor', action='store_true', help='Fail instead of treating unidentified cursor handles as proof of no spinner')
p.add_argument('--force-off', action='store_true', help='Suppress feedback for the outer Ghostty launch only')
p.add_argument('--force-on', action='store_true', help='Request Explorer-style startup feedback')
p.add_argument('--pointer-away', action='store_true', help='Temporarily move pointer to the screen corner, then restore it')
p.add_argument('--pointer-center', action='store_true', help='Temporarily place pointer where the terminal will appear, then restore it')
p.add_argument('options', nargs='*')
a = p.parse_args()
u = C.WinDLL('user32', use_last_error=True)
u.GetCursorInfo.argtypes = [C.POINTER(CursorInfo)]
u.LoadCursorW.argtypes = [W.HINSTANCE, C.c_void_p]
u.LoadCursorW.restype = W.HANDLE
u.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
u.IsWindowVisible.argtypes = [W.HWND]
u.GetClassLongPtrW.argtypes = [W.HWND, C.c_int]
u.GetClassLongPtrW.restype = C.c_size_t
u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
u.SendMessageTimeoutW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM, W.UINT, W.UINT, C.POINTER(C.c_size_t)]
cbtype = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
u.EnumWindows.argtypes = [cbtype, W.LPARAM]
u.EnumChildWindows.argtypes = [W.HWND, cbtype, W.LPARAM]
handles = {u.LoadCursorW(None, C.c_void_p(n)): name for n, name in
           [(32512, 'arrow'), (32513, 'ibeam'), (32514, 'wait'),
            (32515, 'cross'), (32516, 'up'), (32642, 'size_nwse'),
            (32643, 'size_nesw'), (32644, 'size_we'), (32645, 'size_ns'),
            (32646, 'size_all'), (32648, 'no'), (32649, 'hand'),
            (32650, 'appstarting'), (32651, 'help')]}
si = subprocess.STARTUPINFO()
if a.force_off:
    si.dwFlags |= 0x80  # STARTF_FORCEOFFFEEDBACK
if a.force_on:
    si.dwFlags |= 0x40  # STARTF_FORCEONFEEDBACK
original = W.POINT()
u.GetCursorPos(C.byref(original))
if a.pointer_away:
    u.SetCursorPos(0, 0)
if a.pointer_center:
    u.SetCursorPos(u.GetSystemMetrics(0) // 2, u.GetSystemMetrics(1) // 2)
start = time.perf_counter()
if a.shell_launch:
    class ShellInfo(C.Structure):
        _fields_ = [('cbSize', W.DWORD), ('fMask', W.ULONG), ('hwnd', W.HWND),
                    ('lpVerb', W.LPCWSTR), ('lpFile', W.LPCWSTR), ('lpParameters', W.LPCWSTR),
                    ('lpDirectory', W.LPCWSTR), ('nShow', C.c_int), ('hInstApp', W.HINSTANCE),
                    ('lpIDList', C.c_void_p), ('lpClass', W.LPCWSTR), ('hkeyClass', W.HKEY),
                    ('dwHotKey', W.DWORD), ('hIcon', W.HANDLE), ('hProcess', W.HANDLE)]
    shell = C.WinDLL('shell32', use_last_error=True)
    kernel = C.WinDLL('kernel32', use_last_error=True)
    kernel.GetProcessId.argtypes = [W.HANDLE]
    kernel.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
    kernel.TerminateProcess.argtypes = [W.HANDLE, W.UINT]
    kernel.CloseHandle.argtypes = [W.HANDLE]
    shell.ShellExecuteExW.argtypes = [C.POINTER(ShellInfo)]
    info = ShellInfo(cbSize=C.sizeof(ShellInfo), fMask=0x40 | 0x100,
                     lpFile=str(Path(a.exe).resolve()),
                     lpParameters=subprocess.list2cmdline(a.options), nShow=1)
    if not shell.ShellExecuteExW(C.byref(info)):
        raise C.WinError(C.get_last_error())
    class ShellProcess:
        pid = kernel.GetProcessId(info.hProcess)
        def poll(self):
            return None if kernel.WaitForSingleObject(info.hProcess, 0) == 258 else 0
        def wait(self, timeout):
            if kernel.WaitForSingleObject(info.hProcess, int(timeout * 1000)) == 258:
                raise subprocess.TimeoutExpired(a.exe, timeout)
        def terminate(self):
            kernel.TerminateProcess(info.hProcess, 1)
    proc = ShellProcess()
else:
    proc = subprocess.Popen([str(Path(a.exe).resolve()), *a.options], startupinfo=si,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
host = None
visible = responsive = None
changes = []
last = None
@cbtype
def visit(h, _):
    global host
    pid = W.DWORD()
    u.GetWindowThreadProcessId(h, C.byref(pid))
    if pid.value == proc.pid:
        name = C.create_unicode_buffer(128)
        u.GetClassNameW(h, name, len(name))
        if name.value == 'GhosttyWindow' and u.IsWindowVisible(h):
            host = h
    return True
try:
    while time.perf_counter() - start < a.seconds:
        elapsed = time.perf_counter() - start
        ci = CursorInfo(cbSize=C.sizeof(CursorInfo))
        if not u.GetCursorInfo(C.byref(ci)):
            raise C.WinError(C.get_last_error())
        state = handles.get(ci.hCursor, 'other:' + str(ci.hCursor))
        if state != last:
            changes.append({'seconds': round(elapsed, 3), 'cursor': state})
            last = state
        if host is None:
            u.EnumWindows(visit, 0)
        if host and visible is None:
            visible = round(elapsed, 3)
        if host and responsive is None:
            result = C.c_size_t()
            if u.SendMessageTimeoutW(host, 0, 0, 0, 2, 20, C.byref(result)):
                responsive = round(time.perf_counter() - start, 3)
        if proc.poll() is not None:
            raise RuntimeError('Ghostty exited early: ' + str(proc.returncode))
        time.sleep(.01)
    cursors = {}
    if host:
        cursors['GhosttyWindow'] = u.GetClassLongPtrW(host, -12)  # GCLP_HCURSOR
        @cbtype
        def child(h, _):
            name = C.create_unicode_buffer(128)
            u.GetClassNameW(h, name, len(name))
            if name.value == 'GhosttySurface':
                cursors['GhosttySurface'] = u.GetClassLongPtrW(h, -12)
            return True
        u.EnumChildWindows(host, child, 0)
    observed_end = time.perf_counter() - start
    busy_intervals = []
    busy_start = None
    for change in changes:
        if change['cursor'] in ('wait', 'appstarting'):
            if busy_start is None:
                busy_start = change['seconds']
        elif busy_start is not None:
            busy_intervals.append((change['seconds'] - busy_start) * 1000)
            busy_start = None
    if busy_start is not None:
        busy_intervals.append((observed_end - busy_start) * 1000)
    max_busy_ms = round(max(busy_intervals, default=0), 1)
    print(json.dumps({'exe': a.exe, 'force_off_outer': a.force_off,
                      'options': a.options, 'visible_seconds': visible,
                      'responsive_seconds': responsive, 'class_cursors': cursors,
                      'cursor_changes': changes, 'max_busy_ms': max_busy_ms,
                      'observed_seconds': round(observed_end, 3)}, indent=2))
    assert responsive is not None, 'No responsive Ghostty window'
    if a.require_cursors:
        assert cursors.get('GhosttyWindow') and cursors.get('GhosttySurface'), cursors
    if a.require_known_cursor:
        assert not any(c['cursor'].startswith('other:') for c in changes), 'Unknown cursor: cannot verify animation absence'
    if a.max_busy_ms is not None:
        assert a.require_known_cursor, '--max-busy-ms requires --require-known-cursor'
        assert max_busy_ms <= a.max_busy_ms, f'Busy cursor persisted {max_busy_ms} ms'
finally:
    if a.pointer_away or a.pointer_center:
        u.SetCursorPos(original.x, original.y)
    if host:
        u.PostMessageW(host, 0x10, 0, 0)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.terminate()
        proc.wait(timeout=5)
    if a.shell_launch:
        kernel.CloseHandle(info.hProcess)
