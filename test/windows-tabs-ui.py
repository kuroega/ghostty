"""Background Win32 tab/chrome smoke test; never injects keyboard input.

python test/windows-tabs-ui.py --exe zig-out/bin/ghostty.exe --screenshot preview.png
The optional screenshot uses WM_PRINTCLIENT, not the foreground desktop.
"""
import argparse
import base64
import ctypes as C
from ctypes import wintypes as W
import os
from pathlib import Path
import struct
import subprocess
import time
import zlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", default="zig-out/bin/ghostty.exe")
    parser.add_argument("--screenshot")
    args = parser.parse_args()
    u = C.WinDLL("user32", use_last_error=True)
    g = C.WinDLL("gdi32", use_last_error=True)
    u.SetProcessDpiAwarenessContext.argtypes = [W.HANDLE]
    u.SetProcessDpiAwarenessContext(C.c_void_p(-4))
    u.SendMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    u.SendMessageW.restype = W.LPARAM
    u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    u.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.GetClientRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
    u.GetWindowRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
    u.ClientToScreen.argtypes = [W.HWND, C.POINTER(W.POINT)]
    u.GetDpiForWindow.argtypes = [W.HWND]
    u.IsWindowVisible.argtypes = [W.HWND]
    u.IsZoomed.argtypes = [W.HWND]
    callback_type = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
    u.EnumWindows.argtypes = [callback_type, W.LPARAM]
    u.EnumChildWindows.argtypes = [W.HWND, callback_type, W.LPARAM]

    log_path = Path(os.environ["TEMP"]) / "ghostty-tabs-ui-test.log"
    script = "$host.UI.RawUI.WindowTitle='Windows PowerShell'"
    command = ('powershell.exe -NoLogo -NoProfile -NoExit -EncodedCommand '
               + base64.b64encode(script.encode("utf-16-le")).decode("ascii"))
    log = log_path.open("wb")
    process = subprocess.Popen([str(Path(args.exe).resolve()), "--command=" + command,
                                "--window-show-tab-bar=always"], stdout=log, stderr=log)

    def wait(check, timeout=15):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            assert process.poll() is None, f"Unexpected exit: {process.returncode}; {log_path}"
            value = check()
            if value:
                return value
            time.sleep(.05)
        raise AssertionError("Timed out waiting for UI; log: " + str(log_path))

    def windows(parent=None, wanted=None):
        result = []

        @callback_type
        def visit(hwnd, _):
            pid = W.DWORD()
            u.GetWindowThreadProcessId(hwnd, C.byref(pid))
            if pid.value == process.pid:
                name = C.create_unicode_buffer(256)
                u.GetClassNameW(hwnd, name, len(name))
                if wanted is None or name.value == wanted:
                    result.append(hwnd)
            return True

        if parent:
            u.EnumChildWindows(parent, visit, 0)
        else:
            u.EnumWindows(visit, 0)
        return result

    def hosts():
        return windows(wanted="GhosttyWindow")

    def surfaces():
        return windows(host, "GhosttySurface")

    def visible():
        return [h for h in surfaces() if u.IsWindowVisible(h)]

    def title(hwnd):
        value = C.create_unicode_buffer(512)
        u.GetWindowTextW(hwnd, value, len(value))
        return value.value

    def geometry():
        dpi = u.GetDpiForWindow(host)
        scale = lambda n: n * dpi // 96
        rect = W.RECT()
        assert u.GetClientRect(host, C.byref(rect))
        available = max(rect.right - scale(138) - scale(10) - scale(64) - scale(8), 1)
        width = min(max(available // len(surfaces()), scale(96)), scale(240))
        return scale, width, rect.right

    def click(x, y):
        point = (x & 65535) | ((y & 65535) << 16)
        assert u.PostMessageW(host, 0x0201, 1, point)
        assert u.PostMessageW(host, 0x0202, 0, point)

    def select(index):
        scale, width, _ = geometry()
        click(scale(10) + index * width + width // 2, scale(24))

    def close_tab(index):
        scale, width, _ = geometry()
        click(scale(10) + (index + 1) * width - scale(20), scale(24))

    def new_tab():
        previous = surfaces()
        scale, width, _ = geometry()
        click(scale(10) + len(previous) * width + scale(22), scale(24))
        wait(lambda: len(surfaces()) == len(previous) + 1 and len(visible()) == 1
             and visible()[0] not in previous)
        child = visible()[0]
        wait(lambda: title(child) == "Windows PowerShell")
        return child

    def capture_header(path):
        u.GetDC.argtypes = [W.HWND]
        u.GetDC.restype = W.HDC
        u.ReleaseDC.argtypes = [W.HWND, W.HDC]
        u.PrintWindow.argtypes = [W.HWND, W.HDC, W.UINT]
        g.CreateCompatibleDC.argtypes = [W.HDC]
        g.CreateCompatibleDC.restype = W.HDC
        g.CreateCompatibleBitmap.argtypes = [W.HDC, C.c_int, C.c_int]
        g.CreateCompatibleBitmap.restype = W.HANDLE
        g.SelectObject.argtypes = [W.HDC, W.HANDLE]
        g.SelectObject.restype = W.HANDLE
        g.DeleteObject.argtypes = [W.HANDLE]
        g.DeleteDC.argtypes = [W.HDC]
        g.GetDIBits.argtypes = [W.HDC, W.HANDLE, W.UINT, W.UINT, W.LPVOID, W.LPVOID, W.UINT]
        rect = W.RECT()
        u.GetClientRect(host, C.byref(rect))
        width, height = rect.right, u.GetDpiForWindow(host) * 40 // 96
        screen = u.GetDC(host)
        dc = g.CreateCompatibleDC(screen)
        bitmap = g.CreateCompatibleBitmap(screen, width, height)
        assert screen and dc and bitmap
        old = g.SelectObject(dc, bitmap)
        try:
            assert u.PrintWindow(host, dc, 1)
            g.SelectObject(dc, old)
            info = C.create_string_buffer(struct.pack("<IiiHHIIiiII", 40, width, -height,
                                                       1, 32, 0, width * height * 4, 0, 0, 0, 0))
            data = C.create_string_buffer(width * height * 4)
            assert g.GetDIBits(dc, bitmap, 0, height, data, info, 0) == height
            raw = data.raw
            rows = bytearray()
            for y in range(height):
                src = raw[y * width * 4:(y + 1) * width * 4]
                row = bytearray(width * 3)
                row[0::3], row[1::3], row[2::3] = src[2::4], src[1::4], src[0::4]
                rows.extend(b"\0" + row)

            def chunk(kind, payload):
                return (struct.pack(">I", len(payload)) + kind + payload
                        + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))

            png = (b"\x89PNG\r\n\x1a\n"
                   + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
            Path(path).write_bytes(png)
        finally:
            g.SelectObject(dc, old)
            g.DeleteObject(bitmap)
            g.DeleteDC(dc)
            u.ReleaseDC(host, screen)

    try:
        host = wait(lambda: hosts() and hosts()[0])
        wait(lambda: len(surfaces()) == 1 and title(host) == "Windows PowerShell")
        first = surfaces()[0]
        if args.screenshot:
            capture_header(args.screenshot)
        second = new_tab()
        third = new_tab()
        select(0)
        wait(lambda: visible() == [first])
        select(1)
        wait(lambda: visible() == [second])
        close_tab(0)  # close an inactive tab
        wait(lambda: len(surfaces()) == 2 and visible() == [second])
        close_tab(0)  # close the active tab
        wait(lambda: len(surfaces()) == 1 and visible() == [third])
        print("PASS: styled tab selection, + button, active/inactive per-tab close", flush=True)

        new_tab()
        new_tab()
        select(0)
        wait(lambda: visible() == [third])
        assert u.PostMessageW(host, 0x0111, 1004, 0)  # dropdown close-other command
        wait(lambda: len(surfaces()) == 1 and visible() == [third])
        fourth = new_tab()
        new_tab()
        select(1)
        wait(lambda: visible() == [fourth])
        assert u.PostMessageW(host, 0x0111, 1005, 0)
        wait(lambda: len(surfaces()) == 2 and visible() == [fourth])
        close_tab(1)
        wait(lambda: len(surfaces()) == 1 and visible() == [third])
        print("PASS: dropdown command routing, close-other and close-right", flush=True)

        scale, _, width = geometry()
        for button, expected in ((0, 8), (1, 9), (2, 20)):
            point = W.POINT(width - scale(138) + scale(46) * button + scale(23), scale(20))
            u.ClientToScreen(host, C.byref(point))
            packed = (point.x & 65535) | ((point.y & 65535) << 16)
            assert u.SendMessageW(host, 0x0084, 0, packed) == expected
        def caption_button(button, hit):
            scale, _, width = geometry()
            x, y = width - scale(138) + scale(46) * button + scale(23), scale(20)
            point = W.POINT(x, y)
            u.ClientToScreen(host, C.byref(point))
            assert u.PostMessageW(host, 0x00A1, hit, (point.x & 65535) | ((point.y & 65535) << 16))
            assert u.PostMessageW(host, 0x0202, 0, x | (y << 16))

        caption_button(1, 9)
        wait(lambda: u.IsZoomed(host))
        caption_button(1, 9)
        wait(lambda: not u.IsZoomed(host))
        print("PASS: native caption hit testing, maximize and restore", flush=True)

        assert u.PostMessageW(host, 0x0111, 1003, 0)
        wait(lambda: len(hosts()) == 2)
        other = next(h for h in hosts() if h != host)
        wait(lambda: len(windows(other, "GhosttySurface")) == 1)
        assert u.PostMessageW(host, 0x0010, 0, 0)
        wait(lambda: len(hosts()) == 1 and hosts()[0] == other)
        assert u.PostMessageW(other, 0x0010, 0, 0)
        process.wait(timeout=15)
        assert process.returncode == 0, process.returncode
        print("PASS: independent windows and clean shutdown", flush=True)
        print("Log:", log_path)
    finally:
        if process.poll() is None:
            for hwnd in hosts():
                u.PostMessageW(hwnd, 0x0010, 0, 0)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
        log.close()


if __name__ == "__main__":
    main()
