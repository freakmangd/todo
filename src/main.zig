const timestamp_format = "YYYY-MM-DD HH:mm:ss z";
const config_file_path = "config.json";
const todo_dir_path = ".todo";
const todo_item_ext = ".todo";
const note_file_ext = ".md";
const completed_path = "completed";

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

    set,

    install_completions,
    completions,
};

pub fn main(init: std.process.Init) if (@import("builtin").mode == .Debug) anyerror!void else void {
    mainInner(init) catch |err| {
        switch (err) {
            error.CannotFindTodoDir => std.log.err("cannot find todo dir", .{}),
            error.MalformedTodoDir => std.log.err("your .todo dir is malformed, try using 'repair'", .{}),
            else => {},
        }

        return err;
    };
}

pub fn mainInner(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args_iter = try init.minimal.args.iterateAllocator(arena);
    defer args_iter.deinit();

    const exe_path = args_iter.next();
    _ = &exe_path;

    var buf: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);

    const term: Io.Terminal = .{
        .writer = &stdout.interface,
        .mode = try .detect(io, .stdout(), init.environ_map.contains("NO_COLOR"), init.environ_map.contains("CLICOLOR_FORCE")),
    };

    const first_arg = args_iter.next() orelse arg: {
        // running without args
        var todo_dir = findTodoDir(io, .{}) catch {
            std.log.err("no .todo dir found", .{});
            break :arg "help";
        };
        defer todo_dir.close(io);

        const config = try Config.read(arena, io, todo_dir, &buf);

        const args = try consumeArgs(&args_iter, ListArgs);
        try cmdList(io, args, config, todo_dir, term);

        return;
    };

    const command = meta.stringToEnum(Command, first_arg) orelse unknown_command: {
        // try interpreting as an id and stat it
        var todo_dir = findTodoDir(io, .{}) catch break :unknown_command .help;
        defer todo_dir.close(io);

        const config = try Config.read(arena, io, todo_dir, &buf);

        if (first_arg[0] == '-') {
            // treat as args for ls
            var args = try consumeArgs(&args_iter, ListArgs);
            readTack(ListArgs, first_arg, &args.inner);
            try cmdList(io, args, config, todo_dir, term);
            return;
        } else stat: {
            // treat as `stat name`
            _ = config.getItem(first_arg) orelse break :stat;

            var args = try consumeArgs(&args_iter, StatusArgs);
            args.inner.pos[0] = first_arg;
            args.args_len = 1;
            try cmdStatus(io, args, config, todo_dir, term);
            return;
        }

        std.log.err("'{s}' is not a recognized command", .{first_arg});
        return error.UnexpectedArgument;
    };

    switch (command) {
        .help => {
            try stdout.interface.writeAll(
                \\tak
                \\    help                        show this dialogue
                \\    init <name>                 create a .todo dir in the current directory named <name>
                \\    list, ls                    list todo items
                \\                                  -a    list all details
                \\                                  -d    list more details
                \\                                  -h    list history
                \\                                  -n    print notes
                \\    repair                      try to repair .todo dir
                \\
                \\    add, a <name|id>            add a todo item
                \\                                  -m    add a message to the notes file
                \\    remove, rm <name|id>        remove todo item
                \\                                  -y    don't ask for confirmation
                \\    status, stat <name|id>      print the status of an item
                \\                                  -a    list all details
                \\                                  -d    list more details
                \\                                  -h    list history
                \\                                  -n    print notes
                \\    start, on <name|id>         start working on a todo item
                \\    stop, off <name|id>         stop working on a todo item
                \\                                  -a    stop all items on current list
                \\    complete, done <name|id>    complete a todo item
                \\    uncomplete <name|id>        uncomplete a todo item
                \\    notes, n <name|id>          print todo item's notes
                \\                                  -p    print the path to the notes file. 
                \\                                        ex: `todo notes 9d -p | xargs nvim`
                \\
            );
            try stdout.flush();
            return;
        },
        .init => {
            const args = try consumeArgs(&args_iter, InitArgs);
            try cmdInit(io, args, Dir.cwd(), &buf);
            return;
        },
        .repair => {
            //try cmdRepair(arena, io, &config, todo_dir, &stdout.interface);
            return;
        },
        else => {},
    }

    var path: Io.Writer.Allocating = try .initCapacity(arena, ("\"" ++ todo_dir_path ++ "/\"").len);
    defer path.deinit();

    try path.writer.writeByte('"');

    var todo_dir = try findTodoDirWithPath(io, .{ .iterate = true }, &path.writer);
    defer todo_dir.close(io);

    var config = try Config.read(arena, io, todo_dir, &buf);

    var user = User.init(arena, io, init.environ_map, todo_dir, &buf);
    defer user.deinit(io);

    //std.debug.print("{f}\n", .{config});

    switch (command) {
        .init, .help, .repair => unreachable,
        .add, .a => {
            var rand_bytes: [4]u8 = undefined;
            io.random(&rand_bytes);
            const hex = std.fmt.bytesToHex(rand_bytes, .lower);

            const args = try consumeArgs(&args_iter, AddArgs);
            try cmdAdd(arena, io, args, &config, todo_dir, hex, &buf);
        },
        .remove, .rm => {
            const args = try consumeArgs(&args_iter, RemoveArgs);
            try cmdRemove(io, args, &config, todo_dir, &buf);
        },
        .status, .stat => {
            const args = try consumeArgs(&args_iter, StatusArgs);
            try cmdStatus(io, args, config, todo_dir, term);
        },
        .list, .ls => {
            const args = try consumeArgs(&args_iter, ListArgs);
            try cmdList(io, args, config, todo_dir, term);
        },
        .start, .stop, .on, .off => {
            const com: Command = switch (command) {
                .start, .on => .start,
                .stop, .off => .stop,
                else => unreachable,
            };
            const args = try consumeArgs(&args_iter, StartStopArgs);
            try cmdStartStop(io, args, config, todo_dir, com, &buf);
        },
        .complete, .done => {
            const args = try consumeArgs(&args_iter, CompleteArgs);
            try cmdComplete(arena, io, args, &config, todo_dir, &buf);
        },
        .uncomplete => {
            const args = try consumeArgs(&args_iter, UncompleteArgs);
            try cmdUncomplete(io, args, &config, todo_dir, &buf);
        },
        .notes, .n => {
            const args = try consumeArgs(&args_iter, NotesArgs);
            try cmdNotes(io, args, config, todo_dir, &path, &stdout.interface, &buf);
        },
        .install_completions => {
            const args = try consumeArgs(&args_iter, struct {
                pos: [1][]const u8,
            });
            const shell = meta.stringToEnum(Shell, args.posOrFatal(0, "shell name")) orelse {
                std.log.err("unsupported shell for completions :(", .{});
                return error.UnsupportedShell;
            };

            switch (shell) {
                .bash => try stdout.interface.writeAll(@embedFile("completions.bash")),
                .zsh => try stdout.interface.writeAll(@embedFile("completions.zsh")),
                .fish => try stdout.interface.writeAll(@embedFile("completions.fish")),
            }
            try stdout.flush();
            return;
        },
        .completions => {
            const args = try consumeArgs(&args_iter, struct {
                pos: [1][]const u8,
            });
            const shell = meta.stringToEnum(Shell, args.posOrFatal(0, "shell name")) orelse {
                std.log.err("unsupported shell for completions :(", .{});
                return error.UnsupportedShell;
            };

            switch (shell) {
                .bash => {},
                .zsh => {
                    for (config.items.keys(), config.items.values()) |k, v| {
                        try stdout.interface.print("{s}:{s}\n", .{ k, v.name() });
                    }
                },
                .fish => {},
            }
            try stdout.flush();
            return;
        },
        .set => {
            const args = try consumeArgs(&args_iter, struct {
                pos: [2][]const u8,
            });
            const name = args.posOrFatal(0, "name");

            const key = meta.stringToEnum(meta.FieldEnum(User.Data), name) orelse {
                std.log.err("'{s}' is not an available value", .{name});
                return error.UnknownUserConfigName;
            };
            switch (key) {
                inline else => |k| {
                    @field(user.data, @tagName(k)) = args.posOrFatal(1, "value");
                },
            }
        },
    }

    // TODO: maybe only write if config is dirty?
    try config.write(io, todo_dir);
    try user.write(
        io,
    );
}

