const timestamp_format = "YYYY-MM-DD HH:mm:ss z";

const Status = enum {
    created,
    started,
    stopped,
    finishd, // yes, it's misspelled, but this way everything is aligned :)
    restart,

    fn char(s: Status) u8 {
        return switch (s) {
            .created, .stopped, .restart => ' ',
            .started => 'o',
            .finishd => 'x',
        };
    }
};

const Command = enum {
    help,
    init,
    add,
    a,
    remove,
    rm,
    status,
    stat,
    list,
    ls,
    start,
    on,
    stop,
    off,
    complete,
    done,
    uncomplete,
    notes,
    n,
    repair,
};

pub fn main(init: std.process.Init) if (@import("builtin").mode == .Debug) anyerror!void else void {
    mainInner(init) catch |err| switch (err) {
        error.CannotFindTodoDir => std.log.err("cannot find todo dir", .{}),
        error.MalformedTodoDir => std.log.err("your todo dir is malformed", .{}),
        else => |e| {
            if (@import("builtin").mode == .Debug) {
                return e;
            } else {
                std.log.err("{t}", .{e});
            }
        },
    };
}

pub fn mainInner(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args_iter = try init.minimal.args.iterateAllocator(arena);
    defer args_iter.deinit();

    _ = args_iter.skip();

    const first_arg = args_iter.next() orelse "help";
    const command = std.meta.stringToEnum(Command, first_arg) orelse {
        std.log.err("{s} is not a recognized command", .{first_arg});
        return error.UnexpectedArgument;
    };

    switch (command) {
        .init => {
            const args = try consumeArgs(&args_iter, InitArgs);
            try cmdInit(io, args, Dir.cwd());
            return;
        },
        else => {},
    }

    var path: Io.Writer.Allocating = try .initCapacity(arena, 2);
    defer path.deinit();

    try path.writer.writeAll("\"");

    var todo_dir = try findTodoDirWithPath(io, .{ .iterate = true }, &path.writer);
    defer todo_dir.close(io);

    var config = try Config.read(arena, io, todo_dir);

    //std.debug.print("{f}\n", .{config});

    switch (command) {
        .init => unreachable,
        .help => {
            var buf: [2048]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &buf);

            try stdout.interface.writeAll(
                \\todo
                \\  help                      show this dialogue
                \\  init <name>               create a .todo dir in the current directory named <name>
                \\  list, ls                  list todo items
                \\                              -a    list all details
                \\                              -h    list history
                \\  repair                    try to repair .todo dir
                \\
                \\  add, a <name|id>          add a todo item
                \\                              -m    add a message to the notes file
                \\  remove, rm <name|id>      remove todo item
                \\                              -y    don't ask for confirmation
                \\  status, stat <name|id>    print the status of an item
                \\                              -a    list all details
                \\                              -h    list history
                \\  start, on <name|id>       start working on a todo item
                \\  stop, off <name|id>       stop working on a todo item
                \\  complete, done <name|id>  complete a todo item
                \\  uncomplete <name|id>      uncomplete a todo item
                \\  notes, n <name|id>        print todo item's notes
                \\                              -p    print the path to the notes file. 
                \\                                    ex: `todo notes 9d -p | xargs nvim`
                \\
            );
            try stdout.flush();
        },
        .add, .a => {
            var rand_bytes: [4]u8 = undefined;
            io.random(&rand_bytes);
            const hex = std.fmt.bytesToHex(rand_bytes, .lower);

            const args = try consumeArgs(&args_iter, AddArgs);
            try cmdAdd(arena, io, args, &config, todo_dir, hex);
        },
        .remove, .rm => {
            const args = try consumeArgs(&args_iter, RemoveArgs);
            try cmdRemove(io, args, &config, todo_dir);
        },
        .status, .stat => {
            const args = try consumeArgs(&args_iter, StatusArgs);
            try cmdStatus(io, args, config, todo_dir);
        },
        .list, .ls => {
            var stdout_buf: [2048]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &stdout_buf);

            const args = try consumeArgs(&args_iter, ListArgs);
            try cmdList(io, args, config, todo_dir, &stdout.interface);
        },
        .start, .stop, .on, .off => {
            const com: Command = switch (command) {
                .start, .on => .start,
                .stop, .off => .stop,
                else => unreachable,
            };
            const args = try consumeArgs(&args_iter, StartStopArgs);
            try cmdStartStop(io, args, config, todo_dir, com);
        },
        .complete, .done => {
            const args = try consumeArgs(&args_iter, CompleteArgs);
            try cmdComplete(arena, io, args, &config, todo_dir);
        },
        .uncomplete => {
            const args = try consumeArgs(&args_iter, UncompleteArgs);
            try cmdUncomplete(io, args, &config, todo_dir);
        },
        .notes, .n => {
            var stdout_buf: [2048]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &stdout_buf);

            const args = try consumeArgs(&args_iter, NotesArgs);
            try cmdNotes(io, args, config, todo_dir, &path, &stdout.interface);
        },
        .repair => {
            try cmdRepair(arena, io, &config, todo_dir);
        },
    }

    try config.write(io, todo_dir);
}

