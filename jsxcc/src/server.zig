const std = @import("std");
const http = std.http;
const renderer = @import("renderer.zig");

pub const ServerOptions = struct {
    allocator: std.mem.Allocator,
    target_path: []const u8,
    host: []const u8 = "127.0.0.1",
    requested_port: u16 = 4173,
};

pub const TargetKind = enum {
    file,
    directory,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    target_path: []const u8,
    target_kind: TargetKind,
    host: []const u8,
    port: u16,
    listener: std.net.Server,

    pub fn init(options: ServerOptions) !Server {
        const target_path = try std.fs.cwd().realpathAlloc(options.allocator, options.target_path);
        errdefer options.allocator.free(target_path);

        const target_kind = try detectTargetKind(target_path);
        const host = try options.allocator.dupe(u8, options.host);
        errdefer options.allocator.free(host);

        const bind_result = try bindListener(host, options.requested_port);
        return .{
            .allocator = options.allocator,
            .target_path = target_path,
            .target_kind = target_kind,
            .host = host,
            .port = bind_result.port,
            .listener = bind_result.listener,
        };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
        self.allocator.free(self.target_path);
        self.allocator.free(self.host);
    }

    pub fn serve(self: *Server) !void {
        while (true) {
            const connection = self.listener.accept() catch |err| switch (err) {
                error.ConnectionAborted,
                error.ConnectionResetByPeer,
                => continue,
                else => return err,
            };
            self.handleConnection(connection) catch |err| {
                std.debug.print("jsxcc serve: {s}\n", .{@errorName(err)});
            };
        }
    }

    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        var send_buffer: [4096]u8 = undefined;
        var recv_buffer: [4096]u8 = undefined;
        var connection_reader = connection.stream.reader(&recv_buffer);
        var connection_writer = connection.stream.writer(&send_buffer);
        var http_server: http.Server = .init(connection_reader.interface(), &connection_writer.interface);

        while (true) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => {
                    std.debug.print("jsxcc serve receiveHead failed: {s}\n", .{@errorName(err)});
                    return err;
                },
            };

            if (request.head.method != .GET and request.head.method != .HEAD) {
                try self.respond(&request, .method_not_allowed, "text/plain; charset=utf-8", "Method Not Allowed\n");
                continue;
            }

            const target = parseTarget(request.head.target) catch {
                try self.respond(&request, .bad_request, "text/plain; charset=utf-8", "Bad Request\n");
                continue;
            };

            if (std.mem.eql(u8, target.path, "/__jsxcc/live")) {
                const query = target.query orelse "";
                const watched_path = try getQueryParam(self.allocator, query, "path");
                defer if (watched_path) |value| self.allocator.free(value);
                if (watched_path == null) {
                    try self.respond(&request, .bad_request, "text/plain; charset=utf-8", "Missing path query parameter\n");
                    continue;
                }

                const watched_source = self.resolveLogicalPath(watched_path.?) catch {
                    try self.respond(&request, .not_found, "text/plain; charset=utf-8", "Not Found\n");
                    continue;
                };
                defer self.allocator.free(watched_source);

                const token = try buildWatchToken(self.allocator, watched_source);
                defer self.allocator.free(token);

                try self.respond(&request, .ok, "text/plain; charset=utf-8", token);
                continue;
            }

            const resolved_path = self.resolveLogicalPath(target.path) catch {
                try self.respond(&request, .not_found, "text/plain; charset=utf-8", "Not Found\n");
                continue;
            };
            defer self.allocator.free(resolved_path);

            if (isDirectoryPath(resolved_path)) {
                const listing = self.renderDirectoryListing(target.path, resolved_path) catch |err| {
                    std.debug.print("jsxcc serve directory listing failed for {s}: {s}\n", .{ resolved_path, @errorName(err) });
                    try self.respond(&request, .internal_server_error, "text/plain; charset=utf-8", "Internal Server Error\n");
                    continue;
                };
                defer self.allocator.free(listing);

                try self.respond(&request, .ok, "text/html; charset=utf-8", listing);
                continue;
            }

            if (renderer.isRenderableExtension(resolved_path)) {
                const source = std.fs.cwd().readFileAlloc(self.allocator, resolved_path, max_file_size) catch |err| {
                    switch (err) {
                        error.FileNotFound => try self.respond(&request, .not_found, "text/plain; charset=utf-8", "Not Found\n"),
                        else => {
                            std.debug.print("jsxcc serve read source failed for {s}: {s}\n", .{ resolved_path, @errorName(err) });
                            try self.respond(&request, .internal_server_error, "text/plain; charset=utf-8", "Internal Server Error\n");
                        },
                    }
                    continue;
                };
                defer self.allocator.free(source);

                const html_doc = renderer.renderDocument(self.allocator, source, .{
                    .source_name = std.fs.path.basename(resolved_path),
                    .live_reload_path = target.path,
                }) catch |err| {
                    std.debug.print("jsxcc serve render failed for {s}: {s}\n", .{ resolved_path, @errorName(err) });
                    try self.respond(&request, .internal_server_error, "text/plain; charset=utf-8", "Internal Server Error\n");
                    continue;
                };
                defer self.allocator.free(html_doc);

                try self.respond(&request, .ok, "text/html; charset=utf-8", html_doc);
                continue;
            }

            const file_bytes = std.fs.cwd().readFileAlloc(self.allocator, resolved_path, max_file_size) catch |err| {
                switch (err) {
                    error.FileNotFound => try self.respond(&request, .not_found, "text/plain; charset=utf-8", "Not Found\n"),
                    else => {
                        std.debug.print("jsxcc serve read static file failed for {s}: {s}\n", .{ resolved_path, @errorName(err) });
                        try self.respond(&request, .internal_server_error, "text/plain; charset=utf-8", "Internal Server Error\n");
                    },
                }
                continue;
            };
            defer self.allocator.free(file_bytes);

            try self.respond(&request, .ok, contentTypeForPath(resolved_path), file_bytes);
        }
    }

    fn respond(
        _: *Server,
        request: *http.Server.Request,
        status: http.Status,
        content_type: []const u8,
        body: []const u8,
    ) !void {
        var headers = [_]http.Header{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-store" },
        };

        try request.respond(body, .{
            .status = status,
            .extra_headers = &headers,
        });
    }

    pub fn resolveLogicalPath(self: *Server, logical_path: []const u8) ![]u8 {
        if (self.target_kind == .file) {
            if (std.mem.eql(u8, logical_path, "/") or std.mem.eql(u8, logical_path, "")) {
                return self.allocator.dupe(u8, self.target_path);
            }

            var expected: std.ArrayList(u8) = .empty;
            defer expected.deinit(self.allocator);
            try expected.append( self.allocator, '/');
            try expected.appendSlice(self.allocator, std.fs.path.basename(self.target_path));
            if (std.mem.eql(u8, logical_path, expected.items)) {
                return self.allocator.dupe(u8, self.target_path);
            }

            return error.NotFound;
        }

        return try joinResolvedPath(self.allocator, self.target_path, logical_path);
    }

    fn renderDirectoryListing(
        self: *Server,
        logical_path: []const u8,
        directory_path: []const u8,
    ) ![]u8 {
        var entries = try collectDirectoryEntries(self.allocator, directory_path);
        defer freeDirectoryEntries(self.allocator, &entries);

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);

        try output.appendSlice(self.allocator,
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\<meta charset="UTF-8" />
            \\<meta name="viewport" content="width=device-width, initial-scale=1.0" />
            \\<link rel="icon" href="data:," />
            \\<title>jsxcc directory listing</title>
            \\<style>
            \\  body{margin:0;background:#0f172a;color:#e2e8f0;font-family:Inter,system-ui,sans-serif;}
            \\  main{max-width:900px;margin:0 auto;padding:32px 20px 48px;}
            \\  h1{margin:0 0 8px;font-size:24px;}
            \\  p{margin:0 0 20px;color:#94a3b8;}
            \\  table{width:100%;border-collapse:collapse;background:#111827;border-radius:16px;overflow:hidden;}
            \\  th,td{padding:14px 16px;border-bottom:1px solid #1f2937;text-align:left;font-size:14px;}
            \\  th{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#94a3b8;background:#0b1220;}
            \\  tr:last-child td{border-bottom:none;}
            \\  a{color:#c4b5fd;text-decoration:none;}
            \\  a:hover{text-decoration:underline;}
            \\  .kind{color:#94a3b8;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;}
            \\</style>
            \\</head>
            \\<body>
            \\<main>
            \\<h1>jsxcc</h1>
            \\<p>Browsing 
        );
        try appendEscapedHtml(&output, self.allocator, directory_path);
        try output.appendSlice(self.allocator, "</p>\n<table>\n<thead><tr><th>Name</th><th>Type</th></tr></thead>\n<tbody>\n");

        if (!std.mem.eql(u8, logical_path, "/")) {
            const parent_path = parentLogicalPath(logical_path);
            try output.appendSlice(self.allocator, "<tr><td><a href=\"");
            try appendEscapedHtml(&output, self.allocator, parent_path);
            try output.appendSlice(self.allocator, "\">..</a></td><td class=\"kind\">parent</td></tr>\n");
        }

        for (entries.items) |entry| {
            try output.appendSlice(self.allocator, "<tr><td><a href=\"");
            const href = try buildChildHref(self.allocator, logical_path, entry.name, entry.kind == .directory);
            defer self.allocator.free(href);
            try appendEscapedHtml(&output, self.allocator, href);
            try output.appendSlice(self.allocator, "\">");
            try appendEscapedHtml(&output, self.allocator, entry.name);
            if (entry.kind == .directory) {
                try output.appendSlice(self.allocator, "/");
            }
            try output.appendSlice(self.allocator, "</a></td><td class=\"kind\">");
            try output.appendSlice(self.allocator, if (entry.kind == .directory) "directory" else if (renderer.isRenderableExtension(entry.name)) "rendered html" else "static file");
            try output.appendSlice(self.allocator, "</td></tr>\n");
        }

        try output.appendSlice(self.allocator,
            \\</tbody>
            \\</table>
            \\</main>
            \\</body>
            \\</html>
        );

        return output.toOwnedSlice(self.allocator);
    }
};

const max_file_size = 32 * 1024 * 1024;

const BindResult = struct {
    port: u16,
    listener: std.net.Server,
};

const ParsedTarget = struct {
    path: []const u8,
    query: ?[]const u8,
};

const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    head_only: bool = false,
};

const DirectoryEntry = struct {
    name: []u8,
    kind: std.fs.File.Kind,
};

fn detectTargetKind(path: []const u8) !TargetKind {
    if (isDirectoryPath(path)) {
        return .directory;
    }
    return .file;
}

fn bindListener(host: []const u8, start_port: u16) !BindResult {
    var port = start_port;
    while (true) : (port += 1) {
        var address = try std.net.Address.parseIp(host, port);
        const listener = address.listen(.{}) catch |err| switch (err) {
            error.AddressInUse => {
                if (port == std.math.maxInt(u16)) return err;
                continue;
            },
            else => return err,
        };

        return .{
            .port = port,
            .listener = listener,
        };
    }
}

fn parseTarget(target: []const u8) !ParsedTarget {
    if (std.mem.indexOfScalar(u8, target, '?')) |index| {
        return .{
            .path = target[0..index],
            .query = target[index + 1 ..],
        };
    }

    return .{
        .path = target,
        .query = null,
    };
}

fn getQueryParam(
    allocator: std.mem.Allocator,
    query: []const u8,
    key: []const u8,
) !?[]u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '=')) |index| {
            const name = part[0..index];
            if (!std.mem.eql(u8, name, key)) continue;
            return try percentDecode(allocator, part[index + 1 ..]);
        } else if (std.mem.eql(u8, part, key)) {
            return try allocator.dupe(u8, "");
        }
    }

    return null;
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const char = input[index];
        if (char == '%' and index + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[index + 1], 16) catch return error.BadPercentEncoding;
            const lo = std.fmt.charToDigit(input[index + 2], 16) catch return error.BadPercentEncoding;
            try output.append(allocator, @as(u8, @intCast((hi << 4) | lo)));
            index += 3;
            continue;
        }

        if (char == '+') {
            try output.append(allocator, ' ');
        } else {
            try output.append(allocator, char);
        }
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn joinResolvedPath(
    allocator: std.mem.Allocator,
    root: []const u8,
    logical_path: []const u8,
) ![]u8 {
    if (logical_path.len == 0 or std.mem.eql(u8, logical_path, "/")) {
        return allocator.dupe(u8, root);
    }
    if (logical_path[0] != '/') return error.InvalidPath;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, root);

    var segments = std.mem.splitScalar(u8, logical_path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidPath;
        }
        if (std.mem.indexOfScalar(u8, segment, '\\') != null) {
            return error.InvalidPath;
        }

        if (output.items.len == 0 or !std.fs.path.isSep(output.items[output.items.len - 1])) {
            try output.append(allocator, std.fs.path.sep);
        }
        try output.appendSlice(allocator, segment);
    }

    return output.toOwnedSlice(allocator);
}

