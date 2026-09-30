# Native Windows Pi image support

**Implemented and verified with the official side-by-side Microsoft ConPTY
backend.** Stock ConPTY on the tested Windows build discarded Kitty APC;
the pinned packaged backend preserves original VT bytes and their order
while keeping native console/TTY APIs. Pi itself is unchanged.

## Correction to the initial feasibility checkpoint

The initial stock-ConPTY probe correctly measured 0/5 graphics commands for
flags `0`, `0x08`, `0x10`, `0x18`, and `0x20`. However, inspecting the parser's
APC-ignore state alone did not establish that every newer console backend
would discard its output. The newer
[`WriteCharsVT` output path](https://github.com/microsoft/terminal/blob/main/src/host/_stream.cpp)
forwards original input around parser injections. The parser can ignore APC
for its internal screen model while the output writer still passes it on.

After external native backend scope was authorized, the released Microsoft
package was tested directly instead of assuming a custom fork was necessary.
It passed. No Microsoft source fork, DLL injection into other processes,
JavaScript compatibility envelope, or special Pi launcher is used.

## Build and distribution

See [the pinned native dependency](../../vendor/conpty/README.md) for its
version, SHA-256 verification, MIT license, offline preparation, and bundle
layout. Build-time Python/curl do not participate in terminal runtime.

```text
zig build fetch-conpty -Dapp-runtime=win32
zig build -Dapp-runtime=win32
```

The API loader is `src/os/conpty.zig`; `src/pty.zig` owns its module lifetime
and uses the packaged create/resize/close functions. The PTY reader feeds
ordinary VT directly into Ghostty. Missing OpenConsole fails rather than
silently reverting to stock conhost. Keep the installed `bin/conpty/`
directory with the executable.

The old private OSC decoder, Node preload, compatibility launcher, and
workaround-only tests have been removed. No installed npm package, global
Windows environment, or original Pi session is changed by the implementation.
Existing Windows-port, parser, and renderer changes were preserved.

## Pure Zig transport, ordering, and input probe

```text
zig build-exe test/windows/conpty-images.zig -O ReleaseSafe
conpty-images.exe 0
conpty-images.exe 0 C:\absolute\path\to\bin\conpty\conpty.dll
```

The probe launches itself attached to a real console, opens `CONOUT$` and
`CONIN$`, verifies console mode, and writes transmit/display, two chunks,
query, and deletion inside synchronized output. It checks the complete
original byte sequence, including surrounding text and synchronization
markers, not just command counts. An emulated terminal query response must
also reach the client intact through raw VT console input. A named event
coordinates readiness; output capture and waits are bounded. It does not
create a GUI or touch existing application input.

Observed on Windows 26200 x64:

| Backend | Sent | Received | Exact output order | Query reply input |
| --- | --- | --- | --- | --- |
| OS-inbox ConPTY | 5 | **0** | no | preserved |
| Microsoft ConPTY 1.24.260710001 | 5 | **5** | preserved | preserved |

The inbox diagnostic reports `BLOCKED` rather than image acceptance. An
explicit packaged-backend run fails if graphics, ordering, or replies are lost.

## GUI and ordinary Pi acceptance

```text
python test/windows-images.py --exe zig-out/bin/ghostty.exe
python test/windows-images.py --pi-mode plain --exe zig-out/bin/ghostty.exe
python test/windows-images.py --exe FIXED.exe --baseline-exe STOCK.exe --session SESSION.jsonl --screenshot-dir TEMP_DIR
python test/windows-images.py --pi-mode resume --exe FIXED.exe --baseline-exe STOCK.exe --session SESSION.jsonl --screenshot-dir TEMP_DIR
python test/windows-tabs.py --exe zig-out/bin/ghostty.exe
python test/windows-tabs-ui.py --exe zig-out/bin/ghostty.exe
```

- The encoder test uses Pi's installed, unmodified Kitty encoder with a PNG
  large enough for multiple chunks. It asserts visible, correctly located
  image pixels, survival through PTY resizing, placement movement on scrolling,
  deletion, and clean shutdown. The optional stock build is a negative control.
- `plain` verifies ordinary Pi starts in interactive TTY mode, without a model
  prompt. Image replay is tested separately, without needing a model request.
- Session/resume modes use independent temporary session copies and the actual
  `pi.cmd`. Resume selects the copied session through Pi's ordinary picker,
  sending Enter only to the test's own surface. The original session's SHA-256
  is checked. Stock and fixed builds use the same light background and geometry.
- The reported trading session passed ordinary `pi --session` and `pi --resume`
  replay. Native screenshots were inspected: the inline screenshot is visible
  above the Chinese response, rather than displaced off the right edge. The
  stock build has no image. Image visibility changes white-pixel count by 13,164
  in the tested viewport; that count alone is not the visual acceptance evidence.
- Keyboard/tab creation, switching, reordering, close operations, independent
  sessions/windows, native window controls, and clean shutdown passed. One
  keyboard test initially failed a focus assertion; both the stock control and
  the packaged-backend retry passed, so that transient was recorded rather than
  silently ignored.

Targeted Zig verification:

```text
zig build test-lib-vt "-Dtest-filter=image load: rgb" --summary all
zig build test -Dapp-runtime=win32 -Dtest-filter=pty --summary all
zig build run -Dapp-runtime=win32
```

Windows `run` and full-core `test` steps depend on the backend installation
and automatically set `GHOSTTY_CONPTY_DIR` for their child process, including
when using a custom `--prefix`. No manual environment setup is required.
VT-only tests do not depend on the backend. With the override unset and fresh
custom prefixes, the PTY filter passed **197**, with **5** skips, and `run`
launched a native console child and exited successfully.

RGB/RGBA image-load tests passed **81/81**. The broader `image` filter passed
**239**, with **10** platform skips. The `pty` filtered test run passed
**197**, with **5** platform skips. These are targeted runs, not a claim that
all Ghostty tests, all Windows versions, or x86/ARM64 runtime behavior passed.

The final default-prefix build passed **131/131** build steps and installed
`zig-out/bin/ghostty.exe` with its native backend. The existing desktop
shortcut was verified to target that executable; it was not modified. The
deployed executable then passed the encoder regression and copied trading
session replay, and its native screenshot was inspected. The stale installed
JavaScript helper was removed. All six dependency binaries had valid Microsoft
Authenticode signatures, and a deliberately wrong archive was rejected without
changing the existing dependency cache.

Deployment used an unlocked executable; no existing application was terminated
to replace it. Future deployments must follow the same rule: stage separately
if the executable is locked, and confirm the desktop shortcut's target.