const InitArgs = struct {
    pos: [1][]const u8,
};

fn cmdInit(io: Io, args: WrapArgs(InitArgs), cwd: Dir) !void {
    const name = args.posOrFatal(0, "name");

    var todo_dir = try cwd.createDirPathOpen(io, ".todo", .{});
    defer todo_dir.close(io);

    const config_file = try todo_dir.createFile(io, "config.json", .{});
    defer config_file.close(io);

    var buf: [2048]u8 = undefined;
    var fw = config_file.writer(io, &buf);

    try fw.interface.print(
        \\{{
        \\    "name": "{s}",
        \\    "items": {{}}
        \\}}
    , .{name});
    try fw.interface.flush();

    try todo_dir.createDir(io, "completed", .default_dir);
}

const AddArgs = struct {
    pos: [1][]const u8,
    m: ?[]const u8,
};

fn cmdAdd(arena: std.mem.Allocator, io: Io, args: WrapArgs(AddArgs), config: *Config, todo_dir: Dir, key: [8]u8) !void {
    const now: std.Io.Timestamp = .now(io, .real);

    const name = args.posOrFatal(0, "name");

    var buf: [2048]u8 = undefined;
    const name_with_ext = try arena.dupe(u8, nameWithExt(name, ".todo", &buf));

    try config.items.put(arena, key, .{ .path = name_with_ext });

    var todo_file = todo_dir.createFile(io, name_with_ext, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.log.err("'{s}' already exists", .{name});
            return error.TodoAlreadyExists;
        },
        else => |e| return e,
    };
    defer todo_file.close(io);

    {
        var fw = todo_file.writer(io, &buf);
        try fw.interface.print("{t}: {d}", .{ Status.created, now });
        try fw.flush();
    }

    if (args.inner.m) |msg| {
        const notes_path = nameWithExt(name, ".md", &buf);
        var notes_file = try todo_dir.createFile(io, notes_path, .{});
        defer notes_file.close(io);

        var fw = notes_file.writer(io, &buf);
        try fw.interface.print("{s}", .{msg});
        try fw.flush();
    }
}

const RemoveArgs = struct {
    pos: [1][]const u8,
    y: bool,
};

fn cmdRemove(io: Io, args: WrapArgs(RemoveArgs), config: *Config, todo_dir: Dir) !void {
    const name = args.posOrFatal(0, "name");

    if (std.mem.eql(u8, name, "config.json")) {
        std.log.err("Cannot delete 'config.json'", .{});
        return error.IllegalDelete;
    }

    const item = config.getItemOrFatal(name);

    var buf: [2048]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &buf);

    if (!args.inner.y) {
        var stdout = Io.File.stdout().writer(io, &.{});
        try stdout.interface.print("Are you sure you would like to remove '{s}'? (y/n): ", .{name});
    }

    const should_delete = args.inner.y or should_delete: {
        const input = try stdin.interface.takeDelimiter('\n') orelse break :should_delete false;
        break :should_delete input.len == 1 and std.ascii.toLower(input[0]) == 'y';
    };

    if (should_delete) {
        todo_dir.deleteFile(io, item.value.path) catch |err| switch (err) {
            error.FileNotFound => std.log.err("'{s}' not found", .{name}),
            else => |e| {
                std.log.err("Failed to delete todo item '{s}': {t}", .{ name, e });
                return err;
            },
        };

        _ = config.items.swapRemove(item.key);
    }
}