const InitArgs = struct {
    pos: [1][]const u8,
};

fn cmdInit(io: Io, args: WrapArgs(InitArgs), cwd: Dir, buf: []u8) !void {
    const name = args.posOrFatal(0, "name");

    if (cwd.openDir(io, todo_dir_path, .{})) |dir| {
        dir.close(io);
        std.log.err("path already has a .todo dir", .{});
        return;
    } else |_| {}

    var todo_dir = try cwd.createDirPathOpen(io, todo_dir_path, .{});
    defer todo_dir.close(io);

    const config_file = try todo_dir.createFile(io, config_file_path, .{});
    defer config_file.close(io);

    try Config.firstWrite(io, config_file, name, buf);

    try todo_dir.createDir(io, completed_path, .default_dir);
}

const AddArgs = struct {
    pos: [1][]const u8,
    m: ?[]const u8 = null,
};

fn cmdAdd(arena: std.mem.Allocator, io: Io, args: WrapArgs(AddArgs), config: *Config, todo_dir: Dir, key: [8]u8, buf: []u8) !void {
    const now: std.Io.Timestamp = .now(io, .real);

    const name = args.posOrFatal(0, "name");
    const name_with_ext = try arena.dupe(u8, nameWithExt(name, todo_item_ext, buf));

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
        var fw = todo_file.writer(io, buf);
        try fw.interface.print("{t} {d}", .{ Status.created, now });
        try fw.flush();
    }

    if (args.inner.m) |msg| {
        const notes_path = nameWithExt(name, note_file_ext, buf);
        var notes_file = try todo_dir.createFile(io, notes_path, .{});
        defer notes_file.close(io);

        var fw = notes_file.writer(io, buf);
        try fw.interface.print("{s}", .{msg});
        try fw.flush();
    }
}

