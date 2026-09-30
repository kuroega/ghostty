//! Native Win32 application runtime for Ghostty on Windows.
//!
//! This implements the apprt interface using the raw Win32 API: a classic
//! message loop, top-level windows hosting independent terminal tabs,
//! ConPTY-backed termio (provided by the core), and frame presentation
//! via GDI StretchDIBits from the renderer's CPU-memory frame export.
//!
//! Key input, clipboard, and DPI handling all follow Win32 conventions.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const input = @import("../input.zig");
const rendererpkg = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");
const win32 = @import("../os/win32.zig");
const Window = @import("win32/Window.zig");

const log = std.log.scoped(.win32);
const Win32Error = @import("std").os.windows.Win32Error;

pub const resourcesDir = internal_os.resourcesDir;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("the win32 apprt only compiles on Windows");
    }
}

/// Scale factor assumed for rendering; Win32 gives us per-monitor DPI.
const base_dpi: f64 = 96.0;

/// Default initial window size in pixels.
const default_width: u32 = 1024;
const default_height: u32 = 720;

fn lastError() Win32Error {
    return std.os.windows.GetLastError();
}

/// Convert a Win32 virtual-key state to Ghostty modifier flags. Uses
/// the key state arrays from the current message to be consistent with
/// the event being processed.
fn modsFromMessage(wparam: win32.WPARAM, lparam: win32.LPARAM, msg: win32.UINT) input.Mods {
    _ = wparam;
    _ = lparam;
    _ = msg;

    var mods: input.Mods = .{};

    // Use the queue's state for this message. Async state may already
    // reflect a later modifier release while tab creation/closure is busy.
    if (@as(u16, @bitCast(win32.exp.GetKeyState(0x10))) & 0x8000 != 0) mods.shift = true; // VK_SHIFT
    if (@as(u16, @bitCast(win32.exp.GetKeyState(0x11))) & 0x8000 != 0) mods.ctrl = true; // VK_CONTROL
    if (@as(u16, @bitCast(win32.exp.GetKeyState(0x12))) & 0x8000 != 0) mods.alt = true; // VK_MENU
    if (@as(u16, @bitCast(win32.exp.GetKeyState(0x5B))) & 0x8000 != 0 or // VK_LWIN
        @as(u16, @bitCast(win32.exp.GetKeyState(0x5C))) & 0x8000 != 0) // VK_RWIN
        mods.super = true;

    return mods;
}

/// Map a Win32 virtual-key code to a Ghostty input key. This covers the
/// common keys; unmapped keys report `.unidentified` and rely on the
/// UTF-8 text path.
fn keyFromVirtualKey(vk_arg: win32.UINT) input.Key {
    const vk: c_int = @intCast(vk_arg);
    return switch (vk) {
        0x08 => .backspace, // VK_BACK
        0x09 => .tab, // VK_TAB
        0x0D => .enter, // VK_RETURN
        0x13 => .pause, // VK_PAUSE
        0x14 => .caps_lock, // VK_CAPITAL
        0x1B => .escape, // VK_ESCAPE
        0x20 => .space, // VK_SPACE
        0x21 => .page_up, // VK_PRIOR
        0x22 => .page_down, // VK_NEXT
        0x23 => .end, // VK_END
        0x24 => .home, // VK_HOME
        0x25 => .arrow_left, // VK_LEFT
        0x26 => .arrow_up, // VK_UP
        0x27 => .arrow_right, // VK_RIGHT
        0x28 => .arrow_down, // VK_DOWN
        0x2D => .insert, // VK_INSERT
        0x2E => .delete, // VK_DELETE
        0x30...0x39 => @enumFromInt(@as(c_int, @intCast(@intFromEnum(input.Key.digit_0) + (vk - 0x30)))),
        0x41...0x5A => @enumFromInt(@as(c_int, @intCast(@intFromEnum(input.Key.key_a) + (vk - 0x41)))),
        0x5F => .sleep, // VK_SLEEP
        0x60...0x69 => .numpad_0, // handled specially below
        0x6A => .numpad_multiply,
        0x6B => .numpad_add,
        0x6D => .numpad_subtract,
        0x6E => .numpad_decimal,
        0x6F => .numpad_divide,
        0x70...0x87 => @enumFromInt(@as(c_int, @intCast(@intFromEnum(input.Key.f1) + (vk - 0x70)))), // F1-F24
        0x90 => .num_lock, // VK_NUMLOCK
        0x91 => .scroll_lock, // VK_SCROLL
        0xA0 => .shift_left, // VK_LSHIFT
        0xA1 => .shift_right, // VK_RSHIFT
        0xA2 => .control_left, // VK_LCONTROL
        0xA3 => .control_right, // VK_RCONTROL
        0xA4 => .alt_left, // VK_LMENU
        0xA5 => .alt_right, // VK_RMENU
        0xBA => .semicolon, // VK_OEM_1
        0xBB => .equal, // VK_OEM_PLUS
        0xBC => .comma, // VK_OEM_COMMA
        0xBD => .minus, // VK_OEM_MINUS
        0xBE => .period, // VK_OEM_PERIOD
        0xBF => .slash, // VK_OEM_2
        0xC0 => .backquote, // VK_OEM_3
        0xDB => .bracket_left, // VK_OEM_4
        0xDC => .backslash, // VK_OEM_5
        0xDD => .bracket_right, // VK_OEM_6
        0xDE => .quote, // VK_OEM_7
        else => .unidentified,
    };
}

