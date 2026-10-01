//! A native top-level window hosting independent terminal tabs.
const Window = @This();
const std = @import("std");
const rt = @import("../win32.zig");
const win32 = @import("../../os/win32.zig");
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const log = std.log.scoped(.win32_tabs);
const Chrome = @import("Chrome.zig");

app: *rt.App,
hwnd: win32.HWND = undefined,
chrome: Chrome = .{},
tabs: std.ArrayList(*rt.Surface) = .empty,
selected: usize = 0,
dpi: u32 = 96,
closing: bool = false,
minimized: bool = false,

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
const new_button_id = 1001;
const close_button_id = 1002;

pub fn init(self: *Window, app: *rt.App) !void {
    self.* = .{ .app = app, .dpi = win32.exp.GetDpiForSystem() };
    const wc: win32.WNDCLASSW = .{
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .hCursor = win32.exp.LoadCursorW(null, @ptrFromInt(32512)), // IDC_ARROW
        .hInstance = win32.exp.GetModuleHandleW(null) orelse return error.GetModuleFailed,
        .hbrBackground = @ptrFromInt(win32.COLOR_BTNFACE + 1),
        .lpszClassName = class_name.ptr,
    };
    if (win32.exp.RegisterClassW(&wc) == 0 and
        std.os.windows.GetLastError() != .CLASS_ALREADY_EXISTS) return error.RegisterClassFailed;

    var width = self.scaled(1024);
    var height = self.scaled(720);
    var x: c_int = win32.CW_USEDEFAULT;
    var y: c_int = win32.CW_USEDEFAULT;
    var work: win32.RECT = undefined;
    if (win32.exp.SystemParametersInfoW(win32.SPI_GETWORKAREA, 0, &work, 0) != win32.FALSE) {
        width = @min(width, @max(work.right - work.left - 80, 320));
        height = @min(height, @max(work.bottom - work.top - 80, 240));
        x = work.left + @divTrunc(work.right - work.left - width, 2);
        y = work.top + @divTrunc(work.bottom - work.top - height, 2);
    }
    self.hwnd = win32.exp.CreateWindowExW(
        0,
        class_name.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN,
        x,
        y,
        width,
        height,
        null,
        null,
        wc.hInstance,
        self,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = win32.exp.DestroyWindow(self.hwnd);
    self.dpi = win32.exp.GetDpiForWindow(self.hwnd);

    self.chrome.init(self.dpi);
}

pub fn deinit(self: *Window) void {
    self.close();
    self.tabs.deinit(self.app.core_app.alloc);
    self.chrome.deinit();
}

pub fn close(self: *Window) void {
    self.closing = true;
    if (win32.exp.IsWindow(self.hwnd) != win32.FALSE) _ = win32.exp.DestroyWindow(self.hwnd);
}

pub fn active(self: *Window) ?*rt.Surface {
    if (self.closing or self.tabs.items.len == 0) return null;
    return self.tabs.items[self.selected];
}

pub fn indexOf(self: *Window, surface: *rt.Surface) ?usize {
    for (self.tabs.items, 0..) |s, i| if (s == surface) return i;
    return null;
}

pub fn newTab(self: *Window) anyerror!void {
    if (self.closing) return;
    const alloc = self.app.core_app.alloc;
    try self.tabs.ensureUnusedCapacity(alloc, 1);
    try self.app.surfaces.ensureUnusedCapacity(alloc, 1);
    const surface = try alloc.create(rt.Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self.app, .{
        .window = self,
        .context = if (self.tabs.items.len == 0) .window else .tab,
    });
    errdefer surface.deinit();

    const index = self.tabs.items.len;
    self.tabs.appendAssumeCapacity(surface);
    self.app.surfaces.appendAssumeCapacity(surface);
    self.layout();
    self.activate(index);
}

/// Called only after wndProc and core mailbox dispatch have returned.
/// Keeping terminal allocations alive until then prevents callbacks from
/// using freed core state when a close action originates inside keyCallback.
pub fn removeTab(self: *Window, surface: *rt.Surface) void {
    const index = self.indexOf(surface) orelse return;
    _ = self.tabs.orderedRemove(index);
    self.selected = selectionAfterRemoval(self.tabs.items.len, self.selected, index);
    if (self.closing) return;
    if (self.tabs.items.len == 0) {
        self.close();
        return;
    }
    self.chrome.hover = .none;
    self.layout();
    self.activate(self.selected);
}

pub fn activate(self: *Window, index: usize) void {
    if (self.closing or index >= self.tabs.items.len) return;
    self.selected = index;
    for (self.tabs.items, 0..) |s, i| {
        const visible = i == index and !self.minimized;
        s.core_surface.occlusionCallback(visible) catch |err| log.warn("tab visibility err={}", .{err});
        _ = win32.exp.ShowWindow(s.hwnd, if (i == index) win32.SW_SHOW else win32.SW_HIDE);
    }
    self.titleChanged(self.tabs.items[index]);
    if (!self.minimized) _ = win32.exp.SetFocus(self.tabs.items[index].hwnd);
    _ = win32.exp.InvalidateRect(self.tabs.items[index].hwnd, null, win32.FALSE);
}

pub fn gotoTab(self: *Window, direction: apprt.action.GotoTab) void {
    if (tabDestination(self.tabs.items.len, self.selected, direction)) |index| self.activate(index);
}

pub fn moveTab(self: *Window, surface: *rt.Surface, amount: isize) void {
    const index = self.indexOf(surface) orelse return;
    const destination = moveDestination(self.tabs.items.len, index, amount);
    const active_surface = self.active();
    if (index < destination) {
        std.mem.copyForwards(*rt.Surface, self.tabs.items[index..destination], self.tabs.items[index + 1 .. destination + 1]);
    } else if (index > destination) {
        std.mem.copyBackwards(*rt.Surface, self.tabs.items[destination + 1 .. index + 1], self.tabs.items[destination..index]);
    }
    self.tabs.items[destination] = surface;
    self.selected = self.indexOf(active_surface orelse surface).?;
    self.chrome.hover = .none;
    self.activate(self.selected);
}

pub fn closeTabs(self: *Window, surface: *rt.Surface, mode: apprt.action.CloseTabMode) void {
    const index = self.indexOf(surface) orelse return;
    // Destruction only invalidates HWNDs here. The app removes/frees tabs
    // later, so this iteration remains stable even when closing many tabs.
    for (self.tabs.items, 0..) |s, i| {
        const should_close = switch (mode) {
            .this => i == index,
            .other => i != index,
            .right => i > index,
        };
        if (should_close) s.close(false);
    }
}

fn scaled(self: *const Window, value: u32) c_int {
    return @intCast((@as(u64, value) * self.dpi + 48) / 96);
}

pub fn showTabBar(self: *const Window) bool {
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => self.tabs.items.len > 1,
        .never => false,
    };
}