const StatusArgs = struct {
    a: bool,
    h: bool,
    pos: [1][]const u8,
};

fn cmdStatus(io: Io, args: WrapArgs(StatusArgs), config: Config, todo_dir: Dir) !void {
    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{});
    defer item_file.close(io);

    var read_buf: [2048]u8 = undefined;
    const item_status = try item_file.getLastStatus(io, item.value, &read_buf);

    var buf: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    try stdout.interface.print(
        \\on todo list {s}
        \\{f}
        \\
    , .{ config.name, Config.Item.Formatter{
        .all = args.inner.a,
        .history = args.inner.h,
        .key = item.key,
        .item = item.value,
        .status_char = item_status.status.char(),
        .timestamp = item_status.timestamp,
    } });

    if (args.inner.h) {
        try item_file.formatItemStatus(io, &stdout.interface);
    }

    try stdout.flush();
}

const ListArgs = struct {
    a: bool,
    h: bool,
};

fn cmdList(io: Io, args: WrapArgs(ListArgs), config: Config, todo_dir: Dir, stdout: *Io.Writer) !void {
    var buf: [2048]u8 = undefined;

    try stdout.print("on todo list {s}\n", .{config.name});

    for (config.items.keys(), config.items.values()) |k, v| {
        const item_file = try v.openFile(io, todo_dir, .{});
        defer item_file.close(io);

        const item_status = item_file.getLastStatus(io, v, &buf) catch {
            std.log.err("item '{s}'s corresponding file is missing", .{v.name()});
            continue;
        };

        try stdout.print("{f}\n", .{Config.Item.Formatter{
            .all = args.inner.a,
            .history = args.inner.h,
            .key = k,
            .item = v,
            .status_char = item_status.status.char(),
            .timestamp = item_status.timestamp,
        }});

        if (args.inner.h) {
            try item_file.formatItemStatus(io, stdout);
        }
    }

    try stdout.flush();
}

const StartStopArgs = struct {
    pos: [1][]const u8,
};

fn cmdStartStop(io: Io, args: WrapArgs(StartStopArgs), config: Config, todo_dir: Dir, command: Command) !void {
    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{ .mode = .read_write });
    defer item_file.close(io);

    var buf: [2048]u8 = undefined;
    const last_status = try item_file.getLastStatus(io, item.value, &buf);
    if (last_status.status == .restart) {
        std.log.err("{s} is completed, use 'uncomplete' to allow the item to be started", .{name});
    } else if (last_status.status == .started and command == .start) {
        std.log.err("{s} is already started", .{name});
    } else if (last_status.status != .started and command == .stop) {
        std.log.err("{s} is not started, it cannot be stopped", .{name});
    }

    try item_file.addStatus(io, switch (command) {
        .start => .started,
        .stop => .stopped,
        else => unreachable,
    }, &buf);
}

const CompleteArgs = struct {
    pos: [1][]const u8,
};

fn cmdComplete(arena: std.mem.Allocator, io: Io, args: WrapArgs(CompleteArgs), config: *Config, todo_dir: Dir) !void {
    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{ .mode = .read_write });
    defer item_file.close(io);

    var buf: [2048]u8 = undefined;
    const last_status = try item_file.getLastStatus(io, item.value, &buf);
    if (last_status.status == .finishd) {
        std.log.err("{s} is already completed", .{name});
    }

    const complete_dir = try todo_dir.openDir(io, "completed", .{});
    defer complete_dir.close(io);

    try item_file.addStatus(io, .finishd, &buf);
    try config.items.put(arena, item.key, .{ .path = try std.fmt.allocPrint(arena, "completed/{s}", .{item.value.path}) });

    try todo_dir.rename(item.value.path, complete_dir, item.value.path, io);

    const note_file_path = item.value.noteFile(&buf);
    if (todo_dir.rename(note_file_path, complete_dir, note_file_path, io)) {} else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
}

const UncompleteArgs = struct {
    pos: [1][]const u8,
};

fn cmdUncomplete(io: Io, args: WrapArgs(UncompleteArgs), config: *Config, todo_dir: Dir) !void {
    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{ .mode = .read_write });
    defer item_file.close(io);

    var buf: [2048]u8 = undefined;
    const last_status = try item_file.getLastStatus(io, item.value, &buf);
    if (last_status.status != .finishd) {
        std.log.err("{s} cannot be restarted if it is not completed", .{name});
        return;
    }

    try item_file.addStatus(io, .restart, &buf);
}