/// Map numpad virtual keys precisely (they aren't contiguous in the
/// Ghostty enum space).
fn keyFromVirtualKeyNumpad(vk: win32.UINT) ?input.Key {
    return switch (vk) {
        0x60 => .numpad_0,
        0x61 => .numpad_1,
        0x62 => .numpad_2,
        0x63 => .numpad_3,
        0x64 => .numpad_4,
        0x65 => .numpad_5,
        0x66 => .numpad_6,
        0x67 => .numpad_7,
        0x68 => .numpad_8,
        0x69 => .numpad_9,
        else => null,
    };
}

/// Convert Win32 virtual key + scan code to a UTF-8 string for text
/// input, using the current keyboard layout via ToUnicode.
fn textFromVirtualKey(
    vk: win32.UINT,
    scancode: win32.UINT,
    mods: input.Mods,
    buf: []u8,
) []const u8 {
    _ = mods;

    // Keyboard state for ToUnicode.
    var key_state: [256]u8 = @splat(0);
    _ = win32.exp.GetKeyboardState(&key_state);

    var wide: [8]u16 = @splat(0);
    const n = win32.exp.ToUnicode(
        vk,
        scancode,
        &key_state,
        &wide,
        wide.len,
        0,
    );
    if (n <= 0) return "";

    const slice = wide[0..@intCast(n)];
    const len = std.unicode.utf16LeToUtf8(buf, slice) catch return "";
    return buf[0..len];
}

