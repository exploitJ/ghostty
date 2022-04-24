//! Command launches sub-processes. This is an alternate implementation to the
//! Zig std.ChildProcess since at the time of authoring this, ChildProcess
//! didn't support the options necessary to spawn a shell attached to a pty.
//!
//! Consequently, I didn't implement a lot of features that std.ChildProcess
//! supports because we didn't need them. Cross-platform subprocessing is not
//! a trivial thing to implement (I've done it in three separate languages now)
//! so if we want to replatform onto std.ChildProcess I'd love to do that.
//! This was just the fastest way to get something built.
//!
//! TODO:
//!
//!   * Windows
//!   * Mac
//!
const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const TempDir = @import("TempDir.zig");
const mem = std.mem;
const os = std.os;
const debug = std.debug;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const BufMap = std.BufMap;

/// Path to the command to run. This must be an absolute path. This
/// library does not do PATH lookup.
path: []const u8,

/// Command-line arguments. It is the responsibility of the caller to set
/// args[0] to the command. If args is empty then args[0] will automatically
/// be set to equal path.
args: []const []const u8,

/// Environment variables for the child process. If this is null, inherits
/// the environment variables from this process. These are the exact
/// environment variables to set; these are /not/ merged.
env: ?*const BufMap = null,

/// The file handle to set for stdin/out/err. If this isn't set, we do
/// nothing explicitly so it is up to the behavior of the operating system.
stdin: ?File = null,
stdout: ?File = null,
stderr: ?File = null,

/// If set, this will be executed /in the child process/ after fork but
/// before exec. This is useful to setup some state in the child before the
/// exec process takes over, such as signal handlers, setsid, setuid, etc.
pre_exec: ?fn (*Command) void = null,

/// User data that is sent to the callback. Set with setData and getData
/// for a more user-friendly API.
data: ?*anyopaque = null,

/// Process ID is set after start is called.
pid: ?i32 = null,

/// The various methods a process may exit.
pub const Exit = union(enum) {
    /// Exited by normal exit call, value is exit status
    Exited: u8,

    /// Exited by a signal, value is the signal
    Signal: u32,

    /// Exited by a stop signal, value is signal
    Stopped: u32,

    /// Unknown exit reason, value is the status from waitpid
    Unknown: u32,

    pub fn init(status: u32) Exit {
        return if (os.W.IFEXITED(status))
            Exit{ .Exited = os.W.EXITSTATUS(status) }
        else if (os.W.IFSIGNALED(status))
            Exit{ .Signal = os.W.TERMSIG(status) }
        else if (os.W.IFSTOPPED(status))
            Exit{ .Stopped = os.W.STOPSIG(status) }
        else
            Exit{ .Unknown = status };
    }
};

/// Start the subprocess. This returns immediately once the child is started.
///
/// After this is successful, self.pid is available.
pub fn start(self: *Command, alloc: Allocator) !void {
    // Use an arena allocator for the temporary allocations we need in this func.
    // IMPORTANT: do all allocation prior to the fork(). I believe it is undefined
    // behavior if you malloc between fork and exec. The source of the Zig
    // stdlib seems to verify this as well as Go.
    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // Null-terminate all our arguments
    const pathZ = try arena.dupeZ(u8, self.path);
    const argsZ = try arena.allocSentinel(?[*:0]u8, self.args.len, null);
    for (self.args) |arg, i| argsZ[i] = (try arena.dupeZ(u8, arg)).ptr;

    // Determine our env vars
    const envp = if (self.env) |env_map|
        (try createNullDelimitedEnvMap(arena, env_map)).ptr
    else if (builtin.link_libc)
        std.c.environ
    else
        @compileError("missing env vars");

    // Fork
    const pid = try std.os.fork();
    if (pid != 0) {
        // Parent, return immediately.
        self.pid = @intCast(i32, pid);
        return;
    }

    // We are the child.

    // Setup our file descriptors for std streams.
    if (self.stdin) |f| try setupFd(f.handle, os.STDIN_FILENO);
    if (self.stdout) |f| try setupFd(f.handle, os.STDOUT_FILENO);
    if (self.stderr) |f| try setupFd(f.handle, os.STDERR_FILENO);

    // If the user requested a pre exec callback, call it now.
    if (self.pre_exec) |f| f(self);

    // Finally, replace our process.
    _ = std.os.execveZ(pathZ, argsZ, envp) catch null;
}

fn setupFd(src: File.Handle, target: i32) !void {
    // We use dup3 so that we can clear CLO_ON_EXEC. We do NOT want this
    // file descriptor to be closed on exec since we're exactly exec-ing after
    // this.
    if (os.linux.dup3(src, target, 0) < 0) return error.Dup3Failed;
}

/// Wait for the command to exit and return information about how it exited.
pub fn wait(self: Command) !Exit {
    const res = std.os.waitpid(self.pid.?, 0);
    return Exit.init(res.status);
}

/// Sets command->data to data.
pub fn setData(self: *Command, pointer: ?*anyopaque) void {
    self.data = pointer;
}

/// Returns command->data.
pub fn getData(self: Command, comptime DT: type) ?*DT {
    return if (self.data) |ptr|
        @ptrCast(?*DT, @alignCast(@alignOf(DT), ptr))
    else
        null;
}

