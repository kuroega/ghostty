# Windows startup cursor fix — final verification

## Objective / completion criteria

Find the cause of Windows Ghostty's multi-second loading cursor, remove that
feedback delay, improve startup work, and deliver a tested executable at the
existing desktop-shortcut target without breaking native terminal functionality.

## Root cause and causal evidence

The multi-second cursor is **Windows process-startup feedback**, not evidence
that Ghostty's window is blocked for the same duration. The packaged ConPTY
factory starts headless OpenConsole without STARTF_FORCEOFFFEEDBACK. A GUI
parent can therefore request feedback for a headless child that does not enter
a GUI-ready message loop. Windows eventually clears feedback on its timeout.
Setting FORCEOFFFEEDBACK on the shell alone does not control the host's launch.

The initial claim that font scanning was the cause of the full cursor duration
was incorrect. Font probing has measurable overhead, but does not explain a
responsive window while the cursor continues spinning for seconds.

Evidence on this machine:

1. Old installed Debug binary, deliberately delayed GUI child command through
   its actual ConPTY path: window responsive at 0.426 s, appstarting cursor
   persisted **5211 ms**.
2. Initial partial ReleaseFast patch (arrow class cursors + shell feedback flag):
   responsive at 0.344 s, feedback still **5124 ms**. Thus those changes alone
   did **not** fix the headless-host feedback source.
3. Same delayed child launched directly with FORCEOFFFEEDBACK: its window still
   takes about four seconds to appear, but sampled busy duration is **0 ms**.
4. Isolated packaged ConPTY creation, no shell or Ghostty launched, from a
   GUI-subsystem pythonw parent whose own feedback was disabled: host creation
   takes 0.003 s, yet appstarting feedback lasts about 5.94 s. Console-subsystem
   control creates the same packaged pseudoconsole with no sampled spinner.
5. Final host-launch patch, same delayed child through Ghostty: three 7-second
   observations show responsive times 0.337/0.333/0.337 s and **0 ms** busy cursor
   in every run. The child remains deliberately slow; no pointer movement or
   cursor-state injection is used in these causal startup comparisons.

This reproduces and removes the multi-second feedback mechanism through real
Ghostty process creation, rather than inferring success from a green build.
The exact original manual launch timing was not recorded; the controlled
regression isolates the same Windows feedback mechanism without requiring the
user's original timing to recur after caches have warmed.

## Implementation

- `src/os/conpty_host.zig`: create ConDrv server/reference and signal pipe using
  Microsoft's MIT-licensed host creation protocol; launch the **same packaged**
  OpenConsole with STARTF_FORCEOFFFEEDBACK. Pass only four intended inheritable
  handles using PROC_THREAD_ATTRIBUTE_HANDLE_LIST. Use an explicit trusted
  application path and quoted command line. Pack the three owned handles with
  the pinned DLL's ConptyPackPseudoConsole export. The packaged DLL still owns
  resize/shutdown behavior. Close temporary handles on success; close transferred
  candidates and terminate the host on packing failure.
- `src/os/conpty.zig`: retain validated native-architecture host path and pack
  export; use the no-feedback host launcher for flags=0, which is the production
  `WindowsPty.open` path. Preserve the DLL factory for other optional flags.
  Free the stored host path during API teardown. No fallback to inbox conhost.
- `src/Command.zig`, `src/os/windows.zig`: suppress shell-child feedback too;
  correct CreateProcessW's application-name parameter to const LPCWSTR.
- `src/apprt/win32.zig`, `src/apprt/win32/Window.zig`, `src/os/win32.zig`:
  explicit IDC_ARROW class cursors, preventing retention of a previous busy
  cursor. The isolated default-cursor regression demonstrates old null-class
  host/child windows retain seeded busy state; new settings select the arrow.
- `src/font/discovery.zig`, `src/font/face/freetype.zig`: reject candidate fonts
  with lightweight FreeType metadata/CMap probes, avoiding full sizing,
  HarfBuzz setup, and glyph-mutex allocation until a match. Preserve family,
  explicit style, bold/italic and codepoint matching. Clean up a matching face
  if deferred-path allocation fails. No speculative font cache was added.

## Prompt-to-artifact completion audit

