const timestamp_format = "YYYY-MM-DD HH:mm:ss z";

const Config = struct {
    name: []const u8,
};

pub fn main(init: std.process.Init) if (@import("builtin").mode == .Debug) anyerror!void else void {
    mainInner(init) catch |err| switch (err) {
        error.CannotFindTodoDir => std.log.err("cannot find todo dir", .{}),
        error.MalformedTodoDir => std.log.err("your todo dir is malformed", .{}),
        else => |e| {
            std.log.err("{t}", .{e});
            if (@import("builtin").mode == .Debug) return e;
        },
    };
}

pub fn mainInner(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.skip();

    if (args.next()) |arg| {
        const Command = enum {
            help,
            init,
            add,
            remove,
            list,
            start,
            stop,
            complete,
            notes,
            edit,
        };

        const command = std.meta.stringToEnum(Command, arg) orelse {
            std.log.err("{s} is not a recognized command", .{arg});
            return error.UnexpectedArgument;
        };

        switch (command) {
            .help => {
                var buf: [2048]u8 = undefined;
                var stdout = File.stdout().writer(io, &buf);

                try stdout.interface.writeAll(
                    \\todo
                    \\    help             - show this dialogue
                    \\    init             - create a .todo dir in the current directory
                    \\    list             - list todo items
                    \\
                    \\    add <name>       - add a todo item
                    \\    remove <name>    - remove todo item
                    \\    start <name>     - start working on a todo item
                    \\    stop <name>      - stop working on a todo item
                    \\    complete <name>  - complete a todo item
                    \\    notes <name>     - print todo item's notes
                    \\    edit <name>      - print path to todo item's note file, ex. `todo notes abc | xargs vim`
                );
                try stdout.interface.flush();
            },
            .init => {
                const name = try expectNextArg(&args, "name");

                const cwd = Dir.cwd();

                var todo_dir = try cwd.createDirPathOpen(io, ".todo", .{});
                defer todo_dir.close(io);

                const config_file = try todo_dir.createFile(io, "config.zon", .{});
                defer config_file.close(io);

                var buf: [2048]u8 = undefined;
                var fw = config_file.writer(io, &buf);

                try fw.interface.print(
                    \\.{{
                    \\    .name = "{s}",
                    \\}}
                , .{name});
                try fw.interface.flush();
            },
            .add => {
                const now: std.Io.Timestamp = .now(io, .real);

                var todo_dir = try findTodoDir(io, Dir.cwd(), .{});
                defer todo_dir.close(io);

                const name = try expectNextArg(&args, "name");
                const name_with_ext = try nameWithExt(gpa, name, ".todo");
                defer gpa.free(name_with_ext);

                var todo_file = todo_dir.createFile(io, name_with_ext, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        std.log.err("'{s}' already exists", .{name});
                        return error.TodoAlreadyExists;
                    },
                    else => |e| return e,
                };
                defer todo_file.close(io);

                var buf: [2048]u8 = undefined;
                var fw = todo_file.writer(io, &buf);

                try fw.interface.print("created: {d}", .{now});
                try fw.interface.flush();
            },
            .remove => {
                var todo_dir = try findTodoDir(io, Dir.cwd(), .{});
                defer todo_dir.close(io);

                const name = try expectNextArg(&args, "name");
                if (std.mem.eql(u8, name, "config.zon")) {
                    std.log.err("Cannot delete 'config.zon'", .{});
                    return error.IllegalDelete;
                }

                var buf: [2048]u8 = undefined;
                var stdin = File.stdin().reader(io, &buf);

                var stdout = File.stdout().writer(io, &.{});
                try stdout.interface.print("Are you sure you'd like to remove '{s}'? (y/n): ", .{name});

                if (try stdin.interface.takeDelimiter('\n')) |input| {
                    if (input.len == 1 and std.ascii.toLower(input[0]) == 'y') {
                        todo_dir.deleteFile(io, name) catch |err| switch (err) {
                            error.FileNotFound => std.log.err("'{s}' not found", .{name}),
                            else => |e| {
                                std.log.err("Failed to delete todo item: {t}", .{e});
                                return err;
                            },
                        };
                    }
                }
            },
            .list => {
                var buf: [2048]u8 = undefined;
                var stdout = File.stdout().writer(io, &buf);

                var todo_dir = try findTodoDir(io, Dir.cwd(), .{ .iterate = true });
                defer todo_dir.close(io);

                const config = try parseConfig(gpa, io, todo_dir, &buf);
                defer std.zon.parse.free(gpa, config);

                try stdout.interface.print("{s} items:\n", .{config.name});

                var todo_dir_iter = todo_dir.iterate();
                while (try todo_dir_iter.next(io)) |entry| {
                    if (std.mem.eql(u8, entry.name, "config.zon"))
                        continue;

                    const td_item = try todo_dir.openFile(io, entry.name, .{});
                    defer td_item.close(io);

                    var read_buf: [2048]u8 = undefined;
                    var reader = td_item.reader(io, &read_buf);

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

                    try stdout.interface.print("    [{c}] {s} - {s}\n", .{ status_char, trimExt(entry.name), timestamp_str });
                }

                try stdout.interface.flush();
            },
            .notes => {
                var buf: [2048]u8 = undefined;
                var stdout = File.stdout().writer(io, &buf);

                var todo_dir = try findTodoDir(io, Dir.cwd(), .{ .iterate = true });
                defer todo_dir.close(io);

                const name = try expectNextArg(&args, "name");
                const name_with_ext = try nameWithExt(gpa, name, ".md");
                defer gpa.free(name_with_ext);

                const note_file = todo_dir.openFile(io, name_with_ext, .{}) catch |err| switch (err) {
                    error.FileNotFound => return,
                    else => |e| return e,
                };
                defer note_file.close(io);

                var file_buf: [2048]u8 = undefined;
                var file_reader = note_file.reader(io, &file_buf);

                _ = try file_reader.interface.streamRemaining(&stdout.interface);
                try stdout.interface.flush();
            },
            .edit => {
                var buf: [2048]u8 = undefined;
                var stdout = File.stdout().writer(io, &buf);

                var path: Io.Writer.Allocating = try .initCapacity(gpa, 2);
                defer path.deinit();

                try path.writer.writeAll("\"");

                var todo_dir = try findTodoDirWithPath(io, Dir.cwd(), .{ .iterate = true }, &path.writer);
                defer todo_dir.close(io);

                const name = try expectNextArg(&args, "name");
                const name_with_ext = try nameWithExt(gpa, name, ".md");
                defer gpa.free(name_with_ext);

                try path.writer.writeAll(name_with_ext);
                try path.writer.writeAll("\"");

                try stdout.interface.writeAll(path.written());
                try stdout.interface.flush();
            },
            else => @panic("TODO"),
        }
    }
}

