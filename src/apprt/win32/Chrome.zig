//! Windows Terminal-style, DPI-aware tabs integrated into the title bar.
//! Uses the system's Segoe UI font and PowerShell icon, not terminal fonts.
const Chrome = @This();
const std = @import("std");
const w = @import("../../os/win32.zig");
const Window = @import("Window.zig");

regular: ?w.HANDLE = null,
bold: ?w.HANDLE = null,
icon: ?w.HICON = null,
hover: Hit = .none,
pressed: Hit = .none,
first: usize = 0,

pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    new_tab,
    dropdown,
    minimize,
    maximize,
    window_close,
};

pub const Layout = struct {
    height: i32,
    width: i32,
    tab_width: i32,
    first: usize,
    visible: usize,
    left: i32,
    controls: i32,
    add: i32,
    button: i32,
    caption_button: i32,
};

pub fn scale(dpi: u32, value: i32) i32 {
    return @intCast(@divTrunc(@as(i64, value) * dpi, 96));
}

pub fn geometry(width: i32, dpi: u32, count: usize, selected: usize, old_first: usize) Layout {
    const left = scale(dpi, 10);
    const button = scale(dpi, 32);
    const caption_button = scale(dpi, 46);
    const controls = @max(width - caption_button * 3, 0);
    const available = @max(controls - left - button * 2 - scale(dpi, 8), 1);
    const tab_width = if (count == 0) scale(dpi, 240) else std.math.clamp(
        @divTrunc(available, @as(i32, @intCast(@min(count, 100000)))),
        scale(dpi, 96),
        scale(dpi, 240),
    );
    const visible = @min(count, @as(usize, @intCast(@max(@divTrunc(available, tab_width), 1))));
    var first = @min(old_first, count -| visible);
    if (visible > 0) {
        if (selected < first) first = selected;
        if (selected >= first + visible) first = selected - visible + 1;
    }
    return .{
        .height = scale(dpi, 40),
        .width = width,
        .tab_width = tab_width,
        .first = first,
        .visible = visible,
        .left = left,
        .controls = controls,
        .add = left + @as(i32, @intCast(visible)) * tab_width + scale(dpi, 6),
        .button = button,
        .caption_button = caption_button,
    };
}

pub fn init(self: *Chrome, dpi: u32) void {
    self.updateDpi(dpi);
    var path: [512]u16 = undefined;
    const n = w.exp.GetWindowsDirectoryW(&path, path.len);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    if (n > 0 and n + suffix.len < path.len) {
        @memcpy(path[n..][0..suffix.len], suffix);
        path[n + suffix.len] = 0;
        _ = w.exp.ExtractIconExW(path[0 .. n + suffix.len :0].ptr, 0, &self.icon, null, 1);
    }
}

pub fn updateDpi(self: *Chrome, dpi: u32) void {
    if (self.regular) |font| _ = w.exp.DeleteObject(font);
    if (self.bold) |font| _ = w.exp.DeleteObject(font);
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
    self.regular = w.exp.CreateFontW(-scale(dpi, 12), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, face);
    self.bold = w.exp.CreateFontW(-scale(dpi, 12), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, face);
}

pub fn deinit(self: *Chrome) void {
    if (self.regular) |font| _ = w.exp.DeleteObject(font);
    if (self.bold) |font| _ = w.exp.DeleteObject(font);
    if (self.icon) |icon| _ = w.exp.DestroyIcon(icon);
    self.* = .{};
}

pub fn layout(self: *Chrome, window: *Window) Layout {
    var rect: w.RECT = undefined;
    _ = w.exp.GetClientRect(window.hwnd, &rect);
    const result = geometry(rect.right, window.dpi, if (window.showTabBar()) window.tabs.items.len else 0, window.selected, self.first);
    self.first = result.first;
    return result;
}

pub fn invalidate(window: *Window) void {
    if (window.closing) return;
    var rect: w.RECT = undefined;
    _ = w.exp.GetClientRect(window.hwnd, &rect);
    rect.bottom = scale(window.dpi, 40);
    _ = w.exp.InvalidateRect(window.hwnd, &rect, w.FALSE);
}

