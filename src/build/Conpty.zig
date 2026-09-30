//! Pinned side-by-side Microsoft native ConPTY distribution for Windows.
//! Binary acquisition is explicit; normal builds verify the local cache and
//! never download, modify system consoles, or inject application scripts.
const std = @import("std");

pub fn install(b: *std.Build, target: std.Target) *std.Build.Step {
    const ready = b.step("install-conpty", "Install the verified native Windows ConPTY bundle");
    const python = if (b.graph.host.result.os.tag == .windows) "python" else "python3";
    const fetch = b.addSystemCommand(&.{python});
    fetch.addFileArg(b.path("scripts/fetch-conpty.py"));
    b.step("fetch-conpty", "Prepare the pinned native Windows ConPTY dependency").dependOn(&fetch.step);

    const verify = b.addSystemCommand(&.{python});
    verify.addFileArg(b.path("scripts/fetch-conpty.py"));
    verify.addArg("--verify");

    const arch = switch (target.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => @panic("Microsoft native ConPTY supports x86, x86_64, and aarch64 Windows targets"),
    };
    const dll = b.addInstallFileWithDir(
        b.path(b.pathJoin(&.{ "vendor/conpty/runtime", arch, "conpty.dll" })),
        .bin,
        "conpty/conpty.dll",
    );
    dll.step.dependOn(&verify.step);
    ready.dependOn(&dll.step);
    // ConPTY selects the OS-native host, not necessarily the application's
    // architecture (for example, an x64 app on an ARM64 Windows host).
    for ([_][]const u8{ "x86", "x64", "arm64" }) |host_arch| {
        const host = b.addInstallFileWithDir(
            b.path(b.pathJoin(&.{ "vendor/conpty/runtime/hosts", host_arch, "OpenConsole.exe" })),
            .bin,
            b.pathJoin(&.{ "conpty", host_arch, "OpenConsole.exe" }),
        );
        host.step.dependOn(&verify.step);
        ready.dependOn(&host.step);
    }
    for ([_][]const u8{ "LICENSE", "package.json" }) |name| {
        ready.dependOn(&b.addInstallFileWithDir(
            b.path(b.pathJoin(&.{ "vendor/conpty", name })),
            .bin,
            b.pathJoin(&.{ "conpty", name }),
        ).step);
    }
    return ready;
}
