# Native Windows ConPTY dependency

The Windows GUI ships Microsoft's official, signed, side-by-side ConPTY and
OpenConsole binaries. The package version, archive SHA-256, and all six
binary SHA-256 values are pinned in `package.json`. The package declares MIT;
`LICENSE` is installed with the binaries. No custom console fork is required.

## Prepare and build

Python 3 and curl are build-time tools only. From the repository root:

```text
zig build fetch-conpty -Dapp-runtime=win32
zig build -Dapp-runtime=win32
```

For offline preparation of the exact pinned NuGet package:

```text
python scripts/fetch-conpty.py --archive downloaded-package.nupkg
python scripts/fetch-conpty.py --verify
```

`fetch-conpty` downloads only on explicit request, verifies HTTPS and the
pinned hashes, validates version/license metadata, and extracts an allowlist
of files into the ignored `runtime/` cache. Normal Windows GUI builds verify
that cache without networking. Other platforms and standalone VT builds do
not require this dependency. Updating the pin requires repeating the native
transport and Pi acceptance tests, not merely replacing the DLL.

## Distribution

Keep the complete installed bundle next to the executable:

```text
bin/ghostty.exe
bin/conpty/conpty.dll
bin/conpty/x86/OpenConsole.exe
bin/conpty/x64/OpenConsole.exe
bin/conpty/arm64/OpenConsole.exe
bin/conpty/LICENSE
bin/conpty/package.json
```

The DLL matches the application architecture; ConPTY selects the host for the
native OS architecture, including emulated applications. Copying just
`ghostty.exe` is insufficient. The executable is installed only after its
backend bundle has been verified and installed.

The Zig loader uses an absolute executable-relative path and restricts DLL
search to that directory and System32. It requires a matching OpenConsole
host and fails instead of silently falling back to the OS-inbox conhost,
which discarded Kitty APC on the tested Windows build. The module remains
loaded until its HPCON is closed; create, resize, and close use the same API.

`GHOSTTY_CONPTY_DIR` is an optional process-local developer/test override for
an absolute directory containing the same bundle. `zig build run` and full-core
`zig build test` install the backend and set this variable automatically for
their cache-located child executable, respecting custom `--prefix` paths.
VT-only tests do not install the backend. Ordinary Pi users do not need an
override, a launcher, Node preload, or npm modification.

Runtime-tested: Windows build 26200, x64, Pi 0.99.1. x86/ARM64 artifacts are
included and hash-pinned but have not been runtime-tested in this environment.