fn buildWatchToken(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const stat = try std.fs.cwd().statFile(path);
    return std.fmt.allocPrint(allocator, "{d}:{d}", .{ stat.size, stat.mtime });
}

pub fn isDirectoryPath(path: []const u8) bool {
    var directory = (if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{ .iterate = true })
    else
        std.fs.cwd().openDir(path, .{ .iterate = true })) catch return false;
    directory.close();
    return true;
}

fn collectDirectoryEntries(allocator: std.mem.Allocator, directory_path: []const u8) !std.ArrayList(DirectoryEntry) {
    var directory = try std.fs.openDirAbsolute(directory_path, .{ .iterate = true });
    defer directory.close();

    var entries: std.ArrayList(DirectoryEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var iterator = directory.iterate();
    while (true) {
        const maybe_entry = iterator.next() catch |err| {
            std.debug.print("jsxcc serve iterate failed for {s}: {s}\n", .{ directory_path, @errorName(err) });
            return err;
        };
        const entry = maybe_entry orelse break;
        if (std.mem.eql(u8, entry.name, ".")) continue;
        const name = try allocator.dupe(u8, entry.name);
        try entries.append(allocator, .{
            .name = name,
            .kind = entry.kind,
        });
    }

    std.mem.sort(DirectoryEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
            if (lhs.kind == .directory and rhs.kind != .directory) return true;
            if (lhs.kind != .directory and rhs.kind == .directory) return false;
            return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
        }
    }.lessThan);

    return entries;
}

