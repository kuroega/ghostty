# Windows resize hang: diagnosis and verification

## Objective / completion audit

Find the cause of Ghostty's busy-cursor / not-responding behavior during
Windows resizing, fix it, and verify the executable used by the desktop shortcut.

| Requirement | Evidence |
| --- | --- |
| Inspect supplied screenshot | `C:\Users\WYX\AppData\Local\wnip\cache\wnip-20261001-100327.png` inspected; Windows reports `ghostty.exe` not responding. |
| Find resize-specific cause | `App.run` only drained the core mailbox after `DispatchMessageW` returned. `DefWindowProcW` enters a nested native loop for moving/resizing. `App.wakeup` used `PostThreadMessageW`, whose HWND-less messages are not dispatched to a window procedure in that loop. Consequently the bounded 64-entry app mailbox stops draining; producers eventually block, with further backpressure on resize/IO/render callbacks. `src/App.zig` defines that bounded queue; `src/termio/stream_handler.zig` has the blocking producer path. |
| Reproduce, not merely infer from code | `python test/windows-resize.py --exe zig-out/bin/ghostty.exe` on the original binary failed: `mailbox stalled in native resize: 'resize-1' -> 'resize-1'`. The test first verifies `GUI_INMOVESIZE` is set. The same title producer advances continuously outside this loop. Original binary SHA-256: `996da582c9e02737729f91b214cfe4f07b89f783867033f28b5223ad359c239f`. |
| Fix | `src/apprt/win32.zig` now creates an app-owned message-only HWND before starting workers, posts wake messages to that HWND, and drains the core mailbox in its window procedure. A guard prevents recursive core dispatch. Surface destruction remains outside window procedures; the wake HWND is destroyed only after surface teardown joins workers. |
| Verify resizing, not just a green build | `test/windows-resize.py` passed on staged and installed binaries: three actual native resize loops, each delivering over 64 title updates while modal, 80 actual geometry changes per loop, final geometry checked, responsiveness checked with `SendMessageTimeoutW`, title progress after exiting, and clean shutdown. No foreground keyboard/mouse injection. |
| Preserve window and rendering behavior | `python test/windows-tabs-ui.py --exe zig-out/bin/ghostty.exe` passed tab selection/creation/closing, dropdown routing, maximize/restore, independent windows and shutdown. `python test/windows-images.py --exe zig-out/bin/ghostty.exe` passed native Pi image encoding/chunking/placement, resize, scrolling and deletion. |
| Build / source gates | `zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast --prefix zig-out/windows-resize-fixed`, `zig build test -Dapp-runtime=win32 -Dtest-filter="win32 tabs"`, `zig fmt --check src/apprt/win32.zig`, and `git diff --check` passed. Compiler: `C:/Users/WYX/tools/zig-x86_64-windows-0.16.0/zig.exe`. |
| Deliver current executable | Desktop Ghostty shortcut targets `zig-out/bin/ghostty.exe`. That file was replaced with the tested build; installed/staged SHA-256 both `408d2729c9456a787febd236dfc8d322e36a653df32f3777ebe754c028e07bcb`. Original saved as `zig-out/bin/ghostty-before-resize-fix.exe`. Existing user process was not killed, so already-open windows still need restarting to use the fix. Config, shortcut and native ConPTY package were left unchanged. |

The regression deliberately exercises the native modal loop, rather than only
posting WM_SIZE in the ordinary outer loop. It does not reconstruct the exact
Pi session from the screenshot or claim all unrelated possible hangs are fixed.
The reproduced resize-loop starvation is fixed and covered by the regression.