pub fn hit(self: *Chrome, window: *Window, x: i32, y: i32) Hit {
    const g = self.layout(window);
    if (y < 0 or y >= g.height or x < 0 or x >= g.width) return .none;
    if (x >= g.width - g.caption_button) return .window_close;
    if (x >= g.width - g.caption_button * 2) return .maximize;
    if (x >= g.controls) return .minimize;
    if (!window.showTabBar()) return .none;
    if (x >= g.left and x < g.left + @as(i32, @intCast(g.visible)) * g.tab_width and y >= scale(window.dpi, 8)) {
        const slot: usize = @intCast(@divTrunc(x - g.left, g.tab_width));
        const right = g.left + @as(i32, @intCast(slot + 1)) * g.tab_width;
        if (x >= right - scale(window.dpi, 32)) return .{ .close = g.first + slot };
        return .{ .tab = g.first + slot };
    }
    if (x >= g.add and x < @min(g.add + g.button, g.controls)) return .new_tab;
    if (x >= g.add + g.button and x < @min(g.add + 2 * g.button, g.controls)) return .dropdown;
    return .none;
}

pub fn setHover(self: *Chrome, window: *Window, value: Hit) void {
    if (std.meta.eql(self.hover, value)) return;
    self.hover = value;
    invalidate(window);
}