pub const App = struct {
    core_app: *CoreApp,
    config: Config,
    surfaces: std.ArrayList(*Surface) = .empty,
    windows: std.ArrayList(*Window) = .empty,

    /// The thread ID of the thread running our message loop. Other
    /// threads (renderer, io) wake it by posting a message directly to
    /// this thread's queue.
    main_thread_id: win32.DWORD = 0,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        opts: struct {},
    ) !void {
        _ = opts;

        // Opt out of DPI virtualization. Ghostty renders its own text at
        // the physical pixel resolution, and reporting the content scale
        // to the core. Without this, Windows bitmap-stretches our window
        // and coordinates are reported in virtualized units.
        if (win32.exp.SetProcessDpiAwarenessContext(
            win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        ) == win32.FALSE) {
            // Older Windows: fall back to system DPI awareness.
            _ = win32.exp.SetProcessDPIAware();
        }

        // Force creation of this thread's message queue. `PostThreadMessageW`
        // fails for threads without a queue, so a worker thread could race
        // us if we skipped this.
        var msg: win32.MSG = undefined;
        _ = win32.exp.PeekMessageW(&msg, null, 0, 0, win32.PM_NOREMOVE);

        const alloc = core_app.alloc;
        // Load our own config like the GTK apprt does (the entrypoint
        // doesn't pass one in).
        var config_clone = configpkg.Config.load(alloc) catch |err| blk: {
            log.warn("failed to load config, using default err={}", .{err});
            break :blk try configpkg.Config.default(alloc);
        };
        errdefer config_clone.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            // Capture this AFTER the struct literal above, since
            // assigning `self.*` would otherwise clobber it.
            .main_thread_id = win32.exp.GetCurrentThreadId(),
        };
    }

    pub fn terminate(self: *App) void {
        // The core app does not own our apprt surfaces, so we must
        // deinitialize and free them here. We do this before the core
        // app tears down so that we can remove the surface from the
        // core's surface list first (avoiding a dangling pointer).
        for (self.windows.items) |window| window.close();
        while (self.surfaces.pop()) |s| {
            s.deinit();
            self.core_app.alloc.destroy(s);
        }
        self.surfaces.deinit(self.core_app.alloc);
        for (self.windows.items) |window| {
            window.deinit();
            self.core_app.alloc.destroy(window);
        }
        self.windows.deinit(self.core_app.alloc);

        self.config.deinit();
    }

    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    pub fn wakeup(self: *const App) void {
        // Post to the main thread's queue specifically. `PostMessageW`
        // with a NULL window posts to the CALLING thread's queue, which
        // is the wrong queue when this is called from the renderer or io
        // thread (and was silently dropping wakes).
        if (win32.exp.PostThreadMessageW(
            self.main_thread_id,
            win32.WM_GHOSTTY_WAKE,
            0,
            0,
        ) == win32.FALSE) {
            const err = lastError();
            if (err != .SUCCESS and err != .INVALID_THREAD_ID) {
                log.warn("PostThreadMessageW failed id={} err={}", .{ self.main_thread_id, err });
            }
        }
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });

        switch (action) {
            .quit => {
                std.process.exit(0);
                return true;
            },

            .new_window => {
                // Create a new window with a new surface.
                self.newWindow() catch |err| {
                    log.err("error creating new window err={}", .{err});
                };
                return true;
            },

            .new_tab => {
                const window = self.targetWindow(target) orelse return false;
                try window.newTab();
                return true;
            },

            .goto_tab => {
                const window = self.targetWindow(target) orelse return false;
                window.gotoTab(value);
                return true;
            },

            .move_tab => {
                const window = self.targetWindow(target) orelse return false;
                const surface = switch (target) {
                    .surface => |s| s.rt_surface,
                    .app => window.active() orelse return false,
                };
                window.moveTab(surface, value.amount);
                return true;
            },

            .close_tab => {
                const window = self.targetWindow(target) orelse return false;
                const surface = switch (target) {
                    .surface => |s| s.rt_surface,
                    .app => window.active() orelse return false,
                };
                window.closeTabs(surface, value);
                return true;
            },

            .close_window => {
                const window = self.targetWindow(target) orelse return false;
                window.close();
                return true;
            },

            .set_tab_title => {
                switch (target) {
                    .app => return false,
                    .surface => |s| try s.rt_surface.setTabTitle(value.title),
                }
                return true;
            },

            .set_title => {
                switch (target) {
                    .app => {},
                    .surface => |core| core.rt_surface.setTitle(value.title),
                }
                return true;
            },

            .desktop_notification => {
                log.info("desktop notification: {s}", .{value.title});
                return true;
            },

            .config_change => {
                // We can't live-reload config in this minimal apprt.
                return true;
            },

            // The renderer has a fresh frame ready for us. Invalidate
            // the window so that WM_PAINT pulls the new frame (our
            // surface mailbox and the renderer live on separate
            // threads, so this is the only signal we get that the
            // contents changed).
            .render => {
                switch (target) {
                    .app => {},
                    .surface => |core| {
                        _ = win32.exp.InvalidateRect(
                            core.rt_surface.hwnd,
                            null,
                            win32.FALSE,
                        );
                    },
                }
                return true;
            },

            // Ring the bell by sounding the system default beep. This
            // matches the visual/audible bell the core expects.
            .ring_bell => {
                _ = win32.exp.MessageBeep(0); // MB_OK: system default sound
                return true;
            },

            // Actions that are harmless to accept and ignore in this
            // minimal apprt. The core treats a `true` return as
            // "handled" so it won't keep retrying.
            .present_terminal,
            .scrollbar,
            .mouse_shape,
            .mouse_visibility,
            .mouse_over_link,
            .renderer_health,
            .initial_size,
            .reset_window_size,
            .size_limit,
            .cell_size,
            .reload_config,
            .selection_changed,
            .progress_report,
            .show_child_exited,
            .readonly,
            .key_sequence,
            .key_table,
            .color_change,
            .inspector,
            .render_inspector,
            .export_terminal_io,
            => return true,

            .quit_timer => {
                switch (value) {
                    // The core asks us to quit once the last window is
                    // gone (subject to config). We have no windows left
                    // at that point, so exit the message loop.
                    .start => win32.exp.PostQuitMessage(0),
                    .stop => {},
                }
                return true;
            },

            else => {
                log.warn("unhandled apprt action={}", .{action});
                return false;
            },
        }
    }
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        log.warn("IPC not supported on win32 apprt action={}", .{action});
        return false;
    }

    fn targetWindow(self: *App, target: apprt.Target) ?*Window {
        switch (target) {
            .surface => |s| return if (!s.rt_surface.window.closing) s.rt_surface.window else null,
            .app => {
                const foreground = win32.exp.GetForegroundWindow();
                for (self.windows.items) |window| {
                    if (!window.closing and window.hwnd == foreground) return window;
                }
                for (self.windows.items) |window| if (!window.closing) return window;
                return null;
            },
        }
    }

    /// Create a top-level window with its first terminal tab.
    pub fn newWindow(self: *App) !void {
        const alloc = self.core_app.alloc;
        try self.windows.ensureUnusedCapacity(alloc, 1);
        const window = try alloc.create(Window);
        errdefer alloc.destroy(window);
        try window.init(self);
        errdefer window.deinit();
        self.windows.appendAssumeCapacity(window);
        errdefer _ = self.windows.pop();
        try window.newTab();
        _ = win32.exp.ShowWindow(window.hwnd, win32.SW_SHOW);
        _ = win32.exp.UpdateWindow(window.hwnd);
        window.activate(0);
    }

    /// Run the Win32 message loop. This doesn't return until quit.
    pub fn run(self: *App) !void {
        // The initial window.
        try self.newWindow();

        var msg: win32.MSG = undefined;
        while (win32.exp.GetMessageW(&msg, null, 0, 0) != win32.FALSE) {
            _ = win32.exp.TranslateMessage(&msg);
            _ = win32.exp.DispatchMessageW(&msg);

            // Drain the core app mailbox after each message batch. The
            // mailbox is how surfaces and termio threads communicate.
            try self.core_app.tick(self);

            // Destroy closed surfaces outside wndProc and mailbox dispatch,
            // where no callback can still be using their core state.
            var i: usize = 0;
            while (i < self.surfaces.items.len) {
                const s = self.surfaces.items[i];
                if (win32.exp.IsWindow(s.hwnd) != win32.FALSE) {
                    i += 1;
                    continue;
                }
                _ = self.surfaces.swapRemove(i);
                s.window.removeTab(s);
                s.deinit();
                self.core_app.alloc.destroy(s);
            }
            i = 0;
            while (i < self.windows.items.len) {
                const window = self.windows.items[i];
                if (!window.closing) {
                    i += 1;
                    continue;
                }
                _ = self.windows.swapRemove(i);
                window.deinit();
                self.core_app.alloc.destroy(window);
            }
        }
    }
};