fn findTodoDir(io: std.Io, cwd: Dir, open_dir_options: Dir.OpenOptions) !Dir {
    var dcw = Io.Writer.Discarding.init(&.{});
    return findTodoDirWithPath(io, cwd, open_dir_options, &dcw.writer);
}

fn findTodoDirWithPath(io: std.Io, cwd: Dir, open_dir_options: Dir.OpenOptions, path_writer: *Io.Writer) !Dir {
    var cur = cwd;

    const todo_dir: Dir = while (true) {
        const todo_dir = cur.openDir(io, ".todo", open_dir_options) catch {
            const parent = cur.openDir(io, "..", .{}) catch return error.CannotFindTodoDir;
            cur.close(io);
            cur = parent;

            try path_writer.writeAll("../");
            continue;
        };

        try path_writer.writeAll(".todo/");
        break todo_dir;
    };

    if (todo_dir.access(io, "config.zon", .{})) |_| {} else |_| {
        return error.MalformedTodoDir;
    }

    return todo_dir;
}

fn nameWithExt(gpa: std.mem.Allocator, name: []const u8, ext: []const u8) ![]u8 {
    const name_with_ext: []u8 = try gpa.alloc(u8, name.len + ext.len);
    @memcpy(name_with_ext[0..name.len], name);
    @memcpy(name_with_ext[name.len..], ext);
    return name_with_ext;
}

fn trimExt(name: []const u8) []const u8 {
    return name[0 .. name.len - ".todo".len];
}

fn parseConfig(gpa: std.mem.Allocator, io: Io, todo_dir: Dir, buf: []u8) !Config {
    const config_file = try todo_dir.openFile(io, "config.zon", .{});
    defer config_file.close(io);

    var config_reader = config_file.reader(io, buf);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);

    try config_reader.interface.appendRemaining(gpa, &content, .limited(10_000));
    try content.ensureTotalCapacityPrecise(gpa, content.items.len + 1);
    content.appendAssumeCapacity(0);

    return std.zon.parse.fromSliceAlloc(Config, gpa, content.items[0 .. content.items.len - 1 :0], null, .{});
}

fn expectNextArg(args: *std.process.Args.Iterator, name: []const u8) ![]const u8 {
    return args.next() orelse {
        std.log.err("Not enough arguments, missing '{s}'", .{name});
        return error.NotEnoughArguments;
    };
}

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