const NotesArgs = struct {
    p: bool,
    pos: [1][]const u8,
};

fn cmdNotes(io: Io, args: WrapArgs(NotesArgs), config: Config, todo_dir: Dir, path: ?*Io.Writer.Allocating, stdout: *Io.Writer) !void {
    var buf: [2048]u8 = undefined;
    const item = config.getItemOrFatal(args.posOrFatal(0, "name"));
    const name_with_ext = nameWithExt(item.value.withoutExt(), ".md", &buf);

    if (args.inner.p) {
        try path.?.writer.writeAll(name_with_ext);
        try path.?.writer.writeAll("\"");

        try stdout.writeAll(path.?.written());
        try stdout.flush();
        return;
    }

    const note_file = todo_dir.openFile(io, name_with_ext, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("NO FILE NAMED {s}!!\n", .{name_with_ext});
            return;
        },
        else => |e| return e,
    };
    defer note_file.close(io);

    var file_buf: [2048]u8 = undefined;
    var file_reader = note_file.reader(io, &file_buf);

    _ = try file_reader.interface.streamRemaining(stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn cmdRepair(arena: std.mem.Allocator, io: Io, config: *Config, todo_dir: Dir) !void {
    var buf: [2048]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &buf);
    var stdout = Io.File.stdout().writer(io, &.{});

    const complete_dir = try todo_dir.openDir(io, "completed", .{ .iterate = true });
    defer complete_dir.close(io);

    // items without corresponding files
    item_loop: for (config.items.keys(), config.items.values()) |k, v| {
        if (todo_dir.access(io, v.path, .{ .read = true, .write = true })) {} else |err| switch (err) {
            error.FileNotFound => {
                var todo_iter = todo_dir.iterate();
                while (try todo_iter.next(io)) |file| {
                    if (file.kind != .file or !mem.endsWith(u8, file.name, ".todo")) continue;

                    const name = Config.Item.name(.{ .path = file.name });
                    if (mem.eql(u8, name, v.name())) {
                        try config.items.put(arena, k, .{ .path = try arena.dupe(u8, file.name) });
                        std.log.info("found corresponding file for {s}", .{v.name()});
                        continue :item_loop;
                    }
                }

                var completed_iter = complete_dir.iterate();
                while (try completed_iter.next(io)) |file| {
                    if (file.kind != .file or !mem.endsWith(u8, file.name, ".todo")) continue;

                    const name = Config.Item.name(.{ .path = file.name });
                    if (mem.eql(u8, name, v.name())) {
                        try config.items.put(arena, k, .{ .path = try std.fmt.allocPrint(arena, "completed/{s}", .{file.name}) });
                        std.log.info("found corresponding file for {s} in completed/", .{v.name()});
                        continue :item_loop;
                    }
                }

                // couldnt find any corresponding file
                _ = config.items.swapRemove(k);
            },
            error.PermissionDenied => {
                std.log.err("{s} doesn't have adequite permissions, make sure you have read/write access", .{v.path});
            },
            else => |e| {
                std.log.err("unexpected error: {t}", .{e});
            },
        }
    }

    // items in wrong folder
    for (config.items.keys(), config.items.values()) |k, v| {
        const item_file = try v.openFile(io, todo_dir, .{ .mode = .read_write });
        defer item_file.close(io);

        const item_status = try item_file.getLastStatus(io, v, &buf);

        if (v.isInCompleted() and item_status.status != .finishd) {
            try stdout.interface.print("item '{s}' is in completed/ but not marked as complete. You can: (s)et status as complete, (r)emove, (i)gnore, or (m)ove to uncompleted\n(s/r/i/m): ", .{v.name()});
            try stdout.flush();

            const response = try stdin.interface.takeDelimiter('\n') orelse continue;
            switch (response[0]) {
                's' => try item_file.addStatus(io, .finishd, &buf),
                'r' => {
                    try complete_dir.deleteFile(io, v.path);
                    _ = config.items.swapRemove(k);
                },
                'm' => {
                    try complete_dir.rename(v.filename(), todo_dir, v.filename(), io);
                    try config.items.put(arena, k, .{ .path = v.filename() });
                },
                else => continue,
            }
        } else if (!v.isInCompleted() and item_status.status == .finishd) {
            try stdout.interface.print("item '{s}' is in .todo/ but is marked as complete. You can: (s)et status as uncomplete, (r)emove, (i)gnore, or (m)ove to completed\n(s/r/i/m): ", .{v.name()});
            try stdout.flush();

            const response = try stdin.interface.takeDelimiter('\n') orelse continue;
            switch (response[0]) {
                's' => try item_file.addStatus(io, .restart, &buf),
                'r' => {
                    try todo_dir.deleteFile(io, v.path);
                    _ = config.items.swapRemove(k);
                },
                'm' => {
                    try todo_dir.rename(v.path, complete_dir, v.path, io);
                    try config.items.put(arena, k, .{ .path = try std.fmt.allocPrint(arena, "completed/{s}", .{v.path}) });
                },
                else => continue,
            }
        }
    }

    // files without corresponding items
    // TODO
}