const RemoveArgs = struct {
    pos: [1][]const u8,
    y: bool = false,
};

fn cmdRemove(io: Io, args: WrapArgs(RemoveArgs), config: *Config, todo_dir: Dir, buf: []u8) !void {
    const name = args.posOrFatal(0, "name");

    if (std.mem.eql(u8, name, config_file_path)) {
        std.log.err("Cannot delete 'config.json'", .{});
        return error.IllegalDelete;
    }

    const item = config.getItemOrFatal(name);

    const should_delete = args.inner.y or should_delete: {
        var stdin = Io.File.stdin().reader(io, buf);
        var stdout = Io.File.stdout().writer(io, &.{});
        try stdout.interface.print("Are you sure you would like to remove '{s}'? (y/n): ", .{name});
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
    pos: [1][]const u8,
    a: bool = false,
    d: bool = false,
    h: bool = false,
    n: bool = false,
};

fn cmdStatus(io: Io, args: WrapArgs(StatusArgs), config: Config, todo_dir: Dir, term: Io.Terminal) !void {
    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{});
    defer item_file.close(io);

    var read_buf: [2048]u8 = undefined;

    const note_file = item.value.openNoteFile(io, todo_dir, .{}, &read_buf);
    defer note_file.close(io);

    const item_status = try item_file.getStatus(io, item.value, &read_buf);

    const fmt: Config.Item.Formatter = .{
        .details = args.inner.a or args.inner.d,
        .history = args.inner.a or args.inner.h,
        .notes = args.inner.a or args.inner.n,
        .key = item.key,
        .item = item.value,
        .item_status = item_status,
        .notes_file = note_file,
    };

    try term.writer.print(
        \\on list {s}
    , .{config.name});

    try fmt.formatTerm(term);
    try term.writer.writeByte('\n');

    if (args.inner.a or args.inner.h) {
        try item_file.formatItemStatus(io, term.writer);
    }

    try term.writer.flush();
}

const ListArgs = struct {
    a: bool = false,
    d: bool = false,
    h: bool = false,
    n: bool = false,
};

fn cmdList(io: Io, args: WrapArgs(ListArgs), config: Config, todo_dir: Dir, term: Io.Terminal) !void {
    var buf: [2048]u8 = undefined;

    try term.writer.print("on list {s}\n", .{config.name});

    for (config.items.keys(), config.items.values()) |k, v| {
        const item_file = try v.openFile(io, todo_dir, .{});
        defer item_file.close(io);

        const note_file = v.openNoteFile(io, todo_dir, .{}, &buf);
        defer note_file.close(io);

        const item_status = item_file.getStatus(io, v, &buf) catch continue;

        const fmt: Config.Item.Formatter = .{
            .details = args.inner.a or args.inner.d,
            .history = args.inner.a or args.inner.h,
            .notes = args.inner.a or args.inner.n,
            .key = k,
            .item = v,
            .item_status = item_status,
            .notes_file = note_file,
        };

        try fmt.formatTerm(term);
        try term.writer.writeAll("\n");

        if (args.inner.a or args.inner.h) {
            try item_file.formatItemStatus(io, term.writer);
        }
    }

    try term.writer.flush();
}

const StartStopArgs = struct {
    pos: [1][]const u8,
    a: bool = false,
};

fn cmdStartStop(io: Io, args: WrapArgs(StartStopArgs), config: Config, todo_dir: Dir, command: Command, buf: []u8) !void {
    if (args.inner.a) {
        if (command != .stop) {
            std.log.err("-a is only for 'stop'", .{});
            return error.InvalidFlag;
        }

        for (config.items.values()) |v| {
            var f = try v.openFile(io, todo_dir, .{ .mode = .read_write });
            const status = f.getStatus(io, v, buf) catch continue;

            if (status.latest.status == .started) {
                try f.addStatus(io, .stopped, buf);
            }
        }

        return;
    }

    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{ .mode = .read_write });
    defer item_file.close(io);

    const status = try item_file.getStatus(io, item.value, buf);
    if (status.latest.status == .restart) {
        std.log.err("{s} is completed, use 'uncomplete' to allow the item to be started", .{name});
    } else if (status.latest.status == .started and command == .start) {
        std.log.err("{s} is already started", .{name});
    } else if (status.latest.status != .started and command == .stop) {
        std.log.err("{s} is not started, it cannot be stopped", .{name});
    }

    try item_file.addStatus(io, switch (command) {
        .start => .started,
        .stop => .stopped,
        else => unreachable,
    }, buf);
}

