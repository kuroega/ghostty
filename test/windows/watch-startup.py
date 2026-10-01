"""Read-only recorder for a user's normal Windows Ghostty launch.

python test/windows/watch-startup.py
While it records, launch Ghostty using the method that exhibited the spinner.
Does not launch/close applications, move the pointer, attach input queues,
change cursors, or capture screenshots/window contents. Cursor feedback is
system-wide: correlation with a new window is evidence, not proof of cause.
Unrecognized themed cursor handles are recorded, not treated as no animation.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import json
import os
from pathlib import Path
import time


class CursorInfo(C.Structure):
    _fields_ = [('cbSize', W.DWORD), ('flags', W.DWORD),
                ('hCursor', W.HANDLE), ('ptScreenPos', W.POINT)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--output', type=Path,
                        default=Path(os.environ['TEMP']) / 'ghostty-startup-capture.json')
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    u = C.WinDLL('user32', use_last_error=True)
    k = C.WinDLL('kernel32', use_last_error=True)
    u.GetCursorInfo.argtypes = [C.POINTER(CursorInfo)]
    u.LoadCursorW.argtypes = [W.HINSTANCE, C.c_void_p]
    u.LoadCursorW.restype = W.HANDLE
    u.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.IsWindowVisible.argtypes = [W.HWND]
    cbtype = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
    u.EnumWindows.argtypes = [cbtype, W.LPARAM]
    k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    k.OpenProcess.restype = W.HANDLE
    k.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
    k.CloseHandle.argtypes = [W.HANDLE]
    handles = {u.LoadCursorW(None, C.c_void_p(n)): name for n, name in
               [(32512, 'arrow'), (32513, 'ibeam'), (32514, 'wait'),
                (32515, 'cross'), (32516, 'up'), (32642, 'size_nwse'),
                (32643, 'size_nesw'), (32644, 'size_we'), (32645, 'size_ns'),
                (32646, 'size_all'), (32648, 'no'), (32649, 'hand'),
                (32650, 'appstarting'), (32651, 'help')]}

    def windows():
        found = {}
        @cbtype
        def visit(h, _):
            name = C.create_unicode_buffer(128)
            u.GetClassNameW(h, name, len(name))
            if name.value == 'GhosttyWindow' and u.IsWindowVisible(h):
                pid = W.DWORD()
                tid = u.GetWindowThreadProcessId(h, C.byref(pid))
                found[h] = (pid.value, tid)
            return True
        if not u.EnumWindows(visit, 0):
            raise C.WinError(C.get_last_error())
        return found

    def image(pid):
        process = k.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
        if not process:
            return None
        try:
            buf = C.create_unicode_buffer(32768)
            size = W.DWORD(len(buf))
            if k.QueryFullProcessImageNameW(process, 0, buf, C.byref(size)):
                return buf.value
            return None
        finally:
            k.CloseHandle(process)

    seen = windows()
    initial_count = len(seen)
    events = []
    last_cursor = None
    start = time.perf_counter()
    print(f'Recording for {args.seconds:g} seconds. Launch Ghostty normally now.', flush=True)
    try:
        while time.perf_counter() - start < args.seconds:
            elapsed = round(time.perf_counter() - start, 3)
            ci = CursorInfo(cbSize=C.sizeof(CursorInfo))
            if not u.GetCursorInfo(C.byref(ci)):
                raise C.WinError(C.get_last_error())
            state = (ci.flags, ci.hCursor)
            if state != last_cursor:
                events.append({'seconds': elapsed, 'event': 'cursor', 'flags': ci.flags,
                               'handle': ci.hCursor, 'name': handles.get(ci.hCursor, 'unknown')})
                last_cursor = state
            for h, (pid, tid) in windows().items():
                if seen.get(h) != (pid, tid):
                    events.append({'seconds': elapsed, 'event': 'new_ghostty_window',
                                   'hwnd': h, 'pid': pid, 'thread': tid, 'image': image(pid)})
                    seen[h] = (pid, tid)
            time.sleep(.01)
    except KeyboardInterrupt:
        pass
    finally:
        report = {'observed_seconds': round(time.perf_counter() - start, 3),
                  'initial_windows': initial_count,
                  'events': events,
                  'interpretation': 'Global cursor samples; unknown handles are inconclusive. No applications were controlled.'}
        args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
        print('Saved: ' + str(args.output), flush=True)


if __name__ == '__main__':
    main()
