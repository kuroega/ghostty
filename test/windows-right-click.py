"""Native drag/right-click clipboard regression (Windows, Python 3).

Run: python test/windows-right-click.py --exe zig-out/bin/ghostty.exe
Uses only messages to its own window; temporarily replaces the clipboard.
Restores Unicode text, but not other clipboard formats. Run with no valuable
non-text clipboard contents. --action tests an explicit configuration override.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', default='zig-out/bin/ghostty.exe')
    parser.add_argument('--action', choices=['copy', 'copy-or-paste', 'ignore'])
    args = parser.parse_args()
    u = C.WinDLL('user32', use_last_error=True)
    k = C.WinDLL('kernel32', use_last_error=True)
    u.SetProcessDpiAwarenessContext.argtypes = [W.HANDLE]
    u.SetProcessDpiAwarenessContext(C.c_void_p(-4))
    u.SendMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    u.SendMessageW.restype = W.LPARAM
    u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    u.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.GetClientRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
    callback = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
    u.EnumWindows.argtypes = [callback, W.LPARAM]
    u.EnumChildWindows.argtypes = [W.HWND, callback, W.LPARAM]
    u.OpenClipboard.argtypes = [W.HWND]
    u.GetClipboardData.argtypes = [W.UINT]
    u.GetClipboardData.restype = W.HANDLE
    u.SetClipboardData.argtypes = [W.UINT, W.HANDLE]
    u.SetClipboardData.restype = W.HANDLE
    k.GlobalAlloc.argtypes = [W.UINT, C.c_size_t]
    k.GlobalAlloc.restype = W.HANDLE
    k.GlobalLock.argtypes = [W.HANDLE]
    k.GlobalLock.restype = C.c_void_p
    k.GlobalUnlock.argtypes = [W.HANDLE]
    k.GlobalFree.argtypes = [W.HANDLE]

    def open_clipboard():
        for _ in range(100):
            if u.OpenClipboard(None):
                return
            time.sleep(.02)
        raise AssertionError('Clipboard busy')

    def clipboard_read():
        open_clipboard()
        try:
            handle = u.GetClipboardData(13)
            if not handle:
                return None
            ptr = k.GlobalLock(handle)
            assert ptr
            try:
                return C.wstring_at(ptr)
            finally:
                k.GlobalUnlock(handle)
        finally:
            u.CloseClipboard()

    def clipboard_write(text):
        open_clipboard()
        try:
            assert u.EmptyClipboard()
            if text is None:
                return
            data = (text + '\0').encode('utf-16-le')
            handle = k.GlobalAlloc(2, len(data))
            assert handle
            ptr = k.GlobalLock(handle)
            assert ptr
            C.memmove(ptr, data, len(data))
            k.GlobalUnlock(handle)
            if not u.SetClipboardData(13, handle):
                k.GlobalFree(handle)
                raise AssertionError('SetClipboardData failed')
        finally:
            u.CloseClipboard()

    previous = clipboard_read()
    marker = 'GhosttyDragCopy_12345_中文_é'
    sentinel = 'clipboard-not-copied'
    process = None
    host = None
    with tempfile.TemporaryDirectory(prefix='ghostty-right-click-') as tmp:
        tmp = Path(tmp)
        fixture = tmp / 'fixture.py'
        result = tmp / 'paste.txt'
        fixture.write_text(
            'import pathlib, sys, time\n'
            f'print("\\x1b[2J\\x1b[H{marker}", flush=True)\n'
            f'pathlib.Path({str(result)!r}).write_text(input(), encoding="utf-8")\n'
            'time.sleep(60)\n', encoding='utf-8')
        command = subprocess.list2cmdline([sys.executable, '-u', str(fixture)])
        argv = [str(Path(args.exe).resolve()), '--config-default-files=false',
                '--command=' + command, '--font-size=16', '--window-padding-x=0',
                '--window-padding-y=0', '--copy-on-select=none']
        if args.action:
            argv.append('--right-click-action=' + args.action)
        log_path = Path(os.environ['TEMP']) / 'ghostty-right-click-test.log'
        with log_path.open('wb') as log:
            try:
                process = subprocess.Popen(argv, stdout=log, stderr=log)

                def find(parent, name):
                    found = []

                    @callback
                    def visit(hwnd, _):
                        pid = W.DWORD()
                        u.GetWindowThreadProcessId(hwnd, C.byref(pid))
                        text = C.create_unicode_buffer(256)
                        u.GetClassNameW(hwnd, text, len(text))
                        if pid.value == process.pid and text.value == name:
                            found.append(hwnd)
                        return True

                    if parent:
                        u.EnumChildWindows(parent, visit, 0)
                    else:
                        u.EnumWindows(visit, 0)
                    return found[0] if found else None

                def wait(check):
                    end = time.monotonic() + 12
                    while time.monotonic() < end:
                        assert process.poll() is None, f'App exited; see {log_path}'
                        value = check()
                        if value:
                            return value
                        time.sleep(.05)
                    raise AssertionError(f'Timed out; see {log_path}')

                host = wait(lambda: find(None, 'GhosttyWindow'))
                surface = wait(lambda: find(host, 'GhosttySurface'))
                time.sleep(2)
                rect = W.RECT()
                assert u.GetClientRect(surface, C.byref(rect))
                # Select the first rendered line, including trailing blank cells.
                # Copy trims trailing blanks. Messages are in physical client pixels.
                def mouse(message, x, y, buttons=0):
                    u.SendMessageW(surface, message, buttons, (y << 16) | x)

                clipboard_write(sentinel)
                mouse(0x200, 1, 5)
                mouse(0x201, 1, 5, 1)
                for x in range(10, rect.right - 10, 10):
                    mouse(0x200, x, 5, 1)
                mouse(0x202, rect.right - 11, 5)
                assert clipboard_read() == sentinel, 'Selection unexpectedly auto-copied'
                mouse(0x204, rect.right - 11, 5, 2)
                mouse(0x205, rect.right - 11, 5)
                if args.action == 'ignore':
                    assert clipboard_read() == sentinel, 'ignore override did not win'
                    print('PASS: explicit ignore leaves clipboard unchanged')
                else:
                    wait(lambda: clipboard_read() == marker)
                    print('PASS: left-drag then right-click copies exact selected text')
                    if args.action != 'copy':
                        # Copy clears selection. The next right-click must paste,
                        # and Enter commits it to the fixture's stdin for verification.
                        mouse(0x204, rect.right - 11, 5, 2)
                        mouse(0x205, rect.right - 11, 5)
                        u.SendMessageW(surface, 0x100, 13, 0x001C0001)
                        u.SendMessageW(surface, 0x101, 13, 0xC01C0001)
                        wait(lambda: result.exists() and result.read_text(encoding='utf-8') == marker)
                        print('PASS: right-click without selection pastes once')
            finally:
                if process:
                    if host:
                        u.PostMessageW(host, 0x10, 0, 0)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                clipboard_write(previous)


if __name__ == '__main__':
    main()
