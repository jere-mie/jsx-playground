const std = @import("std");

pub const InputMode = enum {
    html,
    jsx,
};

pub const RenderOptions = struct {
    source_name: []const u8 = "app.jsx",
    live_reload_path: ?[]const u8 = null,
};

pub fn detectInputMode(raw_code: []const u8) InputMode {
    const trimmed = trimAsciiStart(stripBom(raw_code));
    if (startsWithIgnoreCase(trimmed, "<!doctype html") or startsWithIgnoreCase(trimmed, "<html")) {
        return .html;
    }

    return .jsx;
}

pub fn isJsxLikeExtension(path: []const u8) bool {
    return eqlExtension(path, ".jsx") or
        eqlExtension(path, ".tsx") or
        eqlExtension(path, ".js") or
        eqlExtension(path, ".ts");
}

pub fn isHtmlExtension(path: []const u8) bool {
    return eqlExtension(path, ".html") or eqlExtension(path, ".htm");
}

pub fn isRenderableExtension(path: []const u8) bool {
    return isJsxLikeExtension(path) or isHtmlExtension(path);
}

pub fn renderDocument(
    allocator: std.mem.Allocator,
    raw_code: []const u8,
    options: RenderOptions,
) ![]u8 {
    return switch (detectInputMode(raw_code)) {
        .html => renderHtmlDocument(allocator, raw_code, options.live_reload_path),
        .jsx => renderJsxDocument(allocator, raw_code, options),
    };
}

pub fn renderHtmlDocument(
    allocator: std.mem.Allocator,
    raw_html: []const u8,
    live_reload_path: ?[]const u8,
) ![]u8 {
    if (live_reload_path == null) {
        return allocator.dupe(u8, raw_html);
    }

    const snippet = try buildLiveReloadSnippet(allocator, live_reload_path.?);
    defer allocator.free(snippet);

    return try injectHtmlSnippet(allocator, raw_html, snippet);
}