fn freeDirectoryEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(DirectoryEntry)) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit(allocator);
}

fn buildChildHref(
    allocator: std.mem.Allocator,
    logical_path: []const u8,
    child_name: []const u8,
    is_directory: bool,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    if (std.mem.eql(u8, logical_path, "/")) {
        try output.append(allocator, '/');
    } else {
        try output.appendSlice(allocator, logical_path);
        if (!std.mem.endsWith(u8, logical_path, "/")) {
            try output.append(allocator, '/');
        }
    }
    try appendUrlEncoded(&output, allocator, child_name);
    if (is_directory) {
        try output.append(allocator, '/');
    }

    return output.toOwnedSlice(allocator);
}

fn appendUrlEncoded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
) !void {
    for (input) |char| {
        const is_unreserved = std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~';
        if (is_unreserved) {
            try output.append(allocator, char);
            continue;
        }

        const escaped = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{char});
        defer allocator.free(escaped);
        try output.appendSlice(allocator, escaped);
    }
}

fn parentLogicalPath(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    const trimmed = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |index| {
        if (index == 0) return "/";
        return trimmed[0..index];
    }
    return "/";
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

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".js")) return "application/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".json")) return "application/json; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".jpg") or std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".txt")) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

test "joinResolvedPath rejects traversal" {
    try std.testing.expectError(error.InvalidPath, joinResolvedPath(std.testing.allocator, "C:\\demo", "/../secret"));
}

test "parentLogicalPath handles nested paths" {
    try std.testing.expectEqualStrings("/", parentLogicalPath("/index.jsx"));
    try std.testing.expectEqualStrings("/foo", parentLogicalPath("/foo/bar/"));
}