pub fn terminalRect(self: *Window) win32.RECT {
    var rect: win32.RECT = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 };
    _ = win32.exp.GetClientRect(self.hwnd, &rect);
    // The custom title bar remains available even when tabs are hidden.
    rect.top = self.scaled(40);
    return rect;
}

pub fn layout(self: *Window) void {
    if (self.closing) return;
    const rect = self.terminalRect();
    const width = @max(rect.right, 1);
    const height = @max(rect.bottom - rect.top, 1);
    Chrome.invalidate(self);
    for (self.tabs.items) |s| {
        _ = win32.exp.SetWindowPos(s.hwnd, null, 0, rect.top, width, height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    }
}

pub fn titleChanged(self: *Window, surface: *rt.Surface) void {
    if (self.closing) return;
    const index = self.indexOf(surface) orelse return;
    Chrome.invalidate(self);
    var buffer: [512]u16 = undefined;
    const title = surface.tab_title orelse surface.title orelse "Ghostty";
    const length = std.unicode.utf8ToUtf16Le(buffer[0 .. buffer.len - 1], title) catch return;
    buffer[length] = 0;
    if (index == self.selected) _ = win32.exp.SetWindowTextW(self.hwnd, buffer[0..length :0].ptr);
}

fn pointFromParam(param: win32.LPARAM) win32.POINT {
    const bits: usize = @bitCast(param);
    return .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
    };
}

