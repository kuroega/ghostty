# Windows Tests

Manual test programs for Windows-specific functionality.

## Native Pi image support

See [native ConPTY implementation and acceptance](native-images.md) and
[dependency preparation/distribution](../../vendor/conpty/README.md).
The Windows GUI bundles an official, pinned Microsoft native backend;
ordinary Pi needs no preload, compatibility launcher, or npm modification.

```text
zig build fetch-conpty -Dapp-runtime=win32
zig build -Dapp-runtime=win32
zig build-exe test/windows/conpty-images.zig -O ReleaseSafe
conpty-images.exe 0 C:\absolute\path\to\bin\conpty\conpty.dll
python test/windows-images.py --exe zig-out/bin/ghostty.exe
```

The pure Zig probe checks APC preservation, exact ordering, synchronized
output, and query-reply input. The GUI test checks the original Pi encoder,
chunking, placement, scrolling, resize, deletion, and shutdown. Session/resume
acceptance uses ordinary `pi.cmd` on temporary copies of the source session.
The previous JavaScript workaround and private decoder have been removed.

## Right-click selection copying

The Win32 runtime does not implement context menus. Its default
`right-click-action` is therefore `copy-or-paste`, matching Windows Terminal:
left-drag to select, right-click to copy and clear the selection, then
right-click without a selection to paste. Other platforms retain the
`context-menu` default; explicit configuration overrides are respected.

```text
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast
python test/windows-right-click.py --exe zig-out/bin/ghostty.exe
python test/windows-right-click.py --exe zig-out/bin/ghostty.exe --action copy
python test/windows-right-click.py --exe zig-out/bin/ghostty.exe --action ignore
```

The native regression sends mouse messages only to its own terminal, checks
that dragging alone does not copy, checks the exact Unicode clipboard text
after right-click, and verifies paste through the child process's stdin.
It temporarily replaces the clipboard and restores Unicode text only;
run with no valuable non-text clipboard contents. The pre-fix default fails
the copy check because it requests an unimplemented context menu.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info + ghostty_init to
verify the MSVC C runtime is properly initialized.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```
copy ..\..\zig-out\lib\ghostty-internal.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".