pub const Surface = struct {
    app: *App,
    window: *Window,
    core_surface: CoreSurface = undefined,
    initialized: bool = false,

    hwnd: win32.HWND = undefined,
    width: u32 = default_width,
    height: u32 = default_height,
    dpi: u32 = 96,
    title: ?[:0]u8 = null,
    tab_title: ?[:0]u8 = null,
    cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },
    focused: bool = true,
    last_frame: ?rendererpkg.Renderer.ExportedFrame = null,

    /// The window class name, registered once per process.
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

    pub const Options = struct {
        window: *Window,
        context: apprt.surface.NewSurfaceContext,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        const alloc = app.core_app.alloc;

        // CreateWindowExW calls wndProc synchronously, so all callback
        // state must be initialized before we expose this pointer.
        self.* = .{ .app = app, .window = opts.window, .dpi = opts.window.dpi, .focused = false };

        // Register the window class once.
        registerWindowClass(alloc) catch |err| switch (err) {
            error.AlreadyRegistered => {},
            else => return err,
        };

        // Each terminal owns a child HWND. The top-level window owns the
        // tab strip and routes focus, visibility, and DPI to its children.
        const rect = opts.window.terminalRect();
        const hwnd = win32.exp.CreateWindowExW(
            0,
            class_name.ptr,
            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
            win32.WS_CHILD | win32.WS_CLIPSIBLINGS,
            0,
            rect.top,
            @max(rect.right, 1),
            @max(rect.bottom - rect.top, 1),
            opts.window.hwnd,
            null,
            win32.exp.GetModuleHandleW(null),
            self,
        ) orelse {
            log.err("CreateWindowExW failed err={}", .{lastError()});
            return error.CreateWindowFailed;
        };
        errdefer _ = win32.exp.DestroyWindow(hwnd);

        self.hwnd = hwnd;
        var client: win32.RECT = undefined;
        if (win32.exp.GetClientRect(hwnd, &client) != win32.FALSE) {
            self.width = @intCast(client.right - client.left);
            self.height = @intCast(client.bottom - client.top);
        }

        // Associate the surface with the window.
        if (win32.exp.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(self))) == 0) {
            // Not fatal, just means WM_CREATE association didn't stick.
        }

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();

        // Windows has no notion of the user's "login shell" the way
        // POSIX does. Ghostty's Windows default is PowerShell (set in
        // Config), so we don't need to do anything here; an explicit
        // `command = ...` in the config always wins.

        // Initialize our core surface.
        self.core_surface = undefined;
        try self.core_surface.init(
            alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();
        self.initialized = true;

        // The owning window shows/focuses this child after committing it
        // to its tab list. Hidden tabs keep their shell but pause rendering.
        try self.core_surface.focusCallback(false);
    }

    pub fn deinit(self: *Surface) void {
        if (self.initialized) {
            self.app.core_app.deleteSurface(self);
            self.core_surface.deinit();
            self.initialized = false;
        }

        if (self.last_frame) |frame| frame.deinit();
        self.last_frame = null;
        if (self.title) |t| self.app.core_app.alloc.free(t);
        if (self.tab_title) |t| self.app.core_app.alloc.free(t);
        if (win32.exp.IsWindow(self.hwnd) != win32.FALSE) {
            _ = win32.exp.DestroyWindow(self.hwnd);
        }
    }

    /// The core surface. Required by CoreApp bookkeeping.
    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    /// The apprt App that owns this surface.
    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    fn registerWindowClass(alloc: Allocator) !void {
        _ = alloc;
        if (class_registered) return;
        class_registered = true;

        const wc: win32.WNDCLASSW = .{
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
            .lpfnWndProc = wndProc,
            .hInstance = win32.exp.GetModuleHandleW(null) orelse return error.GetModuleFailed,
            .lpszClassName = class_name.ptr,
        };
        if (win32.exp.RegisterClassW(&wc) == 0) {
            // ERROR_CLASS_ALREADY_EXISTS means another thread beat us.
            if (lastError() != .CLASS_ALREADY_EXISTS) {
                log.err("RegisterClassW failed err={}", .{lastError()});
                return error.RegisterClassFailed;
            }
            return error.AlreadyRegistered;
        }
    }

    pub fn close(self: *Surface, process_alive: bool) void {
        // Destroy only this tab's child HWND. The app removes and frees
        // it after callbacks return, closing its parent only for the last tab.
        _ = process_alive;
        if (win32.exp.IsWindow(self.hwnd) != win32.FALSE) {
            _ = win32.exp.DestroyWindow(self.hwnd);
        }
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        const scale: f32 = @floatCast(@as(f64, @floatFromInt(self.dpi)) / base_dpi);
        return .{ .x = scale, .y = scale };
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = self;
        return clipboard_type == .standard;
    }

    pub fn setClipboard(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        _ = confirm;
        if (clipboard_type != .standard) return;
        if (contents.len == 0) return;

        // Encode to UTF-16.
        const text = contents[0].data;
        const utf16 = std.unicode.utf8ToUtf16LeAlloc(
            self.app.core_app.alloc,
            text,
        ) catch |err| switch (err) {
            error.InvalidUtf8 => return error.InvalidUtf8,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.app.core_app.alloc.free(utf16);

        try self.setClipboardUtf16(utf16);
    }

    fn setClipboardUtf16(self: *Surface, text: []const u16) !void {
        if (win32.exp.OpenClipboard(self.hwnd) == win32.FALSE)
            return error.OpenClipboardFailed;
        defer _ = win32.exp.CloseClipboard();
        if (win32.exp.EmptyClipboard() == win32.FALSE)
            return error.EmptyClipboardFailed;

        const bytes = (text.len + 1) * @sizeOf(u16);
        const h = win32.exp.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse
            return error.OutOfMemory;
        errdefer _ = win32.exp.GlobalFree(h);
        const dst = win32.exp.GlobalLock(h) orelse return error.GlobalLockFailed;
        const dst_u16: [*]u16 = @ptrCast(@alignCast(dst));
        @memcpy(dst_u16[0..text.len], text);
        dst_u16[text.len] = 0;
        _ = win32.exp.GlobalUnlock(h);

        // Ownership transfers to Windows only on success.
        if (win32.exp.SetClipboardData(win32.CF_UNICODETEXT, h) == null)
            return error.SetClipboardDataFailed;
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        if (clipboard_type != .standard) return .unsupported;

        // Read the clipboard as UTF-8, synchronously.
        var text: []u8 = "";
        var owned = false;
        defer if (owned) self.app.core_app.alloc.free(text);

        if (win32.exp.OpenClipboard(null) != win32.FALSE) {
            defer _ = win32.exp.CloseClipboard();
            if (win32.exp.GetClipboardData(win32.CF_UNICODETEXT)) |h| {
                const src = win32.exp.GlobalLock(h) orelse return .unavailable;
                defer _ = win32.exp.GlobalUnlock(h);

                var len: usize = 0;
                const src_u16: [*]const u16 = @ptrCast(@alignCast(src));
                while (src_u16[len] != 0) len += 1;

                text = std.unicode.utf16LeToUtf8Alloc(
                    self.app.core_app.alloc,
                    src_u16[0..len],
                ) catch "";
                owned = text.len > 0;
            }
        }

        // completeClipboardRequest copies what it needs.
        self.core_surface.completeClipboardRequest(state, .{
            .contents = &.{
                .{ .mime = "text/plain", .data = text },
            },
            .confirmed = true,
        }) catch |err| {
            log.warn("failed to complete clipboard request err={}", .{err});
        };

        return .started;
    }

    pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
        _ = self;
        var map = try global.environMap();
        errdefer map.deinit();

        try map.put("TERM", "xterm-256color");
        try map.put("COLORTERM", "truecolor");

        return map;
    }

    pub fn setTitle(self: *Surface, title: []const u8) void {
        const alloc = self.app.core_app.alloc;
        const new = alloc.dupeZ(u8, title) catch return;
        if (self.title) |old| alloc.free(old);
        self.title = new;

        var wide: [256]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, title) catch return;
        if (n < wide.len) {
            wide[n] = 0;
            _ = win32.exp.SetWindowTextW(self.hwnd, wide[0..n :0].ptr);
        }
        self.window.titleChanged(self);
    }

    fn setTabTitle(self: *Surface, title: []const u8) !void {
        const alloc = self.app.core_app.alloc;
        const new = if (title.len > 0) try alloc.dupeZ(u8, title) else null;
        if (self.tab_title) |old| alloc.free(old);
        self.tab_title = new;
        self.window.titleChanged(self);
    }

    /// Paint the current frame. This pulls the latest frame from the
    /// renderer and blits it with GDI.
    fn paint(self: *Surface) void {
        if (!self.initialized) return;

        // Begin/end the paint cycle up front so Windows validates the
        // update region even if we have no frame to show yet.
        var ps: win32.PAINTSTRUCT = undefined;
        const hdc_opt = win32.exp.BeginPaint(self.hwnd, &ps);
        defer _ = win32.exp.EndPaint(self.hwnd, &ps);
        const hdc = hdc_opt orelse return;

        if (self.core_surface.renderer.takeFrame()) |frame| {
            if (self.last_frame) |old| old.deinit();
            self.last_frame = frame;
        }
        const frame = self.last_frame orelse return;

        switch (frame) {
            .memory => |m| {
                const w: usize = m.width;
                const h: usize = m.height;
                const row_len = w * 4;
                const total = row_len * h;
                if (total == 0) return;

                // The renderer already produced bottom-up BGRA8 (see
                // `OpenGL.present`), which is exactly what a DIB with a
                // POSITIVE height expects: GDI treats the first row in
                // memory as the bottom row, matching GL's origin. So we
                // can hand the frame buffer straight to GDI with no CPU
                // conversion and no copy at all.
                var bi: win32.BITMAPINFO = undefined;
                @memset(std.mem.asBytes(&bi), 0);
                bi.bmiHeader.biSize = @sizeOf(win32.BITMAPINFOHEADER);
                bi.bmiHeader.biWidth = @intCast(w);
                bi.bmiHeader.biHeight = @intCast(h); // bottom-up
                bi.bmiHeader.biPlanes = 1;
                bi.bmiHeader.biBitCount = 32;
                bi.bmiHeader.biCompression = win32.BI_RGB;
                bi.bmiHeader.biSizeImage = @intCast(total);

                _ = win32.exp.StretchDIBits(
                    hdc,
                    0,
                    0,
                    @intCast(w),
                    @intCast(h),
                    0,
                    0,
                    @intCast(w),
                    @intCast(h),
                    m.pixels.ptr,
                    &bi,
                    win32.DIB_RGB_COLORS,
                    win32.SRCCOPY,
                );
            },
            else => {},
        }
    }

    fn handleResize(self: *Surface, w: u32, h: u32) void {
        // The core uses the size we report here directly as the physical
        // framebuffer size (it does not apply the content scale to it),
        // so store the raw client size in physical pixels.
        self.width = w;
        self.height = h;

        if (!self.initialized) return;

        // Notify the core surface of a size change, which will
        // adjust the pty and renderer.
        self.core_surface.sizeCallback(.{
            .width = w,
            .height = h,
        }) catch |err| {
            log.warn("error updating surface size err={}", .{err});
        };
    }

    pub fn handleDpiChange(self: *Surface, dpi: u32) void {
        self.dpi = dpi;
        if (!self.initialized) return;

        const scale: f32 = @floatCast(@as(f64, @floatFromInt(dpi)) / base_dpi);
        self.core_surface.contentScaleCallback(
            .{ .x = scale, .y = scale },
        ) catch |err| {
            log.warn("error updating content scale err={}", .{err});
        };
    }

    fn handleKey(self: *Surface, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        if (!self.initialized) return;

        const vk: win32.UINT = @intCast(wparam & 0xFF);
        const scancode: win32.UINT = @intCast((lparam >> 16) & 0xFF);
        const repeat: u32 = @intCast((lparam >> 0) & 0xFFFF);
        const previous_down = (lparam & (1 << 30)) != 0;

        const action: input.Action = switch (msg) {
            win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => if (previous_down) .repeat else .press,
            else => .release,
        };

        var numpad_key = keyFromVirtualKeyNumpad(vk);
        var key = numpad_key orelse keyFromVirtualKey(vk);

        // Translate numpad 0-9 mapping: virtual keys 0x60-0x69 mapped to
        // numpad_X through the helper above. The fallback in
        // keyFromVirtualKey for 0x60...0x69 maps to .numpad_0 which is
        // wrong; fix that up here.
        if (vk >= 0x60 and vk <= 0x69 and numpad_key == null) {
            numpad_key = .numpad_0;
            key = .numpad_0;
        }

        const mods = modsFromMessage(wparam, lparam, msg);

        // Generate text for both initial presses and auto-repeat events.
        //
        // NOTE: This is the single source of
        // text input. We deliberately do NOT also handle WM_CHAR: the
        // core's key encoder writes `event.utf8` for any event that has
        // it, so feeding it from both WM_KEYDOWN and WM_CHAR would send
        // every printable character to the pty twice (and double the
        // terminal/render work per keystroke).
        var utf8_buf: [64]u8 = undefined;
        var utf8: []const u8 = "";
        if (msg == win32.WM_KEYDOWN) {
            utf8 = textFromVirtualKey(vk, scancode, mods, &utf8_buf);
        }

        // ToUnicode returns control characters with Ctrl held (e.g. 0x14
        // for Ctrl+T). Bindings still need the underlying 't', not that
        // control byte. Virtual letter/digit keys identify it independently
        // of the text sent to the shell and work on key release as well.
        var unshifted: u21 = switch (vk) {
            0x41...0x5A => @intCast(vk + ('a' - 'A')),
            0x30...0x39 => @intCast(vk),
            else => 0,
        };
        if (unshifted == 0 and utf8.len == 1) {
            unshifted = std.unicode.utf8Decode(utf8) catch 0;
        }

        // The low word of lParam is the repeat count and is 1 for the
        // very first press (NOT 0), so we must send exactly that many
        // events. Note the previous `i <= repeat` off-by-one, which sent
        // every keystroke twice (Windows reports repeat=1 for a normal
        // keypress).
        const repeat_count: u32 = switch (action) {
            .press, .repeat => @max(repeat, 1),
            .release => 1,
        };
        var i: u32 = 0;
        while (i < repeat_count) : (i += 1) {
            _ = self.core_surface.keyCallback(.{
                .action = if (i == 0) action else .repeat,
                .key = key,
                .mods = mods,
                .utf8 = utf8,
                .unshifted_codepoint = unshifted,
            }) catch |err| {
                log.warn("error in key callback err={}", .{err});
                return;
            };
        }
    }

    fn handleMouseButton(self: *Surface, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        if (!self.initialized) return;
        _ = lparam;

        const state: input.MouseButtonState = switch (msg) {
            win32.WM_LBUTTONDOWN, win32.WM_MBUTTONDOWN, win32.WM_RBUTTONDOWN => .press,
            else => .release,
        };
        const button: input.MouseButton = switch (msg) {
            win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => .left,
            win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => .middle,
            else => .right,
        };

        const mods = modsFromMessage(wparam, 0, msg);
        _ = self.core_surface.mouseButtonCallback(state, button, mods) catch {};
    }

    fn handleMouseMove(self: *Surface, lparam: win32.LPARAM) void {
        if (!self.initialized) return;

        const x: f32 = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF)));
        const y: f32 = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
        self.cursor_pos = .{ .x = x, .y = y };

        const mods = modsFromMessage(0, 0, 0);
        _ = self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch {};
    }

    fn handleMouseWheel(self: *Surface, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        _ = lparam;
        if (!self.initialized) return;

        const delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
        const units: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
        const mods = modsFromMessage(wparam, 0, msg);

        switch (msg) {
            win32.WM_MOUSEWHEEL => {
                _ = self.core_surface.scrollCallback(
                    0,
                    units * 3, // lines per notch, standard
                    .{},
                ) catch {};
            },
            else => {
                _ = self.core_surface.scrollCallback(
                    units * 3,
                    0,
                    .{},
                ) catch {};
            },
        }
        _ = mods;
    }
};

