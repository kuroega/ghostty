"""Native Windows Ghostty image regression tests: no preload or VT wrapper.

python test/windows-images.py --exe zig-out/bin/ghostty.exe
python test/windows-images.py --exe FIXED.exe --baseline-exe OLD.exe --session SESSION.jsonl --screenshot-dir TEMP_DIR

Uses the installed, unmodified Pi encoder/CLI. Opens only its own windows;
resume selection targets our own surface only. The original session is never modified.
"""
import argparse
import base64
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import time
import zlib


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def save_png(path, width, height, bgra):
    rows = b''.join(b'\0' + bytes(v for x in range(width) for v in
                                  (bgra[(y * width + x) * 4 + 2], bgra[(y * width + x) * 4 + 1], bgra[(y * width + x) * 4]))
                    for y in range(height))
    png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    png += png_chunk(b'IDAT', zlib.compress(rows)) + png_chunk(b'IEND', b'')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


class Windows:
    def __init__(self):
        self.u = C.WinDLL('user32', use_last_error=True)
        self.g = C.WinDLL('gdi32', use_last_error=True)
        u, g = self.u, self.g
        u.SetProcessDpiAwarenessContext.argtypes = [W.HANDLE]
        u.SetProcessDpiAwarenessContext(C.c_void_p(-4))
        self.callback = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
        u.EnumWindows.argtypes = [self.callback, W.LPARAM]
        u.EnumChildWindows.argtypes = [W.HWND, self.callback, W.LPARAM]
        u.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
        u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
        u.GetClientRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
        u.GetDC.argtypes = [W.HWND]; u.GetDC.restype = W.HDC
        u.ReleaseDC.argtypes = [W.HWND, W.HDC]
        u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
        u.SendMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
        u.SendMessageW.restype = C.c_ssize_t
        u.SetWindowPos.argtypes = [W.HWND, W.HWND, C.c_int, C.c_int, C.c_int, C.c_int, W.UINT]
        g.CreateCompatibleDC.argtypes = [W.HDC]; g.CreateCompatibleDC.restype = W.HDC
        g.CreateCompatibleBitmap.argtypes = [W.HDC, C.c_int, C.c_int]; g.CreateCompatibleBitmap.restype = W.HANDLE
        g.SelectObject.argtypes = [W.HDC, W.HANDLE]; g.SelectObject.restype = W.HANDLE
        g.GetDIBits.argtypes = [W.HDC, W.HANDLE, W.UINT, W.UINT, W.LPVOID, W.LPVOID, W.UINT]
        g.DeleteObject.argtypes = [W.HANDLE]; g.DeleteDC.argtypes = [W.HDC]
        g.BitBlt.argtypes = [W.HDC, C.c_int, C.c_int, C.c_int, C.c_int, W.HDC, C.c_int, C.c_int, W.DWORD]

    def find(self, pid, parent, name):
        found = []
        @self.callback
        def visit(handle, _):
            p = W.DWORD(); self.u.GetWindowThreadProcessId(handle, C.byref(p))
            n = C.create_unicode_buffer(256); self.u.GetClassNameW(handle, n, 256)
            if p.value == pid and n.value == name: found.append(handle)
            return True
        if parent: self.u.EnumChildWindows(parent, visit, 0)
        else: self.u.EnumWindows(visit, 0)
        return found[0] if found else None

    def capture(self, handle):
        u, g = self.u, self.g
        rect = W.RECT(); assert u.GetClientRect(handle, C.byref(rect))
        width, height = rect.right, rect.bottom
        screen = u.GetDC(handle); dc = g.CreateCompatibleDC(screen)
        bitmap = g.CreateCompatibleBitmap(screen, width, height)
        old = g.SelectObject(dc, bitmap)
        try:
            assert g.BitBlt(dc, 0, 0, width, height, screen, 0, 0, 0x00CC0020)
            g.SelectObject(dc, old)
            info = C.create_string_buffer(struct.pack('<IiiHHIIiiII', 40, width, -height, 1, 32, 0, width * height * 4, 0, 0, 0, 0))
            data = C.create_string_buffer(width * height * 4)
            assert g.GetDIBits(dc, bitmap, 0, height, data, info, 0) == height
            return width, height, data.raw
        finally:
            g.SelectObject(dc, old); g.DeleteObject(bitmap); g.DeleteDC(dc); u.ReleaseDC(handle, screen)


