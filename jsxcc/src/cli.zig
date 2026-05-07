const std = @import("std");
const build_options = @import("build_options");
const renderer = @import("renderer.zig");
const server_module = @import("server.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        try writeStdout(help_text);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try writeStdout(help_text);
        return;
    }
    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try printStdout("{s}\n", .{build_options.version});
        return;
    }
    if (std.mem.eql(u8, command, "build")) {
        try runBuild(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "serve")) {
        try runServe(allocator, args[2..]);
        return;
    }

    try printStderr("Unknown command: {s}\n\n", .{command});
    try writeStdout(help_text);
    return error.InvalidCommand;
}

const BuildCommand = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    stdout_only: bool = false,
};

const ServeCommand = struct {
    input_path: []const u8,
    host: ?[]const u8 = null,
    port: ?u16 = null,
};

fn runBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const command = try parseBuildCommand(args);
    if (command.stdout_only and command.output_path != null) {
        return error.InvalidArguments;
    }

    const absolute_input = try std.fs.cwd().realpathAlloc(allocator, command.input_path);
    defer allocator.free(absolute_input);

    const is_directory = server_module.isDirectoryPath(absolute_input);
    if (is_directory) {
        if (command.stdout_only) return error.InvalidArguments;
        const output_path = if (command.output_path) |output| try resolvePathAllowCreate(allocator, output) else try defaultDirectoryOutputPath(allocator, command.input_path);
        defer allocator.free(output_path);

        try std.fs.cwd().makePath(output_path);
        try buildDirectory(allocator, absolute_input, output_path);
        try printStdout("Built directory to {s}\n", .{output_path});
        return;
    }

    const source = try std.fs.cwd().readFileAlloc(allocator, absolute_input, max_file_size);
    defer allocator.free(source);

    const html = try renderer.renderDocument(allocator, source, .{
        .source_name = std.fs.path.basename(absolute_input),
    });
    defer allocator.free(html);

    if (command.stdout_only) {
        try std.fs.File.stdout().writeAll(html);
        return;
    }

    const destination = if (command.output_path) |output|
        try resolveSingleFileOutputPath(allocator, absolute_input, output)
    else
        try defaultFileOutputPath(allocator, absolute_input);
    defer allocator.free(destination);

    const destination_dir = std.fs.path.dirname(destination) orelse ".";
    try std.fs.cwd().makePath(destination_dir);
    try writeFile(destination, html);
    try printStdout("Built {s} -> {s}\n", .{ absolute_input, destination });
}

fn runServe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const command = try parseServeCommand(args);

    const host_value = if (command.host) |value| value else try envOrDefaultOwned(allocator, "JSXCC_HOST", "127.0.0.1");
    defer if (command.host == null) allocator.free(host_value);

    const port_value = if (command.port) |value| value else try readPortFromEnvironment(allocator);

    var server = try server_module.Server.init(.{
        .allocator = allocator,
        .target_path = command.input_path,
        .host = host_value,
        .requested_port = port_value,
    });
    defer server.deinit();

    try printStdout("Serving {s} at http://{s}:{d}\n", .{ server.target_path, server.host, server.port });
    try server.serve();
}

fn parseBuildCommand(args: []const []const u8) !BuildCommand {
    var command = BuildCommand{
        .input_path = "",
    };

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            command.output_path = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdout")) {
            command.stdout_only = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArguments;
        }
        if (command.input_path.len != 0) return error.InvalidArguments;
        command.input_path = arg;
    }

    if (command.input_path.len == 0) return error.InvalidArguments;
    return command;
}

fn parseServeCommand(args: []const []const u8) !ServeCommand {
    var command = ServeCommand{
        .input_path = "",
    };

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            command.port = try parsePort(args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            command.host = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArguments;
        }
        if (command.input_path.len != 0) return error.InvalidArguments;
        command.input_path = arg;
    }

    if (command.input_path.len == 0) return error.InvalidArguments;
    return command;
}

fn buildDirectory(
    allocator: std.mem.Allocator,
    input_root: []const u8,
    output_root: []const u8,
) !void {
    var input_dir = try std.fs.openDirAbsolute(input_root, .{ .iterate = true });
    defer input_dir.close();

    var walker = try input_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const source_path = try std.fs.path.join(allocator, &.{ input_root, entry.path });
        defer allocator.free(source_path);
        const entry_name = std.fs.path.basename(entry.path);

        const destination_path = try buildDestinationPath(allocator, output_root, entry.path, entry.kind);
        defer allocator.free(destination_path);

        switch (entry.kind) {
            .directory => try std.fs.cwd().makePath(destination_path),
            .file => {
                const parent = std.fs.path.dirname(destination_path) orelse output_root;
                try std.fs.cwd().makePath(parent);
                if (renderer.isRenderableExtension(entry_name)) {
                    const source = try std.fs.cwd().readFileAlloc(allocator, source_path, max_file_size);
                    defer allocator.free(source);
                    const html = try renderer.renderDocument(allocator, source, .{
                        .source_name = entry_name,
                    });
                    defer allocator.free(html);
                    try writeFile(destination_path, html);
                } else {
                    const bytes = try std.fs.cwd().readFileAlloc(allocator, source_path, max_file_size);
                    defer allocator.free(bytes);
                    try writeFile(destination_path, bytes);
                }
            },
            else => {},
        }
    }
}