fn renderJsxDocument(
    allocator: std.mem.Allocator,
    raw_code: []const u8,
    options: RenderOptions,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8" />
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\<link rel="icon" href="data:," />
        \\<title>
    );
    try appendEscapedHtml(&output, allocator, options.source_name);
    try output.appendSlice(allocator,
        \\</title>
        \\<script src="https://cdn.tailwindcss.com"></script>
        \\<script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
        \\<script type="importmap">
        \\{
        \\  "imports": {
        \\    "react":                  "https://esm.sh/react@18?dev",
        \\    "react/jsx-runtime":      "https://esm.sh/react@18/jsx-runtime?dev",
        \\    "react/jsx-dev-runtime":  "https://esm.sh/react@18/jsx-dev-runtime?dev",
        \\    "react-dom":              "https://esm.sh/react-dom@18?dev&deps=react@18.3.1",
        \\    "react-dom/client":       "https://esm.sh/react-dom@18/client?dev&deps=react@18.3.1",
        \\    "lucide-react":           "https://esm.sh/lucide-react@0.511.0?deps=react@18.3.1",
        \\    "framer-motion":          "https://esm.sh/framer-motion?deps=react@18.3.1",
        \\    "recharts":               "https://esm.sh/recharts?deps=react@18.3.1,react-dom@18.3.1",
        \\    "react-hook-form":        "https://esm.sh/react-hook-form?deps=react@18.3.1",
        \\    "zod":                    "https://esm.sh/zod",
        \\    "zustand":                "https://esm.sh/zustand?deps=react@18.3.1",
        \\    "zustand/middleware":     "https://esm.sh/zustand/middleware?deps=react@18.3.1",
        \\    "@tanstack/react-query":  "https://esm.sh/@tanstack/react-query?deps=react@18.3.1",
        \\    "clsx":                   "https://esm.sh/clsx",
        \\    "tailwind-merge":         "https://esm.sh/tailwind-merge",
        \\    "date-fns":               "https://esm.sh/date-fns",
        \\    "immer":                  "https://esm.sh/immer"
        \\  }
        \\}
        \\</script>
        \\<style>
        \\  body{margin:0;min-height:100vh;background:#f8fafc;color:#0f172a;font-family:Inter,system-ui,sans-serif;}
        \\  #root{min-height:100vh;}
        \\  pre[data-error]{margin:0;padding:18px 20px;white-space:pre-wrap;color:#991b1b;background:#fef2f2;border:1px solid #fecaca;border-radius:12px;font:13px/1.6 ui-monospace,SFMono-Regular,Consolas,monospace;}
        \\</style>
        \\</head>
        \\<body>
        \\<div id="root"></div>
        \\<script type="module">
        \\import React from 'react';
        \\import { createRoot } from 'react-dom/client';
        \\const rootEl = document.getElementById('root');
        \\const rawSource = 
    );
    try appendJsStringLiteral(&output, allocator, raw_code);
    try output.appendSlice(allocator,
        \\;
        \\const sourceName = 
    );
    try appendJsStringLiteral(&output, allocator, options.source_name);
    try output.appendSlice(allocator,
        \\;
        \\function escapeHtml(value) {
        \\  return String(value)
        \\    .replace(/&/g, '&amp;')
        \\    .replace(/</g, '&lt;')
        \\    .replace(/>/g, '&gt;');
        \\}
        \\function showError(error) {
        \\  const message = error instanceof Error ? error.message : String(error);
        \\  rootEl.innerHTML = '<pre data-error>' + escapeHtml(message) + '</pre>';
        \\}
        \\function buildModuleSource(source, filename) {
        \\  const presets = /\.tsx?$/i.test(filename)
        \\    ? ['typescript', ['react', { runtime: 'automatic' }]]
        \\    : [['react', { runtime: 'automatic' }]];
        \\  const compiled = window.Babel.transform(source, {
        \\    filename,
        \\    presets,
        \\    sourceType: 'module',
        \\  }).code;
        \\  const hasDefaultExport = /\bexport\s+default\b/.test(source);
        \\  const fallbackExport = hasDefaultExport
        \\    ? ''
        \\    : '\\nconst __jsxccFallbackDefault = typeof App !== "undefined" ? App : undefined;\\nexport default __jsxccFallbackDefault;\\n';
        \\  return compiled + fallbackExport;
        \\}
        \\window.addEventListener('error', (event) => {
        \\  if (event.error || event.message) {
        \\    showError(event.error || event.message);
        \\  }
        \\});
        \\window.addEventListener('unhandledrejection', (event) => {
        \\  showError(event.reason || 'Unhandled rejection');
        \\});
        \\async function boot() {
        \\  try {
        \\    const moduleSource = buildModuleSource(rawSource, sourceName);
        \\    const blobUrl = URL.createObjectURL(new Blob([moduleSource], { type: 'text/javascript' }));
        \\    try {
        \\      const mod = await import(blobUrl);
        \\      if (!mod.default) {
        \\        throw new Error('No default export found. Export a React component or define App().');
        \\      }
        \\      const root = createRoot(rootEl);
        \\      const exported = mod.default;
        \\      root.render(React.isValidElement(exported) ? exported : React.createElement(exported));
        \\    } finally {
        \\      URL.revokeObjectURL(blobUrl);
        \\    }
        \\  } catch (error) {
        \\    showError(error);
        \\  }
        \\}
        \\boot();
        \\</script>
    );

    if (options.live_reload_path) |watch_path| {
        const snippet = try buildLiveReloadSnippet(allocator, watch_path);
        defer allocator.free(snippet);
        try output.appendSlice(allocator, snippet);
    }

    try output.appendSlice(allocator,
        \\</body>
        \\</html>
    );

    return output.toOwnedSlice(allocator);
}

fn buildLiveReloadSnippet(allocator: std.mem.Allocator, watch_path: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator,
        \\<script>
        \\(function() {
        \\  const watchPath = 
    );
    try appendJsStringLiteral(&output, allocator, watch_path);
    try output.appendSlice(allocator,
        \\;
        \\  let currentToken = null;
        \\  async function poll() {
        \\    try {
        \\      const endpoint = new URL('/__jsxcc/live', window.location.origin);
        \\      endpoint.searchParams.set('path', watchPath);
        \\      const response = await fetch(endpoint, { cache: 'no-store' });
        \\      if (response.ok) {
        \\        const nextToken = await response.text();
        \\        if (currentToken === null) {
        \\          currentToken = nextToken;
        \\        } else if (nextToken !== currentToken) {
        \\          window.location.reload();
        \\          return;
        \\        }
        \\      }
        \\    } catch (_) {}
        \\    window.setTimeout(poll, 1000);
        \\  }
        \\  poll();
        \\})();
        \\</script>
    );

    return output.toOwnedSlice(allocator);
}