const CompleteArgs = struct {
    pos: [1][]const u8,
};

fn cmdComplete(arena: std.mem.Allocator, io: Io, args: WrapArgs(CompleteArgs), config: *Config, todo_dir: Dir, buf: []u8) !void {
    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{ .mode = .read_write });
    defer item_file.close(io);

    const status = try item_file.getStatus(io, item.value, buf);
    if (status.latest.status == .finishd) {
        std.log.err("{s} is already completed", .{name});
    }

    const complete_dir = try todo_dir.openDir(io, completed_path, .{});
    defer complete_dir.close(io);

    try item_file.addStatus(io, .finishd, buf);
    try config.items.put(arena, item.key, .{ .path = try std.fmt.allocPrint(arena, completed_path ++ "/{s}", .{item.value.path}) });

    try todo_dir.rename(item.value.path, complete_dir, item.value.path, io);

    const note_file_path = item.value.noteFile(buf);
    if (todo_dir.rename(note_file_path, complete_dir, note_file_path, io)) {} else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
}

const UncompleteArgs = struct {
    pos: [1][]const u8,
};

fn cmdUncomplete(io: Io, args: WrapArgs(UncompleteArgs), config: *Config, todo_dir: Dir, buf: []u8) !void {
    const name = args.posOrFatal(0, "name");
    const item = config.getItemOrFatal(name);

    const item_file = try item.value.openFile(io, todo_dir, .{ .mode = .read_write });
    defer item_file.close(io);

    const status = try item_file.getStatus(io, item.value, buf);
    if (status.latest.status != .finishd) {
        std.log.err("{s} cannot be restarted if it is not completed", .{name});
        return;
    }

    try item_file.addStatus(io, .restart, buf);
}

const NotesArgs = struct {
    pos: [1][]const u8,
    p: bool = false,
};