| Explicit requirement | Actual evidence | Result |
| --- | --- | --- |
| Find root cause of seconds-long loading animation | Real Ghostty ConPTY regression: responsive window + 5.211 s feedback; shell-only suppression still 5.124 s; isolated GUI-parent ConPTY reproduces feedback without shell; final headless-host suppression removes it with the same delayed command | Covered: host startup feedback identified and causal fix verified |
| Improve performance | Removed full Ghostty/HarfBuzz construction for rejected font candidates. Like-mode warm startup comparison: old Debug median responsive 0.419 s, patched Debug median 0.361 s (one cold-ish outlier 0.604 s). ReleaseFast final app/slow-child median ~0.337 s; real-shortcut median ~0.390 s | Covered: reduced work and observed startup improvement; no claim of a rigorous cold-cache benchmark |
| Fix every-launch cursor issue in current user setup | Installed executable, actual Desktop/Ghostty.lnk, existing unmodified config, three 7-second observations: responsive 0.485/0.389/0.390 s; **0 ms** wait/appstarting in all three. Also three delayed-child stress runs with **0 ms** feedback | Covered within tested Windows/user setup; feedback source disabled at process creation, not masked by a timer |
| Preserve native terminal behavior | Installed executable passes Windows UI smoke test: tabs, add/close, dropdown routing, caption hit testing, maximize/restore, multiple windows and clean shutdown. Installed executable passes native Pi image encoder/chunking/placement/resize/scroll/delete test | Covered for modified host lifecycle, resize and ordered PTY output |
| Preserve font correctness | Targeted font tests pass regular/bold/italic/bold-italic, explicit style, present 'A', missing U+10FFFF and family name extraction | Covered |
| Deliver working fix | Desktop shortcut still targets zig-out/bin/ghostty.exe; installed final binary and staged host-fixed binary both SHA-256 bea319acf5f20a78f451c59643ef91ac4858d1558708341258c70885b362acaa. Original and partial builds backed up separately. Native DLL/host package, user config and shortcut unchanged | Covered |

## Verification commands

Compiler: `C:/Users/WYX/tools/zig-x86_64-windows-0.16.0/zig.exe`

```text
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast --prefix zig-out/windows-startup-host-fixed
zig build test -Dapp-runtime=win32 -Dtest-filter="native ConPTY"
zig build test -Dapp-runtime=win32 -Dtest-filter="windows font discovery"
zig build test -Dapp-runtime=win32 -Dtest-filter="execCommand windows"
zig build test -Dapp-runtime=win32 -Dtest-filter="face name"
python test/windows-tabs-ui.py --exe zig-out/bin/ghostty.exe
python test/windows-images.py --exe zig-out/bin/ghostty.exe
python test/windows/cursor-default-regression.py
python test/windows-startup.py --shell-launch --exe C:/Users/WYX/Desktop/Ghostty.lnk --require-cursors --require-known-cursor --max-busy-ms 250 --seconds 7
python test/windows-startup.py --exe zig-out/windows-startup-host-fixed/bin/ghostty.exe --require-cursors --require-known-cursor --max-busy-ms 250 --seconds 7 -- "--command=C:/Users/WYX/AppData/Local/Programs/Python/Python310/pythonw.exe C:/Users/WYX/Documents/workspace/ghostty/test/windows/startup-feedback-fixture.py"
git diff --check
```

Additional gate coverage:

- The four-second delayed GUI fixture launched directly with FORCEONFEEDBACK
  produces 4351 ms feedback; the 250 ms verifier gate **fails as expected**.
  This demonstrates that cursor sampling detects a real persistent animation,
  rather than accepting responsiveness as a proxy.
- `--require-known-cursor` fails on unrecognized themed cursor handles rather
  than treating them as evidence that no animation exists.
- Packaged host directory with spaces tested via scoped GHOSTTY_CONPTY_DIR:
  successful responsive launch, zero sampled spinner, temporary directory
  cleaned up. No Windows global environment/settings were changed.
- Native ConPTY size-validation test rejects zero/negative dimensions before
  opening handles. Aggregate Zig pass counts include dependency tests and are
  not used as proof of cursor behavior.
- `watch-startup.py` is an optional passive recorder for future user reports;
  it never launches/closes programs, changes cursors, or injects input. It is
  not needed as a completion substitute for the causal tests above.

## Boundaries

Validated on this Windows x64 machine and its pinned packaged ConPTY. Other
architectures were not runtime-tested. Optional nonzero pseudoconsole flags
retain the existing DLL path; current Ghostty terminal creation always uses
zero. Startup sampling measures cursor and visible-window responsiveness, not
shell-prompt or first-render readiness. General Windows feedback for unrelated
GUI programs, unrelated future regressions, and arbitrary shell-profile delays
are not claimed fixed. No issue or PR was created.
