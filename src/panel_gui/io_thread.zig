//! Panel I/O Thread
//!
//! Manages a PTY child process (lazygit, lazydocker, etc.) on a background
//! thread. Reads VT output and queues it for the renderer; writes keyboard
//! input to the PTY stdin.
//!
//! Architecture mirrors neovim_gui/io_thread.zig:
//! - I/O thread reads PTY output continuously
//! - Queues raw bytes for the panel's virtual terminal to process
//! - Input writes go directly to the PTY fd (low latency)
//! - On data arrival, wakes the renderer for immediate redraw

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.panel_io);

/// Thread-safe byte queue for passing PTY output from I/O thread to render thread.
pub const OutputQueue = struct {
    const Self = @This();

    mutex: std.Thread.Mutex = .{},
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    alloc: Allocator,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.alloc);
    }

    pub fn push(self: *Self, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.buffer.appendSlice(self.alloc, data);
    }

    /// Drain all pending output. Returns owned slice, caller must free.
    pub fn drain(self: *Self, alloc: Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffer.items.len == 0) return null;

        const result = try alloc.dupe(u8, self.buffer.items);
        self.buffer.clearRetainingCapacity();
        return result;
    }

    /// Check if there's pending data without draining
    pub fn hasPending(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.items.len > 0;
    }
};

/// The panel I/O thread. Manages the PTY process and shuttles data.
pub const IoThread = struct {
    const Self = @This();

    alloc: Allocator,

    /// The PTY master file descriptor
    pty_fd: ?posix.fd_t = null,

    /// Child process ID
    child_pid: ?posix.pid_t = null,

    /// Output queue (I/O thread writes, render thread reads)
    output_queue: *OutputQueue,

    /// Thread handle
    thread: ?std.Thread = null,

    /// Stop signal
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Render wakeup callback (like nvim_gui's)
    render_wakeup_ptr: ?*anyopaque = null,
    render_wakeup_notify: ?*const fn (*anyopaque) void = null,

    /// Whether the child process has exited
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Child exit code
    exit_code: ?u32 = null,

    pub fn init(alloc: Allocator, output_queue: *OutputQueue) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .output_queue = output_queue,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        if (self.pty_fd) |fd| {
            posix.close(fd);
        }

        // Kill child if still running
        if (self.child_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            // Reap the child
            _ = posix.waitpid(pid, 0);
        }

        self.alloc.destroy(self);
    }

    /// Spawn the panel program in a PTY
    pub fn spawn(self: *Self, program: []const u8, cols: u16, rows: u16, cwd: ?[]const u8) !void {
        // Open a PTY pair
        const pty_result = try openPty(cols, rows);
        self.pty_fd = pty_result.master;

        // Fork the child
        const pid = try posix.fork();
        if (pid == 0) {
            // === CHILD PROCESS ===
            // Close master side
            posix.close(pty_result.master);

            // Create a new session
            _ = std.os.linux.setsid();

            // Set the slave as controlling terminal
            _ = std.os.linux.ioctl(pty_result.slave, std.os.linux.T.IOCSCTTY, @as(usize, 0));

            // Redirect stdio to the slave PTY
            posix.dup2(pty_result.slave, 0) catch posix.exit(1);
            posix.dup2(pty_result.slave, 1) catch posix.exit(1);
            posix.dup2(pty_result.slave, 2) catch posix.exit(1);
            if (pty_result.slave > 2) posix.close(pty_result.slave);

            // Change directory if requested
            if (cwd) |dir| {
                posix.chdir(dir) catch {};
            }

            // Set TERM
            const env = [_:null]?[*:0]const u8{
                "TERM=xterm-256color",
                "COLORTERM=truecolor",
                // Inherit common env vars
                if (std.posix.getenv("HOME")) |h| @ptrCast(std.fmt.bufPrint(&home_buf, "HOME={s}", .{h}) catch "HOME=/tmp") else "HOME=/tmp",
                if (std.posix.getenv("PATH")) |p| @ptrCast(std.fmt.bufPrint(&path_buf, "PATH={s}", .{p}) catch "PATH=/usr/bin") else "PATH=/usr/bin:/bin",
                if (std.posix.getenv("USER")) |u| @ptrCast(std.fmt.bufPrint(&user_buf, "USER={s}", .{u}) catch null) else null,
                if (std.posix.getenv("SHELL")) |s| @ptrCast(std.fmt.bufPrint(&shell_buf, "SHELL={s}", .{s}) catch null) else null,
                if (std.posix.getenv("LANG")) |l| @ptrCast(std.fmt.bufPrint(&lang_buf, "LANG={s}", .{l}) catch null) else null,
                null,
            };

            // Exec the program (split by spaces for simple argument handling)
            // For "lazygit", "lazydocker", etc.
            const argv = [_:null]?[*:0]const u8{
                @ptrCast(program.ptr),
                null,
            };

            // We need a null-terminated program name
            var prog_buf: [256]u8 = undefined;
            const prog_len = @min(program.len, 255);
            @memcpy(prog_buf[0..prog_len], program[0..prog_len]);
            prog_buf[prog_len] = 0;

            const prog_z: [*:0]const u8 = prog_buf[0..prog_len :0];
            _ = argv;

            const args = [_:null]?[*:0]const u8{
                prog_z,
                null,
            };

            // Filter out null entries from env
            var clean_env: [16:null]?[*:0]const u8 = .{null} ** 16;
            var env_idx: usize = 0;
            for (env) |e| {
                if (e != null and env_idx < 15) {
                    clean_env[env_idx] = e;
                    env_idx += 1;
                }
            }

            posix.execvpeZ(prog_z, &args, &clean_env) catch {};

            // If exec failed
            posix.exit(127);
        }

        // === PARENT PROCESS ===
        self.child_pid = pid;
        posix.close(pty_result.slave);
    }

    // Static buffers for env vars in child (used after fork, before exec)
    var home_buf: [512]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    var user_buf: [256]u8 = undefined;
    var shell_buf: [256]u8 = undefined;
    var lang_buf: [256]u8 = undefined;

    /// Start the I/O read thread
    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
    }

    /// Stop the I/O thread
    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Write input data to the PTY (called from main/render thread)
    pub fn writeInput(self: *Self, data: []const u8) !void {
        const fd = self.pty_fd orelse return;
        _ = posix.write(fd, data) catch |err| {
            log.debug("PTY write error: {}", .{err});
            return err;
        };
    }

    /// Resize the PTY
    pub fn resize(self: *Self, cols: u16, rows: u16) !void {
        const fd = self.pty_fd orelse return;
        var ws = std.posix.winsize{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        const TIOCSWINSZ = 0x5414;
        const result = std.os.linux.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws));
        if (result != 0) {
            log.debug("TIOCSWINSZ failed", .{});
        }
    }

    pub fn setRenderWakeup(self: *Self, ptr: *anyopaque, notify_fn: *const fn (*anyopaque) void) void {
        self.render_wakeup_ptr = ptr;
        self.render_wakeup_notify = notify_fn;
    }

    fn triggerRenderWakeup(self: *Self) void {
        if (self.render_wakeup_ptr) |ptr| {
            if (self.render_wakeup_notify) |notify_fn| {
                notify_fn(ptr);
            }
        }
    }

    /// Background thread: continuously read PTY output
    fn readLoop(self: *Self) void {
        var buf: [16384]u8 = undefined;

        while (!self.should_stop.load(.acquire)) {
            const fd = self.pty_fd orelse break;

            // Use poll to avoid blocking indefinitely
            var fds = [_]posix.pollfd{
                .{
                    .fd = fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                },
            };

            const poll_result = posix.poll(&fds, 50) catch |err| {
                log.debug("poll error: {}", .{err});
                break;
            };

            if (poll_result == 0) continue; // timeout
            if (fds[0].revents & posix.POLL.HUP != 0) {
                // PTY closed - child exited
                self.handleChildExit();
                break;
            }

            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(fd, &buf) catch |err| {
                    if (err == error.WouldBlock) continue;
                    log.debug("PTY read error: {}", .{err});
                    self.handleChildExit();
                    break;
                };

                if (n == 0) {
                    self.handleChildExit();
                    break;
                }

                self.output_queue.push(buf[0..n]) catch |err| {
                    log.debug("output queue push error: {}", .{err});
                    continue;
                };

                // Wake the renderer for immediate redraw
                self.triggerRenderWakeup();
            }
        }
    }

    fn handleChildExit(self: *Self) void {
        self.exited.store(true, .release);
        if (self.child_pid) |pid| {
            const wait_result = posix.waitpid(pid, posix.W.NOHANG);
            if (wait_result.pid != 0) {
                self.exit_code = (wait_result.status >> 8) & 0xFF;
                self.child_pid = null;
            }
        }
        self.triggerRenderWakeup();
    }
};

