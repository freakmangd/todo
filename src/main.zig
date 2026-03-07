const timestamp_format = "YYYY-MM-DD HH:mm:ss z";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.skip();

    if (args.next()) |arg| {
        const Command = enum {
            init,
            add,
            remove,
            list,
            start,
            stop,
            complete,
            notes,
        };

        const command = std.meta.stringToEnum(Command, arg) orelse {
            std.log.err("{s} is not a recognized command", .{arg});
            return error.UnexpectedArgument;
        };

        switch (command) {
            .init => {
                const name = try expectNextArg(&args, "name");

                const cwd = std.Io.Dir.cwd();

                var todo_dir = try cwd.createDirPathOpen(init.io, ".todo", .{});
                defer todo_dir.close(init.io);

                const config_file = try todo_dir.createFile(init.io, "config.zon", .{});
                defer config_file.close(init.io);

                var buf: [2048]u8 = undefined;
                var fw = config_file.writer(init.io, &buf);

                try fw.interface.print(
                    \\.{{
                    \\    .name = "{s}",
                    \\}}
                , .{name});
                try fw.interface.flush();
            },
            .add => {
                const name = try expectNextArg(&args, "name");

                var todo_dir = findTodoDir(init.io, std.Io.Dir.cwd(), .{}) catch |err| {
                    std.log.err("cannot find todo dir: {t}", .{err});
                    return error.CannotFindTodoDir;
                };
                defer todo_dir.close(init.io);

                var todo_file = todo_dir.createFile(init.io, name, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        std.log.err("'{s}' already exists", .{name});
                        return error.TodoAlreadyExists;
                    },
                    else => |e| return e,
                };
                defer todo_file.close(init.io);

                var buf: [2048]u8 = undefined;
                var fw = todo_file.writer(init.io, &buf);

                try fw.interface.writeAll("created: ");

                const now = time.Time.now();
                try now.format("YYYY-MM-DD HH:mm:ss z", .{}, &fw.interface);

                try fw.interface.flush();
            },
            .list => {
                var buf: [2048]u8 = undefined;
                var stdout = std.Io.File.stdout().writer(&buf);

                var todo_dir = try findTodoDir(std.fs.cwd(), .{ .iterate = true });
                defer todo_dir.close();

                var todo_dir_iter = todo_dir.iterate();
                while (try todo_dir_iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.name, "config.zon"))
                        continue;

                    const td_item = try todo_dir.openFile(entry.name, .{});
                    defer td_item.close();

                    var read_buf: [2048]u8 = undefined;
                    var reader = td_item.reader(&read_buf);

                    var last_line_maybe: ?[]const u8 = null;
                    while (try reader.interface.takeDelimiter('\n')) |line| {
                        if (line.len == 0) continue;
                        last_line_maybe = line;
                    }

                    const last_line = last_line_maybe orelse {
                        std.log.err("malformed todo item: {s}, file is empty", .{entry.name});
                        continue;
                    };

                    const status_word, const timestamp_str = status_word: {
                        const colon_idx = std.mem.indexOfScalar(u8, last_line, ':') orelse {
                            std.log.err("malformed todo item: {s}, found {s} as latest status", .{ entry.name, last_line });
                            continue;
                        };
                        break :status_word .{ last_line[0..colon_idx], last_line[colon_idx + 2 ..] };
                    };

                    const Status = enum {
                        created,
                        started,
                        stopped,
                        finishd, // yes, it's misspelled, but this way everything is aligned :)
                        restart,
                    };

                    const status = std.meta.stringToEnum(Status, status_word) orelse {
                        std.log.err("malformed todo item: {s}, found {s} as status", .{ entry.name, status_word });
                        continue;
                    };
                    const status_char: u8 = switch (status) {
                        .created, .stopped, .restart => ' ',
                        .started => 'o',
                        .finishd => 'x',
                    };

                    try stdout.interface.print("[{c}] {s} - {s}\n", .{ status_char, entry.name, timestamp_str });
                    try stdout.interface.flush();
                }
            },
            else => @panic("TODO"),
        }
    }
}

fn findTodoDir(io: std.Io, cwd: std.Io.Dir, open_dir_options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    var cur = cwd;

    const todo_dir: std.Io.Dir = todo_dir: while (true) {
        break :todo_dir cur.openDir(io, ".todo", open_dir_options) catch {
            const parent = try cur.openDir(io, "..", .{});
            cur.close(io);
            cur = parent;
            continue;
        };
    };

    if (todo_dir.access(io, "config.zon", .{})) |_| {} else |_| {
        return error.MalformedTodoDir;
    }

    return todo_dir;
}

fn expectNextArg(args: *std.process.Args.Iterator, name: []const u8) ![]const u8 {
    return args.next() orelse {
        std.log.err("Not enough arguments, missing '{s}'", .{name});
        return error.NotEnoughArguments;
    };
}

const std = @import("std");
const time = @import("zig-time");
