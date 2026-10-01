"""Exercise the *native modal* resize loop without foreground input injection.

python test/windows-resize.py --exe zig-out/bin/ghostty.exe
The child floods OSC titles (more than the 64-entry app mailbox) while
SC_SIZE holds the UI inside DefWindowProc. Check delivery during the loop,
then repeated child resizes and responsiveness after exiting it.
"""
import argparse
import base64
import ctypes as C
from ctypes import wintypes as W
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', default='zig-out/bin/ghostty.exe')
    args = parser.parse_args()
    u = C.WinDLL('user32', use_last_error=True)
    callback = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
    u.EnumWindows.argtypes = [callback, W.LPARAM]
    u.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.GetWindowRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
    u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    u.SendMessageTimeoutW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM,
                                     W.UINT, W.UINT, C.POINTER(C.c_size_t)]
    u.SetWindowPos.argtypes = [W.HWND, W.HWND, C.c_int, C.c_int, C.c_int, C.c_int, W.UINT]

    class GUI(C.Structure):
        _fields_ = [('cbSize', W.DWORD), ('flags', W.DWORD),
                    ('active', W.HWND), ('focus', W.HWND), ('capture', W.HWND),
                    ('menu', W.HWND), ('move', W.HWND), ('caret', W.HWND),
                    ('rect', W.RECT)]
    u.GetGUIThreadInfo.argtypes = [W.DWORD, C.POINTER(GUI)]

    with tempfile.TemporaryDirectory(prefix='ghostty-resize-') as tmp:
        log_path = Path(os.environ['TEMP']) / 'ghostty-resize-test.log'
        with log_path.open('wb') as log:
            script = "Start-Sleep -Seconds 2; for($i=0;$i -lt 10000;$i++){[Console]::Write(([char]27)+']2;resize-'+$i+([char]7)); Start-Sleep -Milliseconds 10}"
            command = 'powershell.exe -NoLogo -NoProfile -EncodedCommand ' + base64.b64encode(script.encode('utf-16-le')).decode('ascii')
            process = subprocess.Popen([str(Path(args.exe).resolve()), '--command=' + command],
                                       stdout=log, stderr=log)
            host = None
            thread = W.DWORD()

            def title():
                text = C.create_unicode_buffer(512)
                u.GetWindowTextW(host, text, len(text))
                return text.value

            def modal():
                info = GUI(cbSize=C.sizeof(GUI))
                assert u.GetGUIThreadInfo(thread, C.byref(info))
                return bool(info.flags & 2)  # GUI_INMOVESIZE

            def wait(check, seconds=10):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    assert process.poll() is None, f'exit={process.returncode}; {log_path}'
                    if check():
                        return
                    time.sleep(.02)
                raise AssertionError(f'timed out; {log_path}')

            def find():
                nonlocal host
                @callback
                def visit(hwnd, _):
                    nonlocal host
                    pid = W.DWORD()
                    u.GetWindowThreadProcessId(hwnd, C.byref(pid))
                    name = C.create_unicode_buffer(256)
                    u.GetClassNameW(hwnd, name, len(name))
                    if pid.value == process.pid and name.value == 'GhosttyWindow':
                        host = hwnd
                    return True
                u.EnumWindows(visit, 0)
                return host is not None

            try:
                wait(find)
                thread.value = u.GetWindowThreadProcessId(host, None)
                wait(lambda: title().startswith('resize-'))
                for cycle in range(3):
                    assert u.PostMessageW(host, 0x0112, 0xF008, 0)  # SC_SIZE, bottom right
                    wait(modal)
                    before = title()
                    time.sleep(3)  # >64 OSC messages; outer GetMessage cannot run
                    after = title()
                    assert after.startswith('resize-') and int(after[7:]) - int(before[7:]) > 64, (
                        f'mailbox stalled in native resize: {before!r} -> {after!r}')
                    assert modal(), 'test must still be inside the native resize loop'
                    # Actual client geometry changes generate child WM_SIZE and
                    # drive core, renderer and ConPTY resize, not just chrome.
                    for i in range(80):
                        assert u.SetWindowPos(host, None, 0, 0, 850 + i % 20, 650 + i % 10, 0x4016)
                        time.sleep(.01)
                    def resized():
                        rect = W.RECT()
                        assert u.GetWindowRect(host, C.byref(rect))
                        return rect.right - rect.left == 869 and rect.bottom - rect.top == 659
                    wait(resized)
                    assert modal(), 'geometry changes must occur in the native resize loop'
                    result = C.c_size_t()
                    assert u.SendMessageTimeoutW(host, 0, 0, 0, 2, 2000, C.byref(result)), 'UI hung during resize'
                    assert u.PostMessageW(host, 0x0202, 0, 0)  # end native resize
                    wait(lambda: not modal())
                    assert u.SetWindowPos(host, None, 0, 0, 850 + cycle * 30, 650, 0x16)
                    previous = title()
                    wait(lambda: title() != previous)
                    print(f'cycle {cycle + 1}: native resize, mailbox progress, 80 resizes, exit responsive')
                assert u.PostMessageW(host, 0x0010, 0, 0)
                process.wait(timeout=10)
                assert process.returncode == 0
            finally:
                if host:
                    u.PostMessageW(host, 0x0202, 0, 0)
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
    print('PASS: native modal resize stays responsive')


if __name__ == '__main__':
    main()