fn injectHtmlSnippet(
    allocator: std.mem.Allocator,
    html: []const u8,
    snippet: []const u8,
) ![]u8 {
    if (lastIndexOfIgnoreCase(html, "</body>")) |index| {
        return try spliceBytes(allocator, html, index, snippet);
    }
    if (lastIndexOfIgnoreCase(html, "</html>")) |index| {
        return try spliceBytes(allocator, html, index, snippet);
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, html);
    try output.appendSlice(allocator, "\n");
    try output.appendSlice(allocator, snippet);
    return output.toOwnedSlice(allocator);
}

fn spliceBytes(
    allocator: std.mem.Allocator,
    original: []const u8,
    index: usize,
    inserted: []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, original[0..index]);
    try output.appendSlice(allocator, inserted);
    try output.appendSlice(allocator, original[index..]);
    return output.toOwnedSlice(allocator);
}

fn appendEscapedHtml(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) !void {
    for (input) |char| {
        switch (char) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&#39;"),
            else => try output.append(allocator, char),
        }
    }
}

fn appendJsStringLiteral(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) !void {
    try output.append(allocator, '"');
    for (input) |char| {
        switch (char) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '"' => try output.appendSlice(allocator, "\\\""),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            '<' => try output.appendSlice(allocator, "\\u003C"),
            else => {
                if (char < 32) {
                    const escaped = try std.fmt.allocPrint(allocator, "\\u{X:0>4}", .{char});
                    defer allocator.free(escaped);
                    try output.appendSlice(allocator, escaped);
                } else {
                    try output.append(allocator, char);
                }
            },
        }
    }
    try output.append(allocator, '"');
}

fn stripBom(bytes: []const u8) []const u8 {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) {
        return bytes[3..];
    }
    return bytes;
}

fn trimAsciiStart(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index < bytes.len and std.ascii.isWhitespace(bytes[index])) : (index += 1) {}
    return bytes[index..];
}

fn eqlExtension(path: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), expected);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;

    var index = haystack.len - needle.len;
    while (true) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) {
            return index;
        }
        if (index == 0) break;
        index -= 1;
    }

    return null;
}

test "detect input mode recognizes raw html" {
    try std.testing.expectEqual(.html, detectInputMode(" \n<!DOCTYPE html><html></html>"));
    try std.testing.expectEqual(.html, detectInputMode("<html><body></body></html>"));
    try std.testing.expectEqual(.jsx, detectInputMode("export default function App() { return <div />; }"));
}

test "rendered jsx document includes runtime compiler and source" {
    const html = try renderDocument(std.testing.allocator, "export default function App(){return <div>Hello</div>;}", .{
        .source_name = "App.jsx",
    });
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "window.Babel.transform") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "react/jsx-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\\u003Cdiv>Hello\\u003C/div>") != null);
}

test "html passthrough injects live reload before body close" {
    const html = try renderHtmlDocument(std.testing.allocator, "<html><body><h1>Hello</h1></body></html>", "/demo.jsx");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "watchPath = \"/demo.jsx\"") != null);
    const body_close = std.mem.lastIndexOf(u8, html, "</body>").?;
    const script_index = std.mem.indexOf(u8, html, "<script>").?;
    try std.testing.expect(script_index < body_close);
}