fn rgb(r: u8, g: u8, b: u8) w.DWORD {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

fn fill(dc: w.HDC, rect: w.RECT, color: w.DWORD) void {
    const brush = w.exp.CreateSolidBrush(color) orelse return;
    defer _ = w.exp.DeleteObject(@ptrCast(brush));
    _ = w.exp.FillRect(dc, &rect, brush);
}

fn round(dc: w.HDC, rect: w.RECT, radius: i32, color: w.DWORD) void {
    const brush = w.exp.CreateSolidBrush(color) orelse return;
    defer _ = w.exp.DeleteObject(@ptrCast(brush));
    const old_brush = w.exp.SelectObject(dc, @ptrCast(brush));
    defer {
        if (old_brush) |old| _ = w.exp.SelectObject(dc, old);
    }
    const old_pen = w.exp.SelectObject(dc, w.exp.GetStockObject(w.NULL_PEN) orelse return);
    defer {
        if (old_pen) |old| _ = w.exp.SelectObject(dc, old);
    }
    _ = w.exp.RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
}

fn line(dc: w.HDC, x: i32, y: i32, x2: i32, y2: i32) void {
    _ = w.exp.MoveToEx(dc, x, y, null);
    _ = w.exp.LineTo(dc, x2, y2);
}

fn cross(dc: w.HDC, x: i32, y: i32, size: i32) void {
    line(dc, x - size, y - size, x + size + 1, y + size + 1);
    line(dc, x + size, y - size, x - size - 1, y + size + 1);
}

fn text(dc: w.HDC, font: ?w.HANDLE, title: []const u8, rect_value: w.RECT) void {
    var buffer: [512]u16 = undefined;
    // Bound conversion without cutting a UTF-8 codepoint. DrawText adds
    // the visual ellipsis; long OSC titles must not make the label vanish.
    var bytes = @min(title.len, buffer.len - 1);
    while (bytes < title.len and bytes > 0 and title[bytes] & 0xC0 == 0x80) bytes -= 1;
    const n = std.unicode.utf8ToUtf16Le(buffer[0 .. buffer.len - 1], title[0..bytes]) catch return;
    buffer[n] = 0;
    var rect = rect_value;
    const old = if (font) |f| w.exp.SelectObject(dc, f) else null;
    defer {
        if (old) |f| _ = w.exp.SelectObject(dc, f);
    }
    _ = w.exp.DrawTextW(dc, buffer[0..n :0].ptr, @intCast(n), &rect, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_END_ELLIPSIS | w.DT_NOPREFIX);
}

pub fn paint(self: *Chrome, window: *Window) void {
    var ps: w.PAINTSTRUCT = undefined;
    const dc = w.exp.BeginPaint(window.hwnd, &ps) orelse return;
    defer _ = w.exp.EndPaint(window.hwnd, &ps);
    self.draw(window, dc);
}

/// Also used by WM_PRINTCLIENT, so screenshots/accessibility tooling can
/// render the header without bringing the terminal to the foreground.
pub fn draw(self: *Chrome, window: *Window, dc: w.HDC) void {
    const g = self.layout(window);
    const dpi = window.dpi;
    const white = rgb(255, 255, 255);
    const background = rgb(232, 232, 232);
    fill(dc, .{ .left = 0, .top = 0, .right = g.width, .bottom = g.height }, background);
    _ = w.exp.SetBkMode(dc, w.TRANSPARENT);
    _ = w.exp.SetTextColor(dc, rgb(15, 15, 15));
    const pen = w.exp.CreatePen(0, @max(scale(dpi, 1), 1), rgb(25, 25, 25)) orelse return;
    defer _ = w.exp.DeleteObject(pen);
    const old_pen = w.exp.SelectObject(dc, pen);
    defer {
        if (old_pen) |old| _ = w.exp.SelectObject(dc, old);
    }
    const top = scale(dpi, 9);
    const center_y = @divTrunc(top + g.height, 2);
    const small = scale(dpi, 4);

    for (0..g.visible) |slot| {
        const index = g.first + slot;
        const surface = window.tabs.items[index];
        const left = g.left + @as(i32, @intCast(slot)) * g.tab_width;
        const right = left + g.tab_width;
        const active = index == window.selected;
        const hovered = std.meta.eql(self.hover, .{ .tab = index }) or std.meta.eql(self.hover, .{ .close = index });
        if (active or hovered) {
            const color = if (active) white else rgb(242, 242, 242);
            round(dc, .{ .left = left, .top = top, .right = right, .bottom = g.height + scale(dpi, 8) }, scale(dpi, 16), color);
            fill(dc, .{ .left = left, .top = g.height - scale(dpi, 8), .right = right, .bottom = g.height }, color);
        }
        const icon_size = scale(dpi, 16);
        if (self.icon) |icon| {
            _ = w.exp.DrawIconEx(dc, left + scale(dpi, 10), center_y - @divTrunc(icon_size, 2), icon, icon_size, icon_size, 0, null, w.DI_NORMAL);
        }
        text(dc, if (active) self.bold else self.regular, surface.tab_title orelse surface.title orelse "Windows PowerShell", .{
            .left = left + scale(dpi, 36),
            .top = top,
            .right = right - scale(dpi, 36),
            .bottom = g.height,
        });
        const x = right - scale(dpi, 20);
        if (std.meta.eql(self.hover, .{ .close = index })) round(dc, .{
            .left = x - scale(dpi, 11),
            .top = center_y - scale(dpi, 11),
            .right = x + scale(dpi, 11),
            .bottom = center_y + scale(dpi, 11),
        }, scale(dpi, 8), rgb(219, 219, 219));
        cross(dc, x, center_y, small);
    }
    if (!window.showTabBar()) {
        if (window.active()) |surface| text(dc, self.regular, surface.title orelse "Ghostty", .{
            .left = scale(dpi, 16),
            .top = 0,
            .right = g.controls,
            .bottom = g.height,
        });
    } else {
        for ([_]Hit{ .new_tab, .dropdown }, 0..) |button, i| {
            const x = g.add + @as(i32, @intCast(i)) * g.button;
            if (x + g.button > g.controls) continue;
            if (std.meta.eql(self.hover, button)) round(dc, .{
                .left = x + scale(dpi, 2),
                .top = scale(dpi, 7),
                .right = x + g.button - scale(dpi, 2),
                .bottom = g.height - scale(dpi, 5),
            }, scale(dpi, 8), rgb(216, 216, 216));
            const cx = x + @divTrunc(g.button, 2);
            if (i == 0) {
                line(dc, cx - scale(dpi, 5), center_y, cx + scale(dpi, 5) + 1, center_y);
                line(dc, cx, center_y - scale(dpi, 5), cx, center_y + scale(dpi, 5) + 1);
            } else {
                line(dc, cx - small, center_y - scale(dpi, 2), cx, center_y + scale(dpi, 2));
                line(dc, cx, center_y + scale(dpi, 2), cx + small + 1, center_y - scale(dpi, 2) - 1);
            }
        }
    }
    for ([_]Hit{ .minimize, .maximize, .window_close }, 0..) |button, i| {
        const x = g.controls + @as(i32, @intCast(i)) * g.caption_button;
        const cx = x + @divTrunc(g.caption_button, 2);
        const cy = @divTrunc(g.height, 2);
        const hovered = std.meta.eql(self.hover, button);
        if (hovered) fill(dc, .{ .left = x, .top = 0, .right = x + g.caption_button, .bottom = g.height }, if (i == 2) rgb(196, 43, 28) else rgb(215, 215, 215));
        switch (i) {
            0 => line(dc, cx - small, cy, cx + small + 1, cy),
            1 => {
                const offset = if (w.exp.IsZoomed(window.hwnd) != w.FALSE) scale(dpi, 2) else 0;
                if (offset > 0) {
                    line(dc, cx - small + offset, cy - small - offset, cx + small + offset, cy - small - offset);
                    line(dc, cx + small + offset, cy - small - offset, cx + small + offset, cy + small - offset);
                }
                line(dc, cx - small, cy - small, cx + small + 1, cy - small);
                line(dc, cx + small, cy - small, cx + small, cy + small + 1);
                line(dc, cx + small, cy + small, cx - small - 1, cy + small);
                line(dc, cx - small, cy + small, cx - small, cy - small - 1);
            },
            2 => {
                const white_pen = if (hovered) w.exp.CreatePen(0, @max(scale(dpi, 1), 1), white) else null;
                if (white_pen) |p| {
                    _ = w.exp.SelectObject(dc, p);
                    cross(dc, cx, cy, small);
                    _ = w.exp.SelectObject(dc, pen);
                    _ = w.exp.DeleteObject(p);
                } else cross(dc, cx, cy, small);
            },
            else => unreachable,
        }
    }
}

pub fn dropdown(self: *Chrome, window: *Window) void {
    const menu = w.exp.CreatePopupMenu() orelse return;
    defer _ = w.exp.DestroyMenu(menu);
    _ = w.exp.AppendMenuW(menu, w.MF_STRING, 1001, std.unicode.utf8ToUtf16LeStringLiteral("New tab\tCtrl+Shift+T"));
    _ = w.exp.AppendMenuW(menu, w.MF_STRING, 1003, std.unicode.utf8ToUtf16LeStringLiteral("New window\tCtrl+Shift+N"));
    _ = w.exp.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    _ = w.exp.AppendMenuW(menu, w.MF_STRING, 1004, std.unicode.utf8ToUtf16LeStringLiteral("Close other tabs"));
    _ = w.exp.AppendMenuW(menu, w.MF_STRING, 1005, std.unicode.utf8ToUtf16LeStringLiteral("Close tabs to the right"));
    const g = self.layout(window);
    var point: w.POINT = .{ .x = g.add + g.button, .y = g.height };
    _ = w.exp.ClientToScreen(window.hwnd, &point);
    const id = w.exp.TrackPopupMenuEx(menu, w.TPM_RETURNCMD, point.x, point.y, window.hwnd, null);
    if (id != 0) _ = w.exp.PostMessageW(window.hwnd, w.WM_COMMAND, id, 0);
    self.setHover(window, .none);
}

test "win32 tabs chrome geometry and overflow" {
    const t = std.testing;
    const normal = geometry(1600, 144, 2, 1, 0);
    try t.expectEqual(@as(i32, 60), normal.height);
    try t.expectEqual(@as(i32, 360), normal.tab_width);
    try t.expectEqual(@as(usize, 2), normal.visible);
    const crowded = geometry(800, 144, 20, 19, 0);
    try t.expect(crowded.visible > 0 and crowded.visible < 20);
    try t.expect(crowded.first + crowded.visible == 20);
    const back = geometry(800, 144, 20, 0, crowded.first);
    try t.expectEqual(@as(usize, 0), back.first);
    const empty = geometry(800, 144, 0, 0, 0);
    try t.expectEqual(@as(usize, 0), empty.visible);
}