fn nonClientHit(self: *Window, screen: win32.POINT) win32.LRESULT {
    var rect: win32.RECT = undefined;
    _ = win32.exp.GetWindowRect(self.hwnd, &rect);
    if (win32.exp.IsZoomed(self.hwnd) == win32.FALSE) {
        const border = @max(self.scaled(4), 2);
        const left = screen.x < rect.left + border;
        const right = screen.x >= rect.right - border;
        const top = screen.y < rect.top + border;
        const bottom = screen.y >= rect.bottom - border;
        if (left) return if (top) 13 else if (bottom) 16 else 10;
        if (right) return if (top) 14 else if (bottom) 17 else 11;
        if (top) return 12;
        if (bottom) return 15;
    }
    var point = screen;
    _ = win32.exp.ScreenToClient(self.hwnd, &point);
    return switch (self.chrome.hit(self, point.x, point.y)) {
        .minimize => win32.HTMINBUTTON,
        .maximize => win32.HTMAXBUTTON,
        .window_close => win32.HTCLOSE,
        .none => if (point.y >= 0 and point.y < self.scaled(40)) win32.HTCAPTION else win32.HTCLIENT,
        else => win32.HTCLIENT,
    };
}

fn mouseDown(self: *Window, hit: Chrome.Hit) void {
    self.chrome.pressed = hit;
    _ = win32.exp.SetCapture(self.hwnd);
    if (hit == .tab) self.activate(hit.tab);
    Chrome.invalidate(self);
}

fn mouseUp(self: *Window, hit: Chrome.Hit) void {
    const pressed = self.chrome.pressed;
    self.chrome.pressed = .none;
    _ = win32.exp.ReleaseCapture();
    if (!std.meta.eql(pressed, hit)) return;
    switch (hit) {
        .close => |index| if (index < self.tabs.items.len) self.tabs.items[index].close(false),
        .new_tab => self.newTab() catch |err| log.err("new tab err={}", .{err}),
        .dropdown => self.chrome.dropdown(self),
        .minimize => _ = win32.exp.PostMessageW(self.hwnd, win32.WM_SYSCOMMAND, win32.SC_MINIMIZE, 0),
        .maximize => _ = win32.exp.PostMessageW(self.hwnd, win32.WM_SYSCOMMAND, if (win32.exp.IsZoomed(self.hwnd) != win32.FALSE) win32.SC_RESTORE else win32.SC_MAXIMIZE, 0),
        .window_close => self.close(),
        else => {},
    }
    Chrome.invalidate(self);
}

fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const create: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *Window = @ptrCast(@alignCast(create.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = win32.exp.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(self)));
    }
    const pointer = win32.exp.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (pointer == 0) return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(pointer)));
    switch (msg) {
        0x0024 => { // WM_GETMINMAXINFO
            const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            info.min_track_size = .{ .x = self.scaled(360), .y = self.scaled(160) };
            return 0;
        },
        win32.WM_NCCALCSIZE => {
            // Keep the standard resizable/DWM window, but replace its
            // caption with our integrated tabs. Maximized windows retain
            // the invisible resize frame outside the monitor work area.
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const inset = if (win32.exp.IsZoomed(hwnd) != win32.FALSE) self.scaled(8) else 1;
            rect.left += inset;
            rect.right -= inset;
            rect.top += inset;
            rect.bottom -= inset;
            return 0;
        },
        win32.WM_NCHITTEST => return self.nonClientHit(pointFromParam(lparam)),
        win32.WM_PAINT => {
            self.chrome.paint(self);
            return 0;
        },
        0x0318 => { // WM_PRINTCLIENT
            self.chrome.draw(self, @ptrFromInt(wparam));
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_MOUSEMOVE, win32.WM_NCMOUSEMOVE => {
            var point = pointFromParam(lparam);
            if (msg == win32.WM_NCMOUSEMOVE) _ = win32.exp.ScreenToClient(hwnd, &point);
            self.chrome.setHover(self, self.chrome.hit(self, point.x, point.y));
            var track: win32.TRACKMOUSEEVENT = .{
                .dwFlags = win32.TME_LEAVE | (if (msg == win32.WM_NCMOUSEMOVE) win32.TME_NONCLIENT else @as(u32, 0)),
                .hwndTrack = hwnd,
            };
            _ = win32.exp.TrackMouseEvent(&track);
            // In particular, let Windows see HTMAXBUTTON mouse movement
            // so Windows 11 can offer its native snap-layout popup.
            return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_MOUSELEAVE, win32.WM_NCMOUSELEAVE => {
            self.chrome.setHover(self, .none);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const point = pointFromParam(lparam);
            self.mouseDown(self.chrome.hit(self, point.x, point.y));
            return 0;
        },
        0x00A1 => { // WM_NCLBUTTONDOWN
            const hit: Chrome.Hit = switch (wparam) {
                win32.HTMINBUTTON => .minimize,
                win32.HTMAXBUTTON => .maximize,
                win32.HTCLOSE => .window_close,
                else => return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam),
            };
            self.mouseDown(hit);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const point = pointFromParam(lparam);
            self.mouseUp(self.chrome.hit(self, point.x, point.y));
            return 0;
        },
        0x0215 => { // WM_CAPTURECHANGED
            self.chrome.pressed = .none;
            self.chrome.setHover(self, .none);
            return 0;
        },
        win32.WM_SIZE => {
            self.minimized = wparam == 1; // SIZE_MINIMIZED
            self.layout();
            if (self.tabs.items.len > 0) self.activate(self.selected);
            return 0;
        },
        win32.WM_DPICHANGED => {
            self.dpi = @intCast(wparam & 0xFFFF);
            self.chrome.updateDpi(self.dpi);
            for (self.tabs.items) |s| s.handleDpiChange(self.dpi);
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = win32.exp.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
            self.layout();
            return 0;
        },
        win32.WM_SETFOCUS => {
            if (self.active()) |s| _ = win32.exp.SetFocus(s.hwnd);
            return 0;
        },
        win32.WM_COMMAND => {
            if (wparam >> 16 == 0) switch (wparam & 0xFFFF) {
                new_button_id => self.newTab() catch |err| log.err("new tab err={}", .{err}),
                close_button_id => if (self.active()) |s| s.close(false),
                1003 => self.app.newWindow() catch |err| log.err("new window err={}", .{err}),
                1004 => if (self.active()) |s| self.closeTabs(s, .other),
                1005 => if (self.active()) |s| self.closeTabs(s, .right),
                else => {},
            };
            return 0;
        },
        win32.WM_CLOSE => {
            self.close();
            return 0;
        },
        win32.WM_NCDESTROY => {
            self.closing = true;
            _ = win32.exp.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            for (self.app.windows.items) |other| {
                if (other != self and !other.closing) return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            win32.exp.PostQuitMessage(0);
        },
        else => {},
    }
    return win32.exp.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn tabDestination(count: usize, selected: usize, direction: apprt.action.GotoTab) ?usize {
    if (count == 0) return null;
    return switch (direction) {
        .previous => if (selected == 0) count - 1 else selected - 1,
        .next => (selected + 1) % count,
        .last => count - 1,
        // The binding protocol uses 1-based indices; out-of-range jumps
        // select the last tab, matching the other application runtimes.
        else => if (@intFromEnum(direction) > 0)
            @min(@as(usize, @intCast(@intFromEnum(direction))) - 1, count - 1)
        else
            null,
    };
}

fn selectionAfterRemoval(count: usize, selected: usize, removed: usize) usize {
    if (count == 0) return 0;
    return @min(if (removed < selected) selected - 1 else selected, count - 1);
}

fn moveDestination(count: usize, index: usize, amount: isize) usize {
    if (count == 0) return 0;
    const n: isize = @intCast(count);
    return @intCast(@mod(@as(isize, @intCast(index)) + @mod(amount, n), n));
}

test "win32 tabs selection and removal" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, null), tabDestination(0, 0, .next));
    try t.expectEqual(@as(?usize, 2), tabDestination(3, 0, .previous));
    try t.expectEqual(@as(?usize, 0), tabDestination(3, 2, .next));
    try t.expectEqual(@as(?usize, 2), tabDestination(3, 0, .last));
    try t.expectEqual(@as(?usize, 0), tabDestination(3, 2, @enumFromInt(1)));
    try t.expectEqual(@as(?usize, 2), tabDestination(3, 0, @enumFromInt(9)));
    try t.expectEqual(@as(?usize, null), tabDestination(3, 0, @enumFromInt(0)));
    try t.expectEqual(@as(usize, 0), selectionAfterRemoval(0, 0, 0));
    try t.expectEqual(@as(usize, 1), selectionAfterRemoval(2, 2, 0));
    try t.expectEqual(@as(usize, 1), selectionAfterRemoval(2, 1, 1));
    try t.expectEqual(@as(usize, 0), selectionAfterRemoval(2, 0, 2));
}

test "win32 tabs move wraps" {
    try std.testing.expectEqual(@as(usize, 2), moveDestination(3, 0, -1));
    try std.testing.expectEqual(@as(usize, 0), moveDestination(3, 2, 1));
    try std.testing.expectEqual(@as(usize, 1), moveDestination(3, 0, std.math.minInt(isize)));
    try std.testing.expectEqual(@as(usize, 0), moveDestination(1, 0, 100));
}