fn buildDestinationPath(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    relative_path: []const u8,
    kind: std.fs.File.Kind,
) ![]u8 {
    if (kind == .directory) {
        return std.fs.path.join(allocator, &.{ output_root, relative_path });
    }

    const rel_dir = std.fs.path.dirname(relative_path);
    const base_name = std.fs.path.basename(relative_path);
    const destination_name = if (renderer.isJsxLikeExtension(base_name))
        try renderedFileName(allocator, base_name)
    else
        try allocator.dupe(u8, base_name);
    defer allocator.free(destination_name);

    if (rel_dir) |directory| {
        return std.fs.path.join(allocator, &.{ output_root, directory, destination_name });
    }

    return std.fs.path.join(allocator, &.{ output_root, destination_name });
}

fn resolveSingleFileOutputPath(
    allocator: std.mem.Allocator,
    absolute_input: []const u8,
    requested_output: []const u8,
) ![]u8 {
    const absolute_output = try resolvePathAllowCreate(allocator, requested_output);
    errdefer allocator.free(absolute_output);

    if (server_module.isDirectoryPath(absolute_output) or std.mem.endsWith(u8, requested_output, "\\") or std.mem.endsWith(u8, requested_output, "/")) {
        const rendered_name = try renderedFileName(allocator, std.fs.path.basename(absolute_input));
        defer allocator.free(rendered_name);
        defer allocator.free(absolute_output);
        return std.fs.path.join(allocator, &.{ absolute_output, rendered_name });
    }

    return absolute_output;
}

fn defaultFileOutputPath(allocator: std.mem.Allocator, absolute_input: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(absolute_input) orelse ".";
    const rendered_name = try renderedFileName(allocator, std.fs.path.basename(absolute_input));
    defer allocator.free(rendered_name);

    return std.fs.path.join(allocator, &.{ parent, rendered_name });
}

fn defaultDirectoryOutputPath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    const absolute_input = try std.fs.cwd().realpathAlloc(allocator, input_path);
    defer allocator.free(absolute_input);

    const parent = std.fs.path.dirname(absolute_input) orelse ".";
    const base_name = std.fs.path.basename(absolute_input);
    const output_name = try std.fmt.allocPrint(allocator, "{s}-dist", .{base_name});
    defer allocator.free(output_name);

    return std.fs.path.join(allocator, &.{ parent, output_name });
}

fn resolvePathAllowCreate(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn renderedFileName(allocator: std.mem.Allocator, file_name: []const u8) ![]u8 {
    const extension = std.fs.path.extension(file_name);
    const stem = if (extension.len == 0) file_name else file_name[0 .. file_name.len - extension.len];

    if (renderer.isJsxLikeExtension(file_name)) {
        return std.fmt.allocPrint(allocator, "{s}.html", .{stem});
    }
    if (std.ascii.eqlIgnoreCase(extension, ".htm")) {
        return std.fmt.allocPrint(allocator, "{s}.htm", .{stem});
    }
    if (std.ascii.eqlIgnoreCase(extension, ".html")) {
        return std.fmt.allocPrint(allocator, "{s}.html", .{stem});
    }
    return allocator.dupe(u8, file_name);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn envOrDefaultOwned(
    allocator: std.mem.Allocator,
    key: []const u8,
    fallback: []const u8,
) ![]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch allocator.dupe(u8, fallback);
}

fn readPortFromEnvironment(allocator: std.mem.Allocator) !u16 {
    const env_value = std.process.getEnvVarOwned(allocator, "JSXCC_PORT") catch return 4173;
    defer allocator.free(env_value);
    return parsePort(env_value);
}

fn parsePort(value: []const u8) !u16 {
    const parsed = try std.fmt.parseUnsigned(u16, value, 10);
    if (parsed == 0) return error.InvalidArguments;
    return parsed;
}

fn writeStdout(bytes: []const u8) !void {
    try std.fs.File.stdout().writeAll(bytes);
}

fn printStdout(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [2048]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, fmt, args);
    try writeStdout(rendered);
}

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [2048]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, fmt, args);
    try std.fs.File.stderr().writeAll(rendered);
}

const max_file_size = 32 * 1024 * 1024;

const help_text =
    \\jsxcc
    \\
    \\Build JSX files into standalone HTML or serve them live with a single static binary.
    \\
    \\Usage:
    \\  jsxcc build <input> [-o <output>] [--stdout]
    \\  jsxcc serve <input> [--port <port>] [--host <host>]
    \\  jsxcc version
    \\  jsxcc help
    \\
    \\Commands:
    \\  build     Convert a JSX file or recursively build a directory.
    \\  serve     Serve a file or directory with live JSX rendering and reload.
    \\  version   Print the embedded version from version.txt.
    \\  help      Show this help text.
    \\
    \\Environment:
    \\  JSXCC_PORT   Default starting port for `serve` (falls back upward if busy).
    \\  JSXCC_HOST   Host interface for `serve` (default: 127.0.0.1).
    \\
    \\Extras:
    \\  - Directory builds preserve structure and copy non-JSX assets.
    \\  - HTML inputs are passed through unchanged unless live reload is injected by `serve`.
    \\
;

test "rendered file name swaps jsx-like extensions to html" {
    const jsx_name = try renderedFileName(std.testing.allocator, "demo.jsx");
    defer std.testing.allocator.free(jsx_name);
    try std.testing.expectEqualStrings("demo.html", jsx_name);

    const html_name = try renderedFileName(std.testing.allocator, "index.html");
    defer std.testing.allocator.free(html_name);
    try std.testing.expectEqualStrings("index.html", html_name);
}

test "parse build command accepts output flag" {
    const command = try parseBuildCommand(&.{ "src", "-o", "dist" });
    try std.testing.expectEqualStrings("src", command.input_path);
    try std.testing.expectEqualStrings("dist", command.output_path.?);
}
