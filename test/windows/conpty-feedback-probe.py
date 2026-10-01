"""Isolate console-host startup feedback without launching a shell or Ghostty.

python test/windows/conpty-feedback-probe.py
--inbox uses Windows' own CreatePseudoConsole for comparison.
Never changes cursor state or moves the pointer. Creates a private pseudoconsole,
observes the global cursor for six seconds, then closes its own handles.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import json
from pathlib import Path
import time

class Coord(C.Structure):
    _fields_ = [('X', C.c_short), ('Y', C.c_short)]

class CursorInfo(C.Structure):
    _fields_ = [('cbSize', W.DWORD), ('flags', W.DWORD),
                ('hCursor', W.HANDLE), ('point', W.POINT)]

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--inbox', action='store_true')
p.add_argument('--seconds', type=float, default=6)
p.add_argument('--output', type=Path, help='Write JSON when running via pythonw.exe')
a = p.parse_args()
k = C.WinDLL('kernel32', use_last_error=True)
u = C.WinDLL('user32', use_last_error=True)
k.CreatePipe.argtypes = [C.POINTER(W.HANDLE), C.POINTER(W.HANDLE), C.c_void_p, W.DWORD]
k.CloseHandle.argtypes = [W.HANDLE]
u.GetCursorInfo.argtypes = [C.POINTER(CursorInfo)]
u.LoadCursorW.argtypes = [W.HINSTANCE, C.c_void_p]
u.LoadCursorW.restype = W.HANDLE
handles = {u.LoadCursorW(None, C.c_void_p(n)): name for n, name in
           [(32512, 'arrow'), (32514, 'wait'), (32650, 'appstarting')]}
if a.inbox:
    library = k
    create = k.CreatePseudoConsole
    close = k.ClosePseudoConsole
else:
    path = Path('zig-out/bin/conpty/conpty.dll').resolve()
    library = C.WinDLL(str(path), use_last_error=True, winmode=0x100 | 0x800)
    create = library.ConptyCreatePseudoConsole
    close = library.ConptyClosePseudoConsole
create.argtypes = [Coord, W.HANDLE, W.HANDLE, W.DWORD, C.POINTER(W.HANDLE)]
create.restype = C.c_long
close.argtypes = [W.HANDLE]
close.restype = None
pipes = []
hpc = W.HANDLE()
changes = []
last = None
start = time.perf_counter()
try:
    def pipe():
        r, w = W.HANDLE(), W.HANDLE()
        if not k.CreatePipe(C.byref(r), C.byref(w), None, 0):
            raise C.WinError(C.get_last_error())
        pipes.extend([r, w])
        return r, w
    ir, iw = pipe()
    or_, ow = pipe()
    hr = create(Coord(80, 24), ir, ow, 0, C.byref(hpc))
    if hr < 0:
        raise RuntimeError(f'CreatePseudoConsole failed HRESULT={hr & 0xffffffff:#x}')
    created = time.perf_counter() - start
    while time.perf_counter() - start < a.seconds:
        ci = CursorInfo(cbSize=C.sizeof(CursorInfo))
        if not u.GetCursorInfo(C.byref(ci)):
            raise C.WinError(C.get_last_error())
        state = handles.get(ci.hCursor, 'unknown:' + str(ci.hCursor))
        if state != last:
            changes.append({'seconds': round(time.perf_counter() - start, 3), 'cursor': state})
            last = state
        time.sleep(.01)
    result = json.dumps({'backend': 'inbox' if a.inbox else 'packaged',
                         'creation_seconds': round(created, 3),
                         'shell_launched': False, 'cursor_changes': changes}, indent=2)
    if a.output:
        a.output.write_text(result, encoding='utf-8')
    else:
        print(result)
finally:
    for h in pipes:
        k.CloseHandle(h)
    if hpc:
        close(hpc)