/// Search for "cmd" in the PATH and return the absolute path. This will
/// always allocate if there is a non-null result. The caller must free the
/// resulting value.
///
/// TODO: windows
pub fn expandPath(alloc: Allocator, cmd: []const u8) !?[]u8 {
    // If the command already contains a slash, then we return it as-is
    // because it is assumed to be absolute or relative.
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return try alloc.dupe(u8, cmd);
    }

    const PATH = os.getenvZ("PATH") orelse return null;
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.mem.tokenize(u8, PATH, ":");
    var seen_eacces = false;
    while (it.next()) |search_path| {
        // We need enough space in our path buffer to store this
        const path_len = search_path.len + cmd.len + 1;
        if (path_buf.len < path_len) return error.PathTooLong;

        // Copy in the full path
        mem.copy(u8, &path_buf, search_path);
        path_buf[search_path.len] = '/';
        mem.copy(u8, path_buf[search_path.len + 1 ..], cmd);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0];

        // Stat it
        const f = std.fs.openFileAbsolute(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.AccessDenied => {
                // Accumulate this and return it later so we can try other
                // paths that we have access to.
                seen_eacces = true;
                continue;
            },
            else => return err,
        };
        defer f.close();
        const stat = try f.stat();
        if (stat.kind != .Directory and stat.mode & 0111 != 0) {
            return try alloc.dupe(u8, full_path);
        }
    }

    if (seen_eacces) return error.AccessDenied;

    return null;
}

test "expandPath: env" {
    const path = (try expandPath(testing.allocator, "env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len > 0);
}

test "expandPath: does not exist" {
    const path = try expandPath(testing.allocator, "thisreallyprobablydoesntexist123");
    try testing.expect(path == null);
}

test "expandPath: slash" {
    const path = (try expandPath(testing.allocator, "foo/env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len == 7);
}

// Copied from Zig. This is a publicly exported function but there is no
// way to get it from the std package.
fn createNullDelimitedEnvMap(arena: mem.Allocator, env_map: *const std.BufMap) ![:null]?[*:0]u8 {
    const envp_count = env_map.count();
    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);

    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| : (i += 1) {
        const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + pair.value_ptr.len + 1, 0);
        mem.copy(u8, env_buf, pair.key_ptr.*);
        env_buf[pair.key_ptr.len] = '=';
        mem.copy(u8, env_buf[pair.key_ptr.len + 1 ..], pair.value_ptr.*);
        envp_buf[i] = env_buf.ptr;
    }
    std.debug.assert(i == envp_count);

    return envp_buf;
}

test "createNullDelimitedEnvMap" {
    const allocator = testing.allocator;
    var envmap = BufMap.init(allocator);
    defer envmap.deinit();

    try envmap.put("HOME", "/home/ifreund");
    try envmap.put("WAYLAND_DISPLAY", "wayland-1");
    try envmap.put("DISPLAY", ":1");
    try envmap.put("DEBUGINFOD_URLS", " ");
    try envmap.put("XCURSOR_SIZE", "24");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const environ = try createNullDelimitedEnvMap(arena.allocator(), &envmap);

    try testing.expectEqual(@as(usize, 5), environ.len);

    inline for (.{
        "HOME=/home/ifreund",
        "WAYLAND_DISPLAY=wayland-1",
        "DISPLAY=:1",
        "DEBUGINFOD_URLS= ",
        "XCURSOR_SIZE=24",
    }) |target| {
        for (environ) |variable| {
            if (mem.eql(u8, mem.span(variable orelse continue), target)) break;
        } else {
            try testing.expect(false); // Environment variable not found
        }
    }
}

test "Command: basic exec" {
    var cmd: Command = .{
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "--version" },
    };

    try cmd.start(testing.allocator);
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait();
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);
}

test "Command: pre exec" {
    var cmd: Command = .{
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "--version" },
        .pre_exec = (struct {
            fn do() void {
                // This runs in the child, so we can exit and it won't
                // kill the test runner.
                os.exit(42);
            }
        }).do,
    };

    try cmd.start(testing.allocator);
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait();
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}

test "Command: redirect stdout to file" {
    const td = try TempDir.init();
    defer td.deinit();
    var stdout = try td.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout.close();

    var cmd: Command = .{
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "--version" },
        .stdout = stdout,
    };

    try cmd.start(testing.allocator);
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait();
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    try stdout.seekTo(0);
    const contents = try stdout.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(contents);
    try testing.expect(contents.len > 0);
}

test "Command: custom env vars" {
    const td = try TempDir.init();
    defer td.deinit();
    var stdout = try td.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout.close();

    var env = std.BufMap.init(testing.allocator);
    defer env.deinit();
    try env.put("VALUE", "hello");

    var cmd: Command = .{
        .path = "/usr/bin/env",
        .args = &.{ "/usr/bin/env", "sh", "-c", "echo $VALUE" },
        .stdout = stdout,
        .env = &env,
    };

    try cmd.start(testing.allocator);
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait();
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);

    // Read our stdout
    try stdout.seekTo(0);
    const contents = try stdout.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("hello\n", contents);
}