fn findTodoDir(io: std.Io, open_dir_options: Dir.OpenOptions) !Dir {
    var dcw = Io.Writer.Discarding.init(&.{});
    return findTodoDirWithPath(io, open_dir_options, &dcw.writer);
}

fn findTodoDirWithPath(io: std.Io, open_dir_options: Dir.OpenOptions, path_writer: *Io.Writer) !Dir {
    var depth: usize = 0;
    var cur = try Dir.cwd().openDir(io, ".", .{});

    const todo_dir: Dir = while (true) {
        const todo_dir = cur.openDir(io, ".todo", open_dir_options) catch {
            if (depth == 10) return error.CannotFindTodoDir;

            const parent = cur.openDir(io, "..", .{}) catch return error.CannotFindTodoDir;
            cur.close(io);
            cur = parent;

            depth += 1;

            try path_writer.writeAll("../");
            continue;
        };

        cur.close(io);
        try path_writer.writeAll(".todo/");
        break todo_dir;
    };

    if (todo_dir.access(io, "config.json", .{})) |_| {} else |_| {
        return error.MalformedTodoDir;
    }

    return todo_dir;
}

const Config = struct {
    name: []const u8,
    // "a1b2c3d4" => "item.todo",
    // "a1b2c3d4" => "completed/item2.todo"
    items: Map(Item.Key, Item),

    const Item = struct {
        path: []const u8,

        const Key = [8]u8;

        fn name(item: Item) []const u8 {
            const start_idx = if (item.isInCompleted()) "completed/".len else 0;
            return item.path[start_idx .. item.path.len - ".todo".len];
        }

        fn filename(item: Item) []const u8 {
            const start_idx = if (item.isInCompleted()) "completed/".len else 0;
            return item.path[start_idx..];
        }

        fn isInCompleted(item: Item) bool {
            return mem.startsWith(u8, item.path, "completed/");
        }

        fn withoutExt(item: Item) []const u8 {
            return item.path[0 .. item.path.len - ".todo".len];
        }

        fn openFile(item: Item, io: Io, todo_dir: Dir, options: Io.File.OpenFlags) !File {
            return .{ .inner = try todo_dir.openFile(io, item.path, options) };
        }

        fn noteFile(item: Item, out_buf: []u8) []const u8 {
            const nwe = item.withoutExt();
            @memcpy(out_buf[0..nwe.len], nwe);
            @memcpy(out_buf[nwe.len..][0..3], ".md");
            return out_buf[0 .. nwe.len + 3];
        }

        const File = struct {
            inner: Io.File,

            fn close(file: File, io: Io) void {
                file.inner.close(io);
            }

            fn addStatus(file: File, io: Io, status: Status, buf: []u8) !void {
                const now: std.Io.Timestamp = .now(io, .real);

                var td_writer = file.inner.writer(io, buf);
                try td_writer.seekTo(try file.inner.length(io));
                try td_writer.interface.print("\n{t}: {}", .{ status, now.nanoseconds });
                try td_writer.interface.flush();
            }

            fn getLastStatus(file: File, io: Io, item: Item, buf: []u8) !struct {
                status: Status,
                timestamp: []const u8,
            } {
                var reader = file.inner.reader(io, buf);

                var last_line_maybe: ?[]const u8 = null;
                while (try reader.interface.takeDelimiter('\n')) |line| {
                    if (line.len == 0) continue;
                    last_line_maybe = line;
                }

                const last_line = last_line_maybe orelse {
                    std.log.err("malformed todo item: {s}, file is empty", .{item.name()});
                    return error.TodoItemEmpty;
                };

                const colon_idx = std.mem.indexOfScalar(u8, last_line, ':') orelse {
                    std.log.err("malformed todo item: {s}, found {s} as latest status", .{ item.name(), last_line });
                    return error.MalformedTodoItem;
                };
                const status_word = last_line[0..colon_idx];
                const timestamp_str = last_line[colon_idx + 2 ..];

                const status = std.meta.stringToEnum(Status, status_word) orelse {
                    std.log.err("malformed todo item: {s}, found {s} as status", .{ item.name(), status_word });
                    return error.UnknownStatusForTodoItem;
                };

                return .{
                    .status = status,
                    .timestamp = timestamp_str,
                };
            }

            fn formatItemStatus(file: File, io: Io, w: *Io.Writer) !void {
                var read_buf: [2048]u8 = undefined;
                var reader = file.inner.reader(io, &read_buf);

                try w.writeAll("=================================\n");
                while (try reader.interface.takeDelimiter('\n')) |line| {
                    var space_iter = mem.splitScalar(u8, line, ' ');
                    const status_str = space_iter.next().?;
                    const timestamp = space_iter.next().?;
                    try w.print("{s} {s}\n", .{ status_str, try Formatter.formatTimestamp(timestamp) });
                }
            }
        };

        const Formatter = struct {
            all: bool,
            history: bool,
            item: Item,
            key: Key,
            status_char: u8,
            timestamp: []const u8,

            pub fn format(f: Formatter, w: *Io.Writer) !void {
                if (f.all) {
                    try w.print("\nstatus:  ({c}) {s}\nhash:    {s}\ndate:    {s}", .{
                        f.status_char,
                        f.item.name(),
                        f.key,
                        try formatTimestamp(f.timestamp),
                    });
                } else if (f.history) {
                    try w.print("\n[{s}] ({c}) {s}", .{ f.key, f.status_char, f.item.name() });
                } else {
                    try w.print("    [{s}] ({c}) {s}", .{ f.key, f.status_char, f.item.name() });
                }
            }

            fn formatTimestamp(ts_raw_str: []const u8) ![]const u8 {
                const ts_int = std.fmt.parseInt(u64, ts_raw_str, 10) catch return error.WriteFailed;
                const ts: Io.Timestamp = .{ .nanoseconds = ts_int };
                const ts_sec = ts.toSeconds();
                const ts_cstr = c.ctime(&ts_sec);
                const ts_str = mem.span(ts_cstr);
                return ts_str[0 .. ts_str.len - 1];
            }
        };
    };

    fn write(config: *Config, io: Io, todo_dir: Dir) !void {
        var config_file = try todo_dir.createFile(io, "config.json", .{});
        defer config_file.close(io);

        var writer = config_file.writer(io, &.{});

        try std.json.Stringify.value(config.*, .{}, &writer.interface);
    }

    fn deinit(config: *Config, gpa: std.mem.Allocator) void {
        gpa.free(config.name);
        for (config.items.values()) |v|
            gpa.free(v.path);
        config.items.deinit(gpa);
    }

    fn read(gpa: std.mem.Allocator, io: Io, todo_dir: Dir) !Config {
        var config_file = try todo_dir.openFile(io, "config.json", .{});
        defer config_file.close(io);

        var buf: [2048]u8 = undefined;
        var config_reader = config_file.reader(io, &buf);

        var config_js = std.json.Reader.init(gpa, &config_reader.interface);

        var diag: std.json.Diagnostics = .{};
        config_js.scanner.enableDiagnostics(&diag);
        errdefer {
            std.log.err("json error: {}:{}:{}", .{ diag.getLine(), diag.getColumn(), diag.getByteOffset() });
        }

        return std.json.parseFromTokenSourceLeaky(Config, gpa, &config_js, .{});
    }

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const value: std.json.Value = try std.json.innerParse(std.json.Value, gpa, source, options);

        var config: Config = .{
            .name = &.{},
            .items = .empty,
        };

        config.name = value.object.get("name").?.string;

        const items = value.object.get("items").?.object;
        for (items.keys(), items.values()) |k, v| {
            try config.items.put(gpa, k[0..8].*, try std.json.parseFromValueLeaky(Item, gpa, v, options));
        }

        return config;
    }

    pub fn jsonStringify(config: Config, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();

        try stringify.objectField("name");
        try stringify.write(config.name);

        try stringify.objectField("items");
        try stringify.beginObject();

        for (config.items.keys(), config.items.values()) |k, v| {
            try stringify.objectField(&k);
            try stringify.write(v);
        }

        try stringify.endObject();
        try stringify.endObject();
    }

    const ItemAndKey = struct {
        key: [8]u8,
        value: Item,
    };

    fn getItem(config: Config, id_or_name: []const u8) ?ItemAndKey {
        var best_len: usize = 0;
        var best_is_complete = false;
        var best_value: Item = .{ .path = &.{} };
        var best_key: [8]u8 = @splat(0);

        for (config.items.keys(), config.items.values()) |id, item| {
            const len = eqlLen(&id, id_or_name);
            if (len > best_len) {
                //std.debug.print("1: {s}, score {} -> {}\n", .{ id, best_len, len });
                best_len = len;
                best_is_complete = id_or_name.len == len;
                best_value = item;
                best_key = id;
            } else if (best_len > 0 and len == best_len) {
                // ambiguous
                best_len = 0;
                best_is_complete = false;
            }
        }

        if (best_is_complete) {
            return .{ .key = best_key, .value = best_value };
        }

        for (config.items.keys(), config.items.values()) |id, item| {
            const len = eqlLen(item.name(), id_or_name);
            if (len > best_len) {
                //std.debug.print("2: {s}, score {} -> {}\n", .{ item.name(), best_len, len });
                best_len = len;
                best_is_complete = id_or_name.len == len;
                best_value = item;
                best_key = id;
            } else if (best_len > 0 and len == best_len) {
                // ambiguous
                return null;
            }
        }

        if (best_len == 0) {
            return null;
        }

        return .{ .key = best_key, .value = best_value };
    }

    fn getItemOrFatal(config: Config, id_or_name: []const u8) ItemAndKey {
        return config.getItem(id_or_name) orelse {
            std.log.err("todo item with name/id '{s}' not found", .{id_or_name});
            std.process.exit(1);
        };
    }

    fn eqlLen(a: []const u8, b: []const u8) usize {
        if (mem.eql(u8, a, b)) return a.len;
        const min_len = @min(a.len, b.len);
        if (!mem.eql(u8, a[0..min_len], b[0..min_len])) return 0;
        return min_len;
    }

    fn openItem(config: Config, io: Io, todo_dir: Dir, id_or_name: []const u8) !Item.File {
        return try (config.getItem(id_or_name) orelse return error.ItemNotFound).open(io, todo_dir);
    }

    pub fn format(config: Config, w: *Io.Writer) !void {
        try w.print(
            \\{{
            \\    "name": "{s}",
            \\    "items": {{
            \\
        , .{config.name});
        for (config.items.keys(), config.items.values()) |k, v| {
            try w.print(
                \\        "{s}" => "{s}"
                \\
            , .{ k, v.path });
        }
        try w.writeAll(
            \\    }
            \\}
        );
    }
};

fn nameWithExt(name: []const u8, ext: []const u8, out_buf: []u8) []u8 {
    @memcpy(out_buf[0..name.len], name);
    @memcpy(out_buf[name.len..][0..ext.len], ext);
    return out_buf[0 .. name.len + ext.len];
}

fn WrapArgs(Args: type) type {
    return struct {
        args_len: usize,
        inner: Args,

        const empty: @This() = .{
            .args_len = 0,
            .inner = inner: {
                var args: Args = undefined;
                for (@typeInfo(Args).@"struct".fields) |f| {
                    @field(args, f.name) = switch (@typeInfo(f.type)) {
                        .bool => false,
                        .optional => null,
                        .array => undefined,
                        else => @compileError(f.name ++ "'s type is no good"),
                    };
                }
                break :inner args;
            },
        };

        fn initStatic(inner: Args) @This() {
            return .{
                .inner = inner,
                .args_len = if (@hasField(Args, "pos")) inner.pos.len else 0,
            };
        }

        fn pos(a: @This()) []const []const u8 {
            return a.inner.pos[0..a.args_len];
        }

        fn posOrNull(a: @This(), i: usize) ?[]const u8 {
            if (i >= a.args_len) return null;
            return a.inner.pos[i];
        }

        fn posOrFatal(a: @This(), i: usize, name: []const u8) []const u8 {
            return a.posOrNull(i) orelse {
                std.log.err("expected argument for '{s}' in position {}", .{ name, i });
                std.process.exit(1);
            };
        }
    };
}

fn consumeArgs(args_iter: *std.process.Args.Iterator, Args: type) !WrapArgs(Args) {
    var args: WrapArgs(Args) = .empty;

    arg_loop: while (args_iter.next()) |arg| {
        inline for (@typeInfo(Args).@"struct".fields) |f| {
            if (arg[0] != '-') {
                if (@hasField(Args, "pos")) {
                    if (args.args_len >= args.inner.pos.len) {
                        std.log.err("too many positional arguments", .{});
                        return error.TooManyArgs;
                    }

                    args.inner.pos[args.args_len] = arg;
                    args.args_len += 1;
                    continue :arg_loop;
                } else {
                    std.log.err("positional arguments not expected", .{});
                    return error.PositionalArgument;
                }
            } else if (mem.eql(u8, f.name, arg[1..])) {
                if (f.type == bool) {
                    @field(args.inner, f.name) = true;
                } else if (f.type == []const u8 or f.type == ?[]const u8) {
                    if (!mem.endsWith(u8, arg, "=")) {
                        @field(args.inner, f.name) = args_iter.next() orelse {
                            std.log.err("argument '{s}' expected a value", .{f.name});
                            return error.NamedArgWithoutValue;
                        };
                        continue :arg_loop;
                    }

                    // expecting -arg_name=...
                    if (arg.len < f.name.len + 2) {
                        std.log.err("argument '{s}' malformed", .{f.name});
                        return error.MalformedArgument;
                    }

                    @field(args.inner, f.name) = arg[f.name.len + 2 ..];
                }
                continue :arg_loop;
            } else if (arg[0] == '-' and f.type == bool) {
                for (arg[1..]) |flag_char| {
                    if (mem.eql(u8, f.name, &.{flag_char})) {
                        @field(args.inner, f.name) = true;
                    }
                }
            }
        }
    }

    return args;
}

test "general" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var stdout: Io.Writer.Allocating = .init(gpa);
    defer stdout.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try cmdInit(io, .initStatic(.{ .pos = .{"test"} }), temp_dir.dir);

    var todo_dir = try temp_dir.dir.openDir(io, ".todo", .{});
    defer todo_dir.close(io);

    var config: Config = try .read(arena, io, todo_dir);

    try cmdAdd(arena, io, .initStatic(.{ .pos = .{"item-1"}, .m = null }), &config, todo_dir, "a1b2c3d4".*);
    try cmdAdd(arena, io, .initStatic(.{ .pos = .{"item-2"}, .m = "item-2 notes" }), &config, todo_dir, "e5f6g7h8".*);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on todo list test
        \\    [a1b2c3d4] ( ) item-1
        \\    [e5f6g7h8] ( ) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdStartStop(io, .initStatic(.{ .pos = .{"item-1"} }), config, todo_dir, .start);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on todo list test
        \\    [a1b2c3d4] (o) item-1
        \\    [e5f6g7h8] ( ) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdComplete(arena, io, .initStatic(.{ .pos = .{"e5"} }), &config, todo_dir);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on todo list test
        \\    [a1b2c3d4] (o) item-1
        \\    [e5f6g7h8] (x) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdNotes(io, .initStatic(.{ .pos = .{"e5"}, .p = false }), config, todo_dir, null, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\item-2 notes
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdUncomplete(io, .initStatic(.{ .pos = .{"e5"} }), &config, todo_dir);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on todo list test
        \\    [a1b2c3d4] (o) item-1
        \\    [e5f6g7h8] ( ) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdRemove(io, .initStatic(.{ .pos = .{"a1"}, .y = true }), &config, todo_dir);

    try config.write(io, todo_dir);
}

const std = @import("std");
const c = @import("c");
const mem = std.mem;
const Io = std.Io;
const Dir = Io.Dir;
const Map = std.AutoArrayHashMapUnmanaged;