var class_registered: bool = false;

/// The window procedure. `GWLP_USERDATA` holds the surface pointer.
fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_NCCREATE => {
            const create: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @intCast(lparam)));
            const surface: *Surface = @ptrCast(@alignCast(create.lpCreateParams.?));
            _ = win32.exp.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(surface)));
            surface.hwnd = hwnd;
            return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => {},
    }

    const surface_ptr = win32.exp.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    const surface: ?*Surface = if (surface_ptr != 0)
        @ptrFromInt(@as(usize, @intCast(surface_ptr)))
    else
        null;

    if (surface) |s| switch (msg) {
        win32.WM_PAINT => {
            s.paint();
            return 0;
        },

        win32.WM_SIZE => {
            const w: u32 = @intCast(lparam & 0xFFFF);
            const h: u32 = @intCast((lparam >> 16) & 0xFFFF);
            if (w > 0 and h > 0) s.handleResize(w, h);
            return 0;
        },

        win32.WM_DPICHANGED => {
            const dpi: u32 = @intCast(wparam & 0xFFFF);
            s.handleDpiChange(dpi);
            // Resize to suggested rect.
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
            _ = win32.exp.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
            );
            return 0;
        },

        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            s.handleKey(msg, wparam, lparam);
            return 0;
        },

        win32.WM_LBUTTONDOWN,
        win32.WM_MBUTTONDOWN,
        win32.WM_RBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_MBUTTONUP,
        win32.WM_RBUTTONUP,
        => {
            if (msg == win32.WM_LBUTTONDOWN) _ = win32.exp.SetFocus(hwnd);
            s.handleMouseButton(msg, wparam, lparam);
            return 0;
        },

        win32.WM_MOUSEMOVE => {
            s.handleMouseMove(lparam);
            return 0;
        },

        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            s.handleMouseWheel(msg, wparam, lparam);
            return 0;
        },

        win32.WM_SETFOCUS => {
            s.focused = true;
            if (s.initialized) s.core_surface.focusCallback(true) catch {};
            return 0;
        },

        win32.WM_KILLFOCUS => {
            s.focused = false;
            if (s.initialized) s.core_surface.focusCallback(false) catch {};
            return 0;
        },

        win32.WM_CLOSE => {
            if (s.initialized) s.core_surface.close();
            return 0;
        },

        win32.WM_NCDESTROY => {
            // Only the owning top-level window can terminate the app.
            _ = win32.exp.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        win32.WM_DESTROY => {
            // The core surface will be deinit'd from App teardown or
            // the surface close path.
            return 0;
        },

        else => {},
    };

    return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam);
}