def red_points(frame):
    width, _, data = frame
    return [(i // 4 % width, i // 4 // width) for i in range(0, len(data), 4)
            if data[i + 2] > 220 and data[i] < 30 and data[i + 1] < 30]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', default='zig-out/bin/ghostty.exe')
    parser.add_argument('--baseline-exe', help='Optional stock-ConPTY build for negative control')
    parser.add_argument('--session', type=Path, help='Use a temporary copy of an image-containing session')
    parser.add_argument('--pi-mode', choices=['encoder', 'session', 'resume', 'plain'], help='Default: session when --session is supplied, otherwise encoder')
    parser.add_argument('--screenshot-dir', type=Path)
    args = parser.parse_args()
    if args.session and not args.baseline_exe:
        parser.error('--session requires --baseline-exe for an image/no-image comparison')
    mode = args.pi_mode or ('session' if args.session else 'encoder')
    if mode in ('session', 'resume') and not args.session:
        parser.error('session/resume modes require --session')
    windows = Windows()
    source_bytes = args.session.read_bytes() if args.session else None
    source_hash = hashlib.sha256(source_bytes).hexdigest() if source_bytes else None
    pi = Path(os.environ['APPDATA']) / 'npm/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/terminal-image.js'
    assert pi.is_file(), 'Global Pi TUI package not found'
    with tempfile.TemporaryDirectory(prefix='ghostty-native-images-') as temporary:
        temp = Path(temporary)
        rng = random.Random(123)
        pixels = b''.join(b'\0' + b'\xff\0\0' * 32 + rng.randbytes(32 * 3) for _ in range(64))
        png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0))
        png += png_chunk(b'IDAT', zlib.compress(pixels)) + png_chunk(b'IEND', b'')
        assert len(png) > 6144  # first/middle/final Pi graphics packets
        script = temp / 'probe.mjs'
        script.write_text('import {encodeKitty,deleteKittyImage} from ' + json.dumps(pi.as_uri()) + ';\n'
                          'const image=' + json.dumps(base64.b64encode(png).decode()) + ';\n'
                          'function draw(){process.stdout.write("\\x1b[2J\\x1b[HBEFORE\\r\\n\\x1b[3;5H"+encodeKitty(image,{columns:12,rows:6,imageId:321,moveCursor:false})+"\\x1b[12;1HAFTER");}\n'
                          'draw();process.stdout.on("resize",draw);\n'
                          'setTimeout(()=>process.stdout.write("\\x1b[2S"),4000);\n'
                          'setTimeout(()=>{process.stdout.removeListener("resize",draw);process.stdout.write(deleteKittyImage(321));},10000);\n'
                          'setTimeout(()=>{},30000);\n', encoding='utf-8')
        baseline_white = None
        runs = [('baseline', args.baseline_exe)] if args.baseline_exe else []
        runs.append(('native', args.exe))
        for label, exe in runs:
            if mode != 'encoder':
                sessions = temp / (label + '-sessions')
                sessions.mkdir()
                command = 'cmd.exe /d /c pi.cmd --offline --no-extensions --no-skills --no-context-files --no-approve --session-dir ' + str(sessions)
                if mode in ('session', 'resume'):
                    snapshot = sessions / args.session.name
                    snapshot.write_bytes(source_bytes)
                    command += ' --session ' + str(snapshot) if mode == 'session' else ' --resume'
            else:
                command = 'node ' + str(script)
            logfile = temp / (label + '.log')
            with logfile.open('wb') as log:
                working_directory = json.loads(source_bytes.splitlines()[0]).get('cwd', str(temp)) if source_bytes else str(temp)
                process = subprocess.Popen([str(Path(exe).resolve()), '--command=' + command,
                                            '--working-directory=' + working_directory,
                                            '--background=#ffffff', '--foreground=#242424'], stdout=log, stderr=log)
                host = None
                surface = None
                resume_selected = False
                started = time.monotonic()
                try:
                    def poll_capture():
                        nonlocal host, surface
                        if process.poll() is not None:
                            log.flush(); raise AssertionError(logfile.read_text(errors='replace'))
                        host = windows.find(process.pid, None, 'GhosttyWindow')
                        surface = windows.find(process.pid, host, 'GhosttySurface') if host else None
                        return windows.capture(surface) if surface else None
                    deadline = time.monotonic() + (15 if mode != 'encoder' else 5)
                    frame = None
                    points = []
                    while time.monotonic() < deadline:
                        frame = poll_capture()
                        if mode == 'resume' and surface and not resume_selected and time.monotonic() - started > 3:
                            # Select the only copied session in Pi's ordinary
                            # resume picker. Input targets our own surface only.
                            windows.u.SendMessageW(surface, 0x0100, 0x0D, 0x001C0001)
                            windows.u.SendMessageW(surface, 0x0101, 0x0D, 0xC01C0001)
                            resume_selected = True
                        if frame:
                            points = red_points(frame)
                            if mode in ('encoder', 'plain') and label == 'native' and len(points) > 400: break
                        time.sleep(.1)
                    assert frame is not None, 'No terminal surface'
                    if args.screenshot_dir:
                        save_png(args.screenshot_dir / (label + '.png'), *frame)
                    if mode in ('session', 'resume'):
                        data = frame[2]
                        white = sum(min(data[i:i+3]) > 240 for i in range(0, len(data), 4))
                        if label == 'baseline': baseline_white = white
                        else: assert baseline_white - white > 5000, 'No image difference from stock ConPTY'
                        print(f'PASS: ordinary pi --{mode}, {label}, white pixels={white}', flush=True)
                    elif mode == 'plain':
                        data = frame[2]
                        assert sum(min(data[i:i+3]) < 240 for i in range(0, len(data), 4)) > 1000, 'Pi interactive UI did not render'
                        print(f'PASS: ordinary pi interactive startup, {label} (no model prompt)', flush=True)
                    elif label == 'baseline':
                        assert len(points) == 0, 'Negative control unexpectedly supports Kitty images'
                        print('PASS: stock-ConPTY negative control has no image', flush=True)
                    else:
                        assert len(points) > 400, 'Native image missing'
                        assert min(x for x, _ in points) < frame[0] // 3, 'Image misplaced/clipped at right edge'
                        assert min(y for _, y in points) < frame[1] // 3, 'Image misplaced vertically'
                        initial_y = min(y for _, y in points)
                        assert windows.u.SetWindowPos(host, None, 0, 0, 1000, 700, 0x0016)
                        time.sleep(.5)
                        resized = poll_capture()
                        assert len(red_points(resized)) > 400, 'Image lost after native PTY resize'
                        if mode == 'encoder':
                            deadline = time.monotonic() + 6
                            while time.monotonic() < deadline:
                                scrolled = red_points(poll_capture())
                                if scrolled and min(y for _, y in scrolled) < initial_y - 10: break
                                time.sleep(.1)
                            else: raise AssertionError('Kitty placement did not track scrolling')
                            deadline = time.monotonic() + 12
                            while time.monotonic() < deadline:
                                deleted = poll_capture()
                                if deleted and not red_points(deleted): break
                                time.sleep(.1)
                            else: raise AssertionError('Kitty deletion did not remove image')
                            print('PASS: native Pi encoder, chunking, ordered placement, resize, scrolling, deletion', flush=True)
                finally:
                    if host: windows.u.PostMessageW(host, 0x0010, 0, 0)
                    try: process.wait(5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(); raise AssertionError('Ghostty shutdown hung')
    if args.session:
        assert hashlib.sha256(args.session.read_bytes()).hexdigest() == source_hash, 'Original session changed'
        print('PASS: original session unchanged', flush=True)


if __name__ == '__main__':
    main()