fn cmdNotes(io: Io, args: WrapArgs(NotesArgs), config: Config, todo_dir: Dir, path: ?*Io.Writer.Allocating, stdout: *Io.Writer, buf: []u8) !void {
    const item = config.getItemOrFatal(args.posOrFatal(0, "name"));
    const name_with_ext = nameWithExt(item.value.withoutExt(), note_file_ext, buf);

    if (args.inner.p) {
        try path.?.writer.writeAll(name_with_ext);
        try path.?.writer.writeByte('"');

        try stdout.writeAll(path.?.written());
        try stdout.flush();
        return;
    }

    const note_file = todo_dir.openFile(io, name_with_ext, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer note_file.close(io);

    var file_buf: [2048]u8 = undefined;
    var file_reader = note_file.reader(io, &file_buf);

    _ = try file_reader.interface.streamRemaining(stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn cmdRepair(arena: std.mem.Allocator, io: Io, cwd: Dir, stdout: *Io.Writer) !void {
    var buf: [2048]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &buf);

    const todo_dir = try findTodoDir(io, cwd, .{});
    defer todo_dir.close(io);

    const complete_dir = try todo_dir.openDir(io, completed_path, .{ .iterate = true });
    defer complete_dir.close(io);

    // missing config.json
    const config = Config.read(arena, io, todo_dir, &buf) catch |err| if (err == error.NoConfigFile) {
        const config_file = try todo_dir.createFile(io, config_file_path, .{});
        defer config_file.close(io);

        try stdout.print("missing a config.json file, would you like to create one?\n(y)es/(a)bort:", .{});
        try stdout.flush();

        const name = try arena.dupe(u8, try stdin.interface.takeDelimiter('\n') orelse return);
        try Config.firstWrite(io, config_file, name, buf);
    } else return err;

    // items without corresponding files
    item_loop: for (config.items.keys(), config.items.values()) |k, v| {
        if (todo_dir.access(io, v.path, .{ .read = true, .write = true })) {} else |err| switch (err) {
            error.FileNotFound => {
                var todo_iter = todo_dir.iterate();
                while (try todo_iter.next(io)) |file| {
                    if (file.kind != .file or !mem.endsWith(u8, file.name, todo_item_ext)) continue;

                    const name = Config.Item.name(.{ .path = file.name });
                    if (mem.eql(u8, name, v.name())) {
                        try config.items.put(arena, k, .{ .path = try arena.dupe(u8, file.name) });
                        std.log.info("found corresponding file for {s}", .{v.name()});
                        continue :item_loop;
                    }
                }

                var completed_iter = complete_dir.iterate();
                while (try completed_iter.next(io)) |file| {
                    if (file.kind != .file or !mem.endsWith(u8, file.name, todo_item_ext)) continue;

                    const name = Config.Item.name(.{ .path = file.name });
                    if (mem.eql(u8, name, v.name())) {
                        try config.items.put(arena, k, .{ .path = try std.fmt.allocPrint(arena, completed_path ++ "/{s}", .{file.name}) });
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

        const item_status = try item_file.getStatus(io, v, &buf);

        if (v.isInCompleted() and item_status.latest.status != .finishd) {
            try stdout.print("item '{s}' is in completed/ but not marked as complete. You can: (s)et status as complete, (r)emove, (i)gnore, or (m)ove to uncompleted\n(s/r/i/m): ", .{v.name()});
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
        } else if (!v.isInCompleted() and item_status.latest.status == .finishd) {
            try stdout.print("item '{s}' is in .todo/ but is marked as complete. You can: (s)et status as uncomplete, (r)emove, (i)gnore, or (m)ove to completed\n(s/r/i/m): ", .{v.name()});
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
                    try config.items.put(arena, k, .{ .path = try std.fmt.allocPrint(arena, completed_path ++ "/{s}", .{v.path}) });
                },
                else => continue,
            }
        }
    }

    // files without corresponding items
    // TODO
}

fn findTodoDir(io: std.Io, cwd: Dir, open_dir_options: Dir.OpenOptions) !Dir {
    var dcw = Io.Writer.Discarding.init(&.{});
    return findTodoDirWithPath(io, cwd, open_dir_options, &dcw.writer);
}

fn findTodoDirWithPath(io: std.Io, cwd: Dir, open_dir_options: Dir.OpenOptions, path_writer: *Io.Writer) !Dir {
    var depth: usize = 0;
    const max_depth = 10;

    var cur = try cwd.openDir(io, ".", .{});

    const todo_dir: Dir = while (true) {
        const todo_dir = cur.openDir(io, todo_dir_path, open_dir_options) catch {
            if (depth >= max_depth) return error.CannotFindTodoDir;

            const parent = cur.openDir(io, "..", .{}) catch return error.CannotFindTodoDir;
            cur.close(io);
            cur = parent;

            depth += 1;

            try path_writer.writeAll("../");
            continue;
        };

        cur.close(io);
        try path_writer.writeAll(todo_dir_path ++ "/");
        break todo_dir;
    };

    if (todo_dir.access(io, config_file_path, .{})) |_| {} else |_| {
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
            const file_name = item.filename();
            return file_name[0 .. file_name.len - todo_item_ext.len];
        }

        fn filename(item: Item) []const u8 {
            const start_idx = if (item.isInCompleted()) (completed_path ++ "/").len else 0;
            return item.path[start_idx..];
        }

        fn isInCompleted(item: Item) bool {
            return mem.startsWith(u8, item.path, completed_path ++ "/");
        }

        fn withoutExt(item: Item) []const u8 {
            return item.path[0 .. item.path.len - todo_item_ext.len];
        }

        fn openFile(item: Item, io: Io, todo_dir: Dir, options: Io.File.OpenFlags) !File {
            return .{ .inner = try todo_dir.openFile(io, item.path, options) };
        }

        fn openNoteFile(item: Item, io: Io, todo_dir: Dir, options: Io.File.OpenFlags, buf: []u8) MaybeNoteFile {
            const note_path = item.noteFile(buf);
            return .{
                .io = io,
                .buf = buf,
                .inner = todo_dir.openFile(io, note_path, options) catch null,
            };
        }

        const MaybeNoteFile = struct {
            io: Io,
            buf: []u8,
            inner: ?Io.File,

            fn close(f: MaybeNoteFile, io: Io) void {
                if (f.inner) |inner| inner.close(io);
            }

            fn reader(f: MaybeNoteFile) ?Io.File.Reader {
                return if (f.inner) |inner| inner.reader(f.io, f.buf) else null;
            }
        };

        fn noteFile(item: Item, out_buf: []u8) []const u8 {
            const nwe = item.withoutExt();
            @memcpy(out_buf[0..nwe.len], nwe);
            @memcpy(out_buf[nwe.len..][0..3], note_file_ext);
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
                try td_writer.interface.print("\n{t} {}", .{ status, now.nanoseconds });
                try td_writer.interface.flush();
            }

            const StatusLine = struct {
                status: Status,
                timestamp: ?[]const u8,
                author_name: ?[]const u8,
                author_email: ?[]const u8,
                format_mode: enum {
                    simple,
                    detailed,
                } = .simple,

                fn read(line: []const u8) !StatusLine {
                    var iter: SpaceQuoteIter = .init(line);

                    const status_str = iter.next() orelse return error.EmptyStatusLine;
                    const status = meta.stringToEnum(Status, status_str) orelse return error.UnknownStatusForTodoItem;

                    const timestamp = iter.next();
                    const author_name = iter.next();
                    const author_email = iter.next();

                    return .{
                        .status = status,
                        .timestamp = timestamp,
                        .author_name = author_name,
                        .author_email = author_email,
                    };
                }
            };

            const FirstLatestStatus = struct {
                first: StatusLine,
                latest: StatusLine,
            };

            fn getStatus(file: File, io: Io, item: Item, buf: []u8) !FirstLatestStatus {
                var reader = file.inner.reader(io, buf);

                var first_status: StatusLine = undefined;
                const first_line_maybe = try reader.interface.takeDelimiter('\n');
                if (first_line_maybe) |first_line| {
                    first_status = StatusLine.read(first_line) catch |err| {
                        std.log.err("malformed todo item: {s}", .{item.name()});

                        var sl_iter = mem.splitScalar(u8, first_line, ' ');
                        if (sl_iter.next()) |status_str| std.log.err("found '{s}' as status", .{status_str});
                        return err;
                    };
                }

                var last_line_maybe: ?[]const u8 = first_line_maybe;
                while (try reader.interface.takeDelimiter('\n')) |line| {
                    if (line.len == 0) continue;
                    last_line_maybe = line;
                }

                const last_line = last_line_maybe orelse {
                    std.log.err("malformed todo item: {s}, file is empty", .{item.name()});
                    return error.TodoItemEmpty;
                };

                const latest_status = StatusLine.read(last_line) catch |err| {
                    std.log.err("malformed todo item: {s}", .{item.name()});

                    var sl_iter = mem.splitScalar(u8, last_line, ' ');
                    if (sl_iter.next()) |status_str| std.log.err("found '{s}' as status", .{status_str});
                    return err;
                };

                return .{
                    .first = first_status,
                    .latest = latest_status,
                };
            }

            fn formatItemStatus(file: File, io: Io, w: *Io.Writer) !void {
                var read_buf: [2048]u8 = undefined;
                var reader = file.inner.reader(io, &read_buf);

                try w.writeAll("================================\n");
                while (try reader.interface.takeDelimiter('\n')) |line| {
                    const status_line = StatusLine.read(line) catch return error.WriteFailed;
                    try w.print("{t} {s}\n", .{
                        status_line.status,
                        try Formatter.formatTimestamp(status_line.timestamp),
                    });
                }
            }
        };

        const Formatter = struct {
            details: bool,
            history: bool,
            notes: bool,

            item: Item,
            key: Key,
            item_status: Item.File.FirstLatestStatus,
            notes_file: MaybeNoteFile,

            pub fn formatTerm(f: Formatter, term: Io.Terminal) !void {
                if (f.details) {
                    const first_has_email = f.item_status.first.author_email != null;
                    const latest_has_email = f.item_status.latest.author_email != null;

                    try term.setColor(.bright_yellow);
                    try term.writer.print("\nstatus:  ({c}) {s}\n", .{
                        f.item_status.latest.status.char(),
                        f.item.name(),
                    });

                    try term.setColor(.white);

                    if (f.item_status.first.author_name != null or f.item_status.first.author_email != null) {
                        try term.writer.print("author:  {s} {s}{s}{s}\n", .{
                            f.item_status.first.author_name orelse "",
                            if (first_has_email) "<" else "",
                            f.item_status.first.author_email orelse "",
                            if (first_has_email) ">" else "",
                        });
                    }

                    try term.writer.print(
                        \\hash:    {s}
                        \\latest:  {s}{s}{s} {s}{s}{s}
                    , .{
                        f.key,
                        try formatTimestamp(f.item_status.latest.timestamp),
                        author_str: {
                            if (f.item_status.latest.author_name != null or f.item_status.latest.author_email != null) {
                                break :author_str "\n         ";
                            } else {
                                break :author_str "";
                            }
                        },
                        f.item_status.latest.author_name orelse "",
                        if (latest_has_email) "<" else "",
                        f.item_status.latest.author_email orelse "",
                        if (latest_has_email) ">" else "",
                    });
                } else if (f.history or f.notes) {
                    try term.writer.print("\n[{s}] ({c}) {s}", .{ f.key, f.item_status.latest.status.char(), f.item.name() });
                } else {
                    try term.writer.print("    [{s}] ({c}) {s}", .{ f.key, f.item_status.latest.status.char(), f.item.name() });
                }

                if (f.notes) write_notes: {
                    var nfr = f.notes_file.reader() orelse break :write_notes;

                    try term.writer.writeAll("\n\n");
                    _ = nfr.interface.streamRemaining(term.writer) catch return error.WriteFailed;
                    try term.writer.writeByte('\n');
                }
            }

            fn formatTimestamp(ts_raw_str_maybe: ?[]const u8) ![]const u8 {
                const ts_raw_str = ts_raw_str_maybe orelse return "??? ??? ?? ??:??:?? ????";
                const ts_int = std.fmt.parseInt(u64, ts_raw_str, 10) catch return error.WriteFailed;
                const ts: Io.Timestamp = .{ .nanoseconds = ts_int };
                const ts_sec = ts.toSeconds();
                const ts_cstr = c.ctime(&ts_sec);
                const ts_str = mem.span(ts_cstr);
                return ts_str[0 .. ts_str.len - 1];
            }
        };
    };

    fn write(config: Config, io: Io, todo_dir: Dir) !void {
        var config_file = try todo_dir.createFile(io, config_file_path, .{});
        defer config_file.close(io);

        var writer = config_file.writer(io, &.{});
        try std.json.Stringify.value(config, .{}, &writer.interface);
    }

    fn deinit(config: *Config, gpa: std.mem.Allocator) void {
        gpa.free(config.name);
        for (config.items.values()) |v|
            gpa.free(v.path);
        config.items.deinit(gpa);
    }

    fn read(gpa: std.mem.Allocator, io: Io, todo_dir: Dir, buf: []u8) !Config {
        var config_file = todo_dir.openFile(io, config_file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NoConfigFile,
            else => |e| return e,
        };
        defer config_file.close(io);

        var config_reader = config_file.reader(io, buf);

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

    fn eqlLen(haystack: []const u8, needle: []const u8) usize {
        if (needle.len > haystack.len) return 0;
        if (mem.eql(u8, haystack, needle)) return haystack.len;
        const min_len = @min(haystack.len, needle.len);
        if (!mem.eql(u8, haystack[0..min_len], needle[0..min_len])) return 0;
        return min_len;
    }

    fn openItem(config: Config, io: Io, todo_dir: Dir, id_or_name: []const u8) !Item.File {
        return try (config.getItem(id_or_name) orelse return error.ItemNotFound).open(io, todo_dir);
    }

    fn firstWrite(io: Io, config_file: Io.File, name: []const u8, buf: []u8) void {
        var fw = config_file.writer(io, buf);
        try fw.interface.print(
            \\{{
            \\    "name": "{s}",
            \\    "items": {{}}
            \\}}
        , .{name});
        try fw.interface.flush();
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

const User = struct {
    file: ?Io.File,
    data: Data,

    const user_file_path = "user.json";

    const Data = struct {
        name: []const u8,
        email: []const u8,
    };

    fn init(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, todo_dir: Io.Dir, buf: []u8) User {
        return initInner(gpa, io, env, todo_dir, buf) catch .{
            .file = null,
            .data = .{
                .name = "",
                .email = "",
            },
        };
    }

    fn initInner(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, todo_dir: Io.Dir, buf: []u8) !User {
        const user_file = user_file: {
            if (todo_dir.openFile(io, user_file_path, .{})) |file| {
                break :user_file file;
            } else |_| {}

            if (kf.open(io, gpa, env.*, .home, .{})) |home_dir_maybe| home_dir: {
                const home_dir = home_dir_maybe orelse break :home_dir;
                defer home_dir.close(io);

                const user_file = home_dir.openFile(io, user_file_path, .{}) catch break :home_dir;
                break :user_file user_file;
            } else |_| {}

            return error.NoUserFile;
        };

        return read(gpa, io, user_file, buf);
    }

    fn deinit(u: User, io: Io) void {
        if (u.file) |file| file.close(io);
    }

    fn read(gpa: std.mem.Allocator, io: Io, user_file: Io.File, buf: []u8) !User {
        var user_reader = user_file.reader(io, buf);

        var user_js = std.json.Reader.init(gpa, &user_reader.interface);

        var diag: std.json.Diagnostics = .{};
        user_js.scanner.enableDiagnostics(&diag);
        errdefer {
            std.log.err("json error: {}:{}:{}", .{ diag.getLine(), diag.getColumn(), diag.getByteOffset() });
        }

        const data = try std.json.parseFromTokenSourceLeaky(Data, gpa, &user_js, .{});

        return .{
            .file = user_file,
            .data = data,
        };
    }

    fn write(user: User, io: Io) !void {
        const file = user.file orelse return;
        var writer = file.writer(io, &.{});
        try std.json.Stringify.value(user, .{}, &writer.interface);
        try writer.end();
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

            // matching either -arg "abc" or -arg="abc"
        } else if (meta.stringToEnum(meta.FieldEnum(Args), arg[1 .. mem.indexOfScalar(u8, arg[1..], '=') orelse arg.len])) |field| {
            switch (field) {
                inline else => |field_name_tag| {
                    if (@hasField(Args, "pos") and field_name_tag == .pos) {
                        std.log.err("'pos' is not a valid argument name", .{});
                        return error.UnknownArgument;
                    }

                    const field_name = @tagName(field_name_tag);
                    const F = @FieldType(Args, field_name);

                    if (F == bool) {
                        @field(args.inner, field_name) = true;
                    } else if (F == []const u8 or F == ?[]const u8) {
                        if (!mem.endsWith(u8, arg, "=")) {
                            @field(args.inner, field_name) = args_iter.next() orelse {
                                std.log.err("argument '{s}' expected a value", .{field_name});
                                return error.NamedArgWithoutValue;
                            };
                            continue :arg_loop;
                        }

                        // expecting -arg_name=...
                        if (arg.len < field_name.len + 2) {
                            std.log.err("argument '{s}' malformed", .{field_name});
                            return error.MalformedArgument;
                        }

                        @field(args.inner, field_name) = arg[field_name.len + 2 ..];
                    }
                    continue :arg_loop;
                },
            }
        } else {
            readTack(Args, arg, &args.inner);
        }
    }

    return args;
}

fn readTack(Args: type, arg_str: []const u8, args: *Args) void {
    inline for (@typeInfo(Args).@"struct".fields) |f| {
        if (f.type == bool and arg_str[0] == '-') {
            for (arg_str[1..]) |flag_char| {
                if (mem.eql(u8, f.name, &.{flag_char})) {
                    @field(args, f.name) = true;
                }
            }
        }
    }
}

const SpaceQuoteIter = struct {
    str: []const u8,
    idx: usize,

    fn init(str: []const u8) SpaceQuoteIter {
        return .{
            .str = str,
            .idx = 0,
        };
    }

    fn next(iter: *SpaceQuoteIter) ?[]const u8 {
        if (iter.idx >= iter.str.len) return null;
        var space_iter = mem.splitScalar(u8, iter.str[iter.idx..], ' ');

        var word = space_iter.next() orelse return null;
        if (word.len == 0 or word[0] != '"') {
            iter.idx += word.len + 1;
            return word;
        }

        if (word[0] == '"' and word[word.len - 1] == '"') {
            iter.idx += word.len + 1;
            return word[1 .. word.len - 1];
        }

        var len = word.len;
        while (word[0] == '"') {
            word = space_iter.next() orelse break;
            len += word.len;
        }

        defer iter.idx += len + 2;
        return iter.str[iter.idx + 1 ..][0 .. len - 1];
    }
};

test SpaceQuoteIter {
    var iter: SpaceQuoteIter = .init("a \"b c\" d e  f \"gh\" i \"jk\"");

    try std.testing.expectEqualStrings("a", iter.next().?);
    try std.testing.expectEqualStrings("b c", iter.next().?);
    try std.testing.expectEqualStrings("d", iter.next().?);
    try std.testing.expectEqualStrings("e", iter.next().?);
    try std.testing.expectEqualStrings("", iter.next().?);
    try std.testing.expectEqualStrings("f", iter.next().?);
    try std.testing.expectEqualStrings("gh", iter.next().?);
    try std.testing.expectEqualStrings("i", iter.next().?);
    try std.testing.expectEqualStrings("jk", iter.next().?);
}

const Shell = enum {
    bash,
    zsh,
    fish,
};

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

    var buf: [2048]u8 = undefined;

    try cmdInit(io, .initStatic(.{ .pos = .{"test"} }), temp_dir.dir, &buf);

    var todo_dir = try temp_dir.dir.openDir(io, todo_dir_path, .{});
    defer todo_dir.close(io);

    var config: Config = try .read(arena, io, todo_dir, &buf);

    try cmdAdd(arena, io, .initStatic(.{ .pos = .{"item-1"} }), &config, todo_dir, "a1b2c3d4".*, &buf);
    try cmdAdd(arena, io, .initStatic(.{ .pos = .{"item-2"}, .m = "item-2 notes" }), &config, todo_dir, "e5f6g7h8".*, &buf);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on list test
        \\    [a1b2c3d4] ( ) item-1
        \\    [e5f6g7h8] ( ) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdStartStop(io, .initStatic(.{ .pos = .{"item-1"} }), config, todo_dir, .start, &buf);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on list test
        \\    [a1b2c3d4] (o) item-1
        \\    [e5f6g7h8] ( ) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdComplete(arena, io, .initStatic(.{ .pos = .{"e5"} }), &config, todo_dir, &buf);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on list test
        \\    [a1b2c3d4] (o) item-1
        \\    [e5f6g7h8] (x) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdNotes(io, .initStatic(.{ .pos = .{"e5"} }), config, todo_dir, null, &stdout.writer, &buf);

    try std.testing.expectEqualStrings(
        \\item-2 notes
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdUncomplete(io, .initStatic(.{ .pos = .{"e5"} }), &config, todo_dir, &buf);
    try cmdList(io, .empty, config, todo_dir, &stdout.writer);

    try std.testing.expectEqualStrings(
        \\on list test
        \\    [a1b2c3d4] (o) item-1
        \\    [e5f6g7h8] ( ) item-2
        \\
    , stdout.written());
    stdout.writer.end = 0;

    try cmdRemove(io, .initStatic(.{ .pos = .{"a1"}, .y = true }), &config, todo_dir, &buf);

    try config.write(io, todo_dir);
}

const std = @import("std");
const c = @import("c");
const kf = @import("known-folders");
const mem = std.mem;
const meta = std.meta;
const Io = std.Io;
const Dir = Io.Dir;
const Map = std.AutoArrayHashMapUnmanaged;
