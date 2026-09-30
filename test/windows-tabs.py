"""Opt-in native Windows tab smoke test (Python 3, no extra dependencies).

Run: python test/windows-tabs.py --exe zig-out/windows-tabs/bin/ghostty.exe
Temporarily focuses its own test window for keyboard shortcuts. Never sends
input to other windows, restores the previous foreground window, and only
closes processes/windows it created. Logs go to the Windows temp directory.
"""
import argparse
import base64
import ctypes as C
from ctypes import wintypes as W
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", default="zig-out/bin/ghostty.exe")
    parser.add_argument("--screenshot", help="Optional header PNG (requires Pillow)")
    args = parser.parse_args()
    u = C.WinDLL("user32", use_last_error=True)
    u.SetProcessDpiAwarenessContext.argtypes = [W.HANDLE]
    u.SetProcessDpiAwarenessContext(C.c_void_p(-4))  # Match the app's physical coordinates.
    u.SendMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    u.SendMessageW.restype = W.LPARAM
    u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    u.SendMessageTimeoutW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM,
                                    W.UINT, W.UINT, C.POINTER(C.c_size_t)]
    u.SendMessageTimeoutW.restype = W.LPARAM
    u.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
    u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
    u.IsWindowVisible.argtypes = [W.HWND]
    u.SetForegroundWindow.argtypes = [W.HWND]
    u.GetDpiForWindow.argtypes = [W.HWND]
    u.GetDpiForWindow.restype = W.UINT
    u.GetClientRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
    u.GetWindowRect.argtypes = [W.HWND, C.POINTER(W.RECT)]
    u.GetForegroundWindow.restype = W.HWND
    u.AttachThreadInput.argtypes = [W.DWORD, W.DWORD, W.BOOL]
    u.PeekMessageW.argtypes = [C.POINTER(W.MSG), W.HWND, W.UINT, W.UINT, W.UINT]
    callback_type = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
    u.EnumWindows.argtypes = [callback_type, W.LPARAM]
    u.EnumChildWindows.argtypes = [W.HWND, callback_type, W.LPARAM]

    class Mouse(C.Structure):
        _fields_ = [("dx", W.LONG), ("dy", W.LONG), ("mouseData", W.DWORD),
                    ("dwFlags", W.DWORD), ("time", W.DWORD), ("extra", C.c_size_t)]

    class Keyboard(C.Structure):
        _fields_ = [("vk", W.WORD), ("scan", W.WORD), ("flags", W.DWORD),
                    ("time", W.DWORD), ("extra", C.c_size_t)]

    class Payload(C.Union):
        _fields_ = [("mouse", Mouse), ("key", Keyboard)]

    class Input(C.Structure):
        _fields_ = [("type", W.DWORD), ("payload", Payload)]

    u.SendInput.argtypes = [W.UINT, C.POINTER(Input), C.c_int]
    u.MapVirtualKeyW.argtypes = [W.UINT, W.UINT]
    previous = u.GetForegroundWindow()
    log_path = Path(os.environ["TEMP"]) / "ghostty-windows-tabs-test.log"
    log = log_path.open("wb")
    # Every shell has a distinct title, allowing checks of background titles,
    # preservation of sessions across switches, and reordering.
    script = "$host.UI.RawUI.WindowTitle='Tab '+$PID"
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    command = 'powershell.exe -NoLogo -NoProfile -NoExit -EncodedCommand ' + encoded
    # An installed application may register Ctrl+Shift+W globally. Use a
    # test-only binding to exercise the same close_tab action reliably.
    process = subprocess.Popen([str(Path(args.exe).resolve()), "--command=" + command,
                                "--window-show-tab-bar=always",
                                "--keybind=ctrl+shift+f4=close_tab:this",
                                "--keybind=ctrl+shift+f5=close_tab:other",
                                "--keybind=ctrl+shift+f6=close_tab:right"],
                               stdout=log, stderr=log)

    def wait(check, timeout=12):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if process.poll() is not None:
                raise AssertionError(f"Ghostty exited unexpectedly: {process.returncode}")
            value = check()
            if value:
                return value
            time.sleep(.05)
        raise AssertionError("Timed out waiting for tab state; see " + str(log_path))

    def enumerate_windows(parent=None):
        result = []

        @callback_type
        def visit(hwnd, _):
            pid = W.DWORD()
            u.GetWindowThreadProcessId(hwnd, C.byref(pid))
            if pid.value == process.pid:
                name = C.create_unicode_buffer(256)
                u.GetClassNameW(hwnd, name, len(name))
                result.append((hwnd, name.value))
            return True

        if parent:
            u.EnumChildWindows(parent, visit, 0)
        else:
            u.EnumWindows(visit, 0)
        return result

    def hosts():
        return [h for h, name in enumerate_windows() if name == "GhosttyWindow"]

    def surfaces(host):
        return [h for h, name in enumerate_windows(host) if name == "GhosttySurface"]

    def visible(host):
        return [h for h in surfaces(host) if u.IsWindowVisible(h)]

    def title(hwnd):
        text = C.create_unicode_buffer(512)
        u.GetWindowTextW(hwnd, text, len(text))
        return text.value

    pressed = set()

    def event(vk, release=False):
        # Abort rather than accidentally typing into a user's other window.
        assert release or u.GetForegroundWindow() in hosts(), (
            "Test window lost foreground focus; process=" + str(process.poll())
            + " hosts=" + str(hosts()))
        scan = u.MapVirtualKeyW(vk, 4)
        flags = 8 | (2 if release else 0) | (1 if scan >> 8 else 0)
        value = Input(type=1, payload=Payload(key=Keyboard(scan=scan & 255, flags=flags)))
        assert u.SendInput(1, C.byref(value), C.sizeof(value)) == 1
        if release:
            pressed.discard(vk)
        else:
            pressed.add(vk)

    class GuiInfo(C.Structure):
        _fields_ = [("size", W.DWORD), ("flags", W.DWORD), ("active", W.HWND),
                    ("focus", W.HWND), ("capture", W.HWND), ("menu", W.HWND),
                    ("move", W.HWND), ("caret", W.HWND), ("rect", W.RECT)]

    def focused(host):
        thread = u.GetWindowThreadProcessId(host, None)
        info = GuiInfo(size=C.sizeof(GuiInfo))
        assert u.GetGUIThreadInfo(thread, C.byref(info))
        return info.focus

    def focus_window(host):
        u.SetForegroundWindow(host)
        if u.GetForegroundWindow() != host:
            # Windows can restrict activation from a background test
            # process. Temporarily share its foreground input queue; do
            # not change system-wide focus policies or send keys elsewhere.
            message = W.MSG()
            u.PeekMessageW(C.byref(message), None, 0, 0, 0)
            current = C.WinDLL("kernel32").GetCurrentThreadId()
            foreground = u.GetWindowThreadProcessId(u.GetForegroundWindow(), None)
            target = u.GetWindowThreadProcessId(host, None)
            threads = []
            try:
                for thread in {foreground, target} - {current, 0}:
                    if u.AttachThreadInput(current, thread, True):
                        threads.append(thread)
                u.SetForegroundWindow(host)
            finally:
                for thread in threads:
                    u.AttachThreadInput(current, thread, False)
        wait(lambda: u.GetForegroundWindow() == host)

    def shortcut(host, modifiers, key):
        # HWND removal precedes potentially slower shell/renderer teardown.
        # Wait until the UI thread can process a new event before typing.
        result = C.c_size_t()
        assert u.SendMessageTimeoutW(host, 0, 0, 0, 2, 10000, C.byref(result))
        focus_window(host)
        time.sleep(.1)
        assert focused(host) in visible(host), (
            "Terminal lost keyboard focus: " + str(focused(host))
            + "; children=" + str(enumerate_windows(host)))
        for mod in modifiers:
            event(mod)
        time.sleep(.05)
        event(key)
        time.sleep(.15)
        event(key, True)
        for mod in reversed(modifiers):
            event(mod, True)
        time.sleep(.2)

    try:
        host = wait(lambda: hosts() and hosts()[0])
        wait(lambda: len(surfaces(host)) == 1 and title(host).startswith("Tab "))
        first = surfaces(host)[0]
        first_title = title(first)
        focus_window(host)
        time.sleep(.2)
        if args.screenshot:
            from PIL import ImageGrab
            rect = W.RECT()
            assert u.GetWindowRect(host, C.byref(rect))
            ImageGrab.grab(bbox=(rect.left, rect.top, rect.right,
                                rect.top + u.GetDpiForWindow(host) * 44 // 96),
                           all_screens=True).save(args.screenshot)

        shortcut(host, [0x11, 0x10], ord("T"))  # Ctrl+Shift+T
        wait(lambda: len(surfaces(host)) == 2 and len(visible(host)) == 1)
        second = visible(host)[0]
        assert second != first
        wait(lambda: title(second).startswith("Tab "))

        print("PASS: Ctrl+Shift+T creates a second tab", flush=True)

        def header_geometry():
            dpi = u.GetDpiForWindow(host)
            scale = lambda n: n * dpi // 96
            rect = W.RECT()
            assert u.GetClientRect(host, C.byref(rect))
            available = max(rect.right - scale(138) - scale(10) - scale(64) - scale(8), 1)
            width = min(max(available // len(surfaces(host)), scale(96)), scale(240))
            return scale, width

        def click(x, y):
            point = x | (y << 16)
            assert u.PostMessageW(host, 0x0201, 1, point)
            assert u.PostMessageW(host, 0x0202, 0, point)

        def click_tab(index):
            scale, width = header_geometry()
            click(scale(10) + index * width + width // 2, scale(24))

        click_tab(0)
        wait(lambda: visible(host) == [first])
        click_tab(1)
        wait(lambda: visible(host) == [second])
        shortcut(host, [0x11], 0x09)  # Ctrl+Tab wraps to first
        wait(lambda: visible(host) == [first])
        assert title(host) == first_title
        shortcut(host, [0x11, 0x10], 0x09)  # Ctrl+Shift+Tab wraps back
        wait(lambda: visible(host) == [second])
        shortcut(host, [0x12], ord("1"))  # Alt+1
        wait(lambda: visible(host) == [first])

        # Native '+' button creates another independent shell.
        scale, width = header_geometry()
        click(scale(10) + len(surfaces(host)) * width + scale(6 + 16), scale(24))
        wait(lambda: len(surfaces(host)) == 3 and len(visible(host)) == 1
             and visible(host)[0] not in (first, second))
        third = visible(host)[0]
        wait(lambda: title(third).startswith("Tab "))
        shortcut(host, [0x11, 0x10], 0x21)  # Ctrl+Shift+PageUp: move left
        shortcut(host, [0x12], ord("2"))
        wait(lambda: visible(host) == [third])
        shortcut(host, [0x12], ord("9"))  # default Alt+9 selects last
        wait(lambda: visible(host) == [second])

        print("PASS: tab switching, native + button, and reordering", flush=True)
        # Close inactive/active tabs without losing surviving sessions.
        assert u.PostMessageW(first, 0x0010, 0, 0)
        wait(lambda: len(surfaces(host)) == 2)
        wait(lambda: visible(host) == [second])
        shortcut(host, [0x11, 0x10], 0x73)  # test-only Ctrl+Shift+F4
        wait(lambda: len(surfaces(host)) == 1 and visible(host) == [third])

        print("PASS: closing inactive/active tabs preserves surviving sessions", flush=True)

        def new_tab():
            existing = surfaces(host)
            assert u.PostMessageW(host, 0x0111, 1001, 0)
            wait(lambda: len(surfaces(host)) == len(existing) + 1
                 and len(visible(host)) == 1 and visible(host)[0] not in existing)
            child = visible(host)[0]
            wait(lambda: title(child).startswith("Tab "))
            return child

        new_tab()
        new_tab()
        shortcut(host, [0x12], ord("1"))
        shortcut(host, [0x11, 0x10], 0x74)  # close other tabs
        wait(lambda: len(surfaces(host)) == 1 and visible(host) == [third])
        fourth = new_tab()
        new_tab()
        shortcut(host, [0x12], ord("2"))
        shortcut(host, [0x11, 0x10], 0x75)  # close tabs to the right
        wait(lambda: len(surfaces(host)) == 2 and visible(host) == [fourth])
        scale, width = header_geometry()
        click(scale(10) + width * 2 - scale(20), scale(24))  # tab's own close button
        wait(lambda: len(surfaces(host)) == 1 and visible(host) == [third])
        print("PASS: close-other, close-right, and native close button", flush=True)

        # Multiple top-level windows must remain independent.
        shortcut(host, [0x11, 0x10], ord("N"))
        wait(lambda: len(hosts()) == 2)
        other = next(h for h in hosts() if h != host)
        wait(lambda: len(surfaces(other)) == 1)
        assert u.PostMessageW(host, 0x0010, 0, 0)
        wait(lambda: len(hosts()) == 1 and hosts()[0] == other)
        # Closing the last tab closes only its window and exits cleanly.
        assert u.PostMessageW(other, 0x0111, 1002, 0)
        process.wait(timeout=15)
        assert process.returncode == 0, process.returncode
        print("PASS: native buttons, keyboard creation/switching/reordering/closing,")
        print("      independent sessions, per-tab close buttons, multiple windows, clean exit")
        print("Log:", log_path)
    finally:
        # Release only keys injected by this test, even after an assertion.
        for vk in pressed:
            value = Input(type=1, payload=Payload(key=Keyboard(vk=vk, flags=2)))
            u.SendInput(1, C.byref(value), C.sizeof(value))
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        if previous:
            u.SetForegroundWindow(previous)
        log.close()


if __name__ == "__main__":
    main()