/// Result of opening a PTY pair
const PtyPair = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
};

/// Open a new PTY pair and set the window size
fn openPty(cols: u16, rows: u16) !PtyPair {
    // Use posix_openpt / grantpt / unlockpt / ptsname
    const master = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer posix.close(master);

    // Grant and unlock
    const TIOCSPTLCK = 0x40045431;
    var unlock: c_int = 0;
    _ = std.os.linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock));

    // Get slave PTY number
    const TIOCGPTN = 0x80045430;
    var pty_num: c_uint = 0;
    _ = std.os.linux.ioctl(master, TIOCGPTN, @intFromPtr(&pty_num));

    // Build slave path
    var slave_path_buf: [32]u8 = undefined;
    const slave_path = std.fmt.bufPrint(&slave_path_buf, "/dev/pts/{d}", .{pty_num}) catch return error.PathTooLong;
    // Null-terminate
    slave_path_buf[slave_path.len] = 0;

    const slave = try posix.open(slave_path_buf[0..slave_path.len :0], .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer posix.close(slave);

    // Set window size on the slave
    var ws = posix.winsize{
        .col = cols,
        .row = rows,
        .xpixel = 0,
        .ypixel = 0,
    };
    const TIOCSWINSZ = 0x5414;
    _ = std.os.linux.ioctl(slave, TIOCSWINSZ, @intFromPtr(&ws));

    return .{ .master = master, .slave = slave };
}
