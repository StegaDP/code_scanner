const std = @import("std");

const Mode = enum { bytes, lines };

const Cli = struct {
    path: []const u8 = ".",
    top_langs: usize = 15,
    top_files: usize = 20,
    mode: Mode = .bytes,
    ignore: bool = true,
    include_hidden: bool = false,
    exclude_exts: [][]const u8 = &.{},
    exclude_paths: [][]const u8 = &.{},
};

const FileTop = struct {
    size: u64,
    lines: u64,
    rel_path: []const u8,
};

const LanguageStats = struct {
    bytes: u64 = 0,
    lines: u64 = 0,
    files: u64 = 0,
};

const LocalStats = struct {
    lang: std.StringHashMapUnmanaged(LanguageStats) = .{},
    files_seen: u64 = 0,
    dirs_seen: u64 = 0,
    top_bytes: std.ArrayListUnmanaged(FileTop) = .empty, // sorted desc by size
    top_lines: std.ArrayListUnmanaged(FileTop) = .empty, // sorted desc by lines

    fn deinit(self: *LocalStats, alloc: std.mem.Allocator) void {
        self.lang.deinit(alloc);
        self.top_bytes.deinit(alloc);
        self.top_lines.deinit(alloc);
    }
};

const WorkQueue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged([]const u8) = .empty,
    done: bool = false,

    fn deinit(self: *WorkQueue, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }

    fn push(self: *WorkQueue, alloc: std.mem.Allocator, io: std.Io, item: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.items.append(alloc, item);
        self.cond.signal(io);
    }

    fn pop(self: *WorkQueue, io: std.Io) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.items.items.len == 0 and !self.done) {
            self.cond.waitUncancelable(io, &self.mutex);
        }
        if (self.items.items.len == 0) return null;
        return self.items.pop();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa_alloc = init.gpa;
    const a = init.arena.allocator();

    var out_buf: [64 * 1024]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var file_out = stdout_file.writer(init.io, &out_buf);
    defer file_out.interface.flush() catch {};
    const out = &file_out.interface;

    const cli = try parseCli(gpa_alloc, init.minimal.args, out);

    const cwd_path_z = try std.process.currentPathAlloc(init.io, a);
    const cwd_path = std.mem.sliceTo(cwd_path_z, 0);
    const root_path = if (std.fs.path.isAbsolute(cli.path))
        try a.dupe(u8, cli.path)
    else
        try std.fs.path.resolve(a, &.{ cwd_path, cli.path });

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const worker_count: usize = @max(1, @min(64, cpu_count));

    var queue = WorkQueue{};
    defer queue.deinit(gpa_alloc);

    const locals = try gpa_alloc.alloc(LocalStats, worker_count);
    defer {
        for (locals) |*ls| ls.deinit(gpa_alloc);
        gpa_alloc.free(locals);
    }
    @memset(locals, .{});

    const threads = try gpa_alloc.alloc(std.Thread, worker_count);
    defer gpa_alloc.free(threads);

    const ctx = WorkerCtx{
        .cli = cli,
        .queue = &queue,
        .alloc = gpa_alloc,
        .arena = a,
        .io = init.io,
    };

    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, workerMain, .{ ctx, &locals[i] });
    }

    // Producer: walk directories and enqueue file absolute paths.
    try walkAndEnqueue(gpa_alloc, a, cli, root_path, init.io, &queue);

    // Finish queue.
    queue.mutex.lockUncancelable(init.io);
    queue.done = true;
    queue.mutex.unlock(init.io);
    queue.cond.broadcast(init.io);

    for (threads) |t| t.join();

    var merged = LocalStats{};
    defer merged.deinit(gpa_alloc);
    try mergeAll(gpa_alloc, cli, locals, &merged);

    try renderReport(out, cli, merged);
}

fn parseCli(alloc: std.mem.Allocator, args: std.process.Args, out: *std.Io.Writer) !Cli {
    var cli: Cli = .{};
    var ex_exts = std.ArrayListUnmanaged([]const u8).empty;
    var ex_paths = std.ArrayListUnmanaged([]const u8).empty;
    errdefer ex_exts.deinit(alloc);
    errdefer ex_paths.deinit(alloc);

    var it = try std.process.Args.Iterator.initAllocator(args, alloc);
    defer it.deinit();

    _ = it.next(); // exe
    while (it.next()) |argz| {
        const arg = std.mem.sliceTo(argz, 0);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(out);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--no-ignore")) {
            cli.ignore = false;
        } else if (std.mem.eql(u8, arg, "--include-hidden")) {
            cli.include_hidden = true;
        } else if (std.mem.eql(u8, arg, "--exclude-ext")) {
            const vz = it.next() orelse return error.InvalidArgs;
            const v = std.mem.sliceTo(vz, 0);
            try parseCsvList(alloc, &ex_exts, v, true);
        } else if (std.mem.eql(u8, arg, "--exclude-path")) {
            const vz = it.next() orelse return error.InvalidArgs;
            const v = std.mem.sliceTo(vz, 0);
            try parseCsvList(alloc, &ex_paths, v, false);
        } else if (std.mem.eql(u8, arg, "--by")) {
            const vz = it.next() orelse return error.InvalidArgs;
            const v = std.mem.sliceTo(vz, 0);
            if (std.mem.eql(u8, v, "bytes")) cli.mode = .bytes else if (std.mem.eql(u8, v, "lines")) cli.mode = .lines else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--top")) {
            const vz = it.next() orelse return error.InvalidArgs;
            const v = std.mem.sliceTo(vz, 0);
            cli.top_langs = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--top-files")) {
            const vz = it.next() orelse return error.InvalidArgs;
            const v = std.mem.sliceTo(vz, 0);
            cli.top_files = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArgs;
        } else {
            cli.path = try alloc.dupe(u8, arg);
        }
    }

    cli.exclude_exts = try ex_exts.toOwnedSlice(alloc);
    cli.exclude_paths = try ex_paths.toOwnedSlice(alloc);
    return cli;
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\code-scanner (Zig) — многопоточный сканер языков/конфигов
        \\
        \\USAGE:
        \\  code-scanner [path]
        \\    [--by bytes|lines]
        \\    [--top N] [--top-files N]
        \\    [--exclude-ext csv,parquet] [--exclude-path market_data,dist]
        \\              [--no-ignore] [--include-hidden]
        \\
        \\NOTES:
        \\  По умолчанию считает «как GitHub» по байтам.
        \\  Режим lines читает файлы и считает строки (медленнее).
        \\
    );
}

fn parseCsvList(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
    csv: []const u8,
    lower: bool,
) !void {
    var start: usize = 0;
    while (start < csv.len) {
        var end = start;
        while (end < csv.len and csv[end] != ',') : (end += 1) {}
        const raw = std.mem.trim(u8, csv[start..end], " \t\r\n");
        if (raw.len != 0) {
            const item = if (lower)
                try std.ascii.allocLowerString(alloc, raw)
            else
                try alloc.dupe(u8, raw);
            try list.append(alloc, item);
        }
        start = end + 1;
    }
}

const WorkerCtx = struct {
    cli: Cli,
    queue: *WorkQueue,
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
};

fn workerMain(ctx: WorkerCtx, local: *LocalStats) void {
    while (true) {
        const abs_path = ctx.queue.pop(ctx.io) orelse break;
        processOne(ctx, local, abs_path) catch {};
    }
}

fn processOne(ctx: WorkerCtx, local: *LocalStats, abs_path: []const u8) !void {
    if (isExcludedPath(abs_path, ctx.cli.exclude_paths)) return;
    const basename = std.fs.path.basename(abs_path);
    if (ctx.cli.ignore and isIgnoredFile(basename)) return;
    if (isExcludedExt(basename, ctx.cli.exclude_exts)) return;

    const lang = detectLanguage(ctx.arena, basename);
    if (lang == null) return;

    const file = try std.Io.Dir.openFileAbsolute(ctx.io, abs_path, .{});
    defer file.close(ctx.io);
    const stat = try file.stat(ctx.io);
    if (stat.kind != .file) return;
    local.files_seen += 1;

    const lines = try countLines(ctx.io, file);

    const entry = try local.lang.getOrPut(ctx.alloc, lang.?);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    entry.value_ptr.files += 1;
    entry.value_ptr.bytes += stat.size;
    entry.value_ptr.lines += lines;

    const ft: FileTop = .{ .size = stat.size, .lines = lines, .rel_path = abs_path };
    try addTopFileBytes(ctx.alloc, ctx.cli.top_files, &local.top_bytes, ft);
    try addTopFileLines(ctx.alloc, ctx.cli.top_files, &local.top_lines, ft);
}

fn countLines(io: std.Io, file: std.Io.File) !u64 {
    var buf: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    var offset: u64 = 0;
    var saw_any: bool = false;
    var last: u8 = 0;
    while (true) {
        const n = try std.Io.File.readPositional(file, io, &.{buf[0..]}, offset);
        if (n == 0) break;
        saw_any = true;
        last = buf[n - 1];
        total += @intCast(std.mem.count(u8, buf[0..n], "\n"));
        offset += n;
    }
    if (saw_any and last != '\n') total += 1;
    return total;
}

fn addTopFileBytes(alloc: std.mem.Allocator, limit: usize, list: *std.ArrayListUnmanaged(FileTop), item: FileTop) !void {
    if (limit == 0) return;
    var idx: usize = 0;
    while (idx < list.items.len) : (idx += 1) {
        const other = list.items[idx];
        if (other.size < item.size) break;
        if (other.size == item.size and other.lines < item.lines) break;
    }
    if (idx >= limit and list.items.len >= limit) return;
    try list.insert(alloc, idx, item);
    if (list.items.len > limit) _ = list.pop();
}

fn addTopFileLines(alloc: std.mem.Allocator, limit: usize, list: *std.ArrayListUnmanaged(FileTop), item: FileTop) !void {
    if (limit == 0) return;
    var idx: usize = 0;
    while (idx < list.items.len) : (idx += 1) {
        const other = list.items[idx];
        if (other.lines < item.lines) break;
        if (other.lines == item.lines and other.size < item.size) break;
    }
    if (idx >= limit and list.items.len >= limit) return;
    try list.insert(alloc, idx, item);
    if (list.items.len > limit) _ = list.pop();
}

fn walkAndEnqueue(
    gpa_alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    cli: Cli,
    root_abs: []const u8,
    io: std.Io,
    queue: *WorkQueue,
) !void {
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(gpa_alloc);

    try stack.append(gpa_alloc, root_abs);

    while (stack.items.len != 0) {
        const dir_abs = stack.pop().?;
        if (isExcludedPath(dir_abs, cli.exclude_paths)) continue;
        var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |ent| {
            if (!cli.include_hidden and ent.name.len > 0 and ent.name[0] == '.') {
                // Still allow special dotfiles with no extension? We skip by default like most scanners.
                continue;
            }
            if (cli.ignore and ent.kind == .directory and isIgnoredDir(ent.name)) continue;
            if (ent.kind == .file and isExcludedExt(ent.name, cli.exclude_exts)) continue;

            const abs_child = try std.fs.path.join(arena, &.{ dir_abs, ent.name });
            switch (ent.kind) {
                .directory => try stack.append(gpa_alloc, abs_child),
                .file => try queue.push(gpa_alloc, io, abs_child),
                else => {},
            }
        }
    }
}

fn isExcludedExt(basename: []const u8, exts: [][]const u8) bool {
    if (exts.len == 0) return false;
    const ext_with_dot = std.fs.path.extension(basename);
    if (ext_with_dot.len == 0) return false;
    const e = if (ext_with_dot[0] == '.') ext_with_dot[1..] else ext_with_dot;
    if (e.len == 0) return false;
    var buf: [64]u8 = undefined;
    // Most extensions are short; fall back to heapless compare if too long.
    if (e.len <= buf.len) {
        const lower = std.ascii.lowerString(buf[0..e.len], e);
        for (exts) |x| if (std.mem.eql(u8, lower, x)) return true;
        return false;
    }
    // Slow path: case-insensitive compare without allocation.
    for (exts) |x| if (std.ascii.eqlIgnoreCase(e, x)) return true;
    return false;
}

fn isExcludedPath(abs_path: []const u8, needles: [][]const u8) bool {
    if (needles.len == 0) return false;
    for (needles) |n| {
        if (n.len == 0) continue;
        if (containsIgnoreCase(abs_path, n)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn mergeAll(alloc: std.mem.Allocator, cli: Cli, locals: []LocalStats, merged: *LocalStats) !void {
    for (locals) |ls| {
        var it = ls.lang.iterator();
        while (it.next()) |e| {
            const entry = try merged.lang.getOrPut(alloc, e.key_ptr.*);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.bytes += e.value_ptr.bytes;
            entry.value_ptr.lines += e.value_ptr.lines;
            entry.value_ptr.files += e.value_ptr.files;
        }
        // merge top files
        for (ls.top_bytes.items) |ft| try addTopFileBytes(alloc, cli.top_files, &merged.top_bytes, ft);
        for (ls.top_lines.items) |ft| try addTopFileLines(alloc, cli.top_files, &merged.top_lines, ft);
        merged.files_seen += ls.files_seen;
        merged.dirs_seen += ls.dirs_seen;
    }
}

fn renderReport(out: *std.Io.Writer, cli: Cli, stats: LocalStats) !void {
    var pairs: std.ArrayListUnmanaged(struct { name: []const u8, st: LanguageStats, metric: u64 }) = .empty;
    defer pairs.deinit(std.heap.page_allocator);

    var total_metric: u64 = 0;
    var it = stats.lang.iterator();
    while (it.next()) |e| {
        const metric: u64 = switch (cli.mode) {
            .bytes => e.value_ptr.bytes,
            .lines => e.value_ptr.lines,
        };
        if (metric == 0) continue;
        total_metric += metric;
        try pairs.append(std.heap.page_allocator, .{ .name = e.key_ptr.*, .st = e.value_ptr.*, .metric = metric });
    }

    std.sort.pdq(@TypeOf(pairs.items[0]), pairs.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(pairs.items[0]), b: @TypeOf(pairs.items[0])) bool {
            return a.metric > b.metric;
        }
    }.lessThan);

    try out.writeAll("Summary\n");
    try out.print("  languages: {d}\n", .{stats.lang.count()});
    try out.print("  files:     {d}\n", .{stats.files_seen});
    try out.writeAll("  total:     ");
    try writeMetric(out, cli.mode, total_metric);
    try out.writeAll("\n\n");

    try out.print("Languages ({s})\n", .{switch (cli.mode) { .bytes => "bytes", .lines => "lines" }});
    if (total_metric == 0) {
        try out.writeAll("  (no matching files)\n");
    } else {
        const bar_w: usize = 32;
        const show_n = @min(cli.top_langs, pairs.items.len);
        for (pairs.items[0..show_n]) |p| {
            const pct = (@as(f64, @floatFromInt(p.metric)) / @as(f64, @floatFromInt(total_metric))) * 100.0;
            const filled = @as(usize, @intFromFloat(@round((pct / 100.0) * @as(f64, @floatFromInt(bar_w)))));
            try out.print("  {s: <16} {d:>6.2}%  ", .{ p.name, pct });
            try writeBar(out, filled, bar_w);
            try out.writeAll("  (");
            try writeMetric(out, cli.mode, p.metric);
            try out.print(", {d} files)\n", .{p.st.files});
        }
        if (pairs.items.len > show_n) try out.print("  ... +{d} more\n", .{pairs.items.len - show_n});
    }

    try out.writeAll("\nLargest files\n");
    if (stats.top_bytes.items.len == 0) {
        try out.writeAll("  (none)\n");
    } else {
        const show_n = @min(cli.top_files, stats.top_bytes.items.len);
        for (stats.top_bytes.items[0..show_n], 1..) |ft, idx| {
            var bbuf: [32]u8 = undefined;
            const bs = try fmtBytes(&bbuf, ft.size);
            try out.print("  {d:>2}. {s:>10}  {d:>8} lines  {s}\n", .{ idx, bs, ft.lines, ft.rel_path });
        }
    }

    try out.writeAll("\nLongest files\n");
    if (stats.top_lines.items.len == 0) {
        try out.writeAll("  (none)\n");
    } else {
        const show_n = @min(cli.top_files, stats.top_lines.items.len);
        for (stats.top_lines.items[0..show_n], 1..) |ft, idx| {
            var bbuf: [32]u8 = undefined;
            const bs = try fmtBytes(&bbuf, ft.size);
            try out.print("  {d:>2}. {d:>8} lines  {s:>10}  {s}\n", .{ idx, ft.lines, bs, ft.rel_path });
        }
    }
}

fn writeBar(w: anytype, filled: usize, width: usize) !void {
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) try w.writeAll("#") else try w.writeAll(".");
    }
}

fn fmtBytes(buf: *[32]u8, n: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024.0 and u + 1 < units.len) : (u += 1) v /= 1024.0;
    return std.fmt.bufPrint(buf.*[0..], "{d:.2} {s}", .{ v, units[u] });
}

fn writeMetric(w: anytype, mode: Mode, n: u64) !void {
    switch (mode) {
        .bytes => {
            var buf: [32]u8 = undefined;
            const s = try fmtBytes(&buf, n);
            try w.print("{s}", .{s});
        },
        .lines => {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d} lines", .{n});
            try w.print("{s}", .{s});
        },
    }
}

fn isIgnoredDir(name: []const u8) bool {
    const set = std.StaticStringMap(void).initComptime(.{
        .{ ".git", {} },
        .{ ".hg", {} },
        .{ ".svn", {} },
        .{ ".idea", {} },
        .{ ".vscode", {} },
        .{ "node_modules", {} },
        .{ "target", {} },
        .{ "dist", {} },
        .{ "build", {} },
        .{ "out", {} },
        .{ ".zig-cache", {} },
        .{ "zig-out", {} },
        .{ "vendor", {} },
        .{ "third_party", {} },
        .{ "__pycache__", {} },
        .{ ".pytest_cache", {} },
        .{ ".mypy_cache", {} },
        .{ ".ruff_cache", {} },
        .{ ".cache", {} },
        .{ ".gradle", {} },
        .{ ".dart_tool", {} },
        .{ ".next", {} },
        .{ ".nuxt", {} },
        .{ "coverage", {} },
        .{ ".terraform", {} },
        .{ ".venv", {} },
        .{ "venv", {} },
        .{ ".tox", {} },
    });
    return set.has(name);
}

fn isIgnoredFile(basename: []const u8) bool {
    // Common lock & generated files; also ignore generic *.lock.
    if (std.mem.endsWith(u8, basename, ".lock")) return true;
    const set = std.StaticStringMap(void).initComptime(.{
        .{ "Cargo.lock", {} },
        .{ "package-lock.json", {} },
        .{ "yarn.lock", {} },
        .{ "pnpm-lock.yaml", {} },
        .{ "bun.lockb", {} },
        .{ "composer.lock", {} },
        .{ "poetry.lock", {} },
        .{ "Pipfile.lock", {} },
        .{ "Gemfile.lock", {} },
        .{ "go.sum", {} },
        .{ ".DS_Store", {} },
    });
    return set.has(basename);
}

fn detectLanguage(arena: std.mem.Allocator, basename: []const u8) ?[]const u8 {
    // Filename-based first.
    const lower = std.ascii.allocLowerString(arena, basename) catch return null;

    const file_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "makefile", "Makefile" },
        .{ "dockerfile", "Dockerfile" },
        .{ "cmakelists.txt", "CMake" },
        .{ "meson.build", "Meson" },
        .{ "build.gradle", "Gradle" },
        .{ "build.gradle.kts", "Gradle Kotlin" },
        .{ "settings.gradle", "Gradle" },
        .{ "settings.gradle.kts", "Gradle Kotlin" },
        .{ "pom.xml", "Maven" },
        .{ "package.json", "JSON (Node)" },
        .{ "tsconfig.json", "JSON (TSConfig)" },
        .{ "composer.json", "JSON (Composer)" },
        .{ "deno.json", "JSON (Deno)" },
        .{ "deno.jsonc", "JSONC (Deno)" },
        .{ "cargo.toml", "TOML (Cargo)" },
        .{ "cargo.lock", "Lock (ignored)" },
        .{ "go.mod", "Go Module" },
        .{ "go.work", "Go Workspace" },
        .{ "gemfile", "Ruby (Gemfile)" },
        .{ "rakefile", "Ruby (Rakefile)" },
        .{ "podfile", "Ruby (CocoaPods)" },
        .{ "jenkinsfile", "Jenkinsfile" },
        .{ "justfile", "Just" },
        .{ "buck", "Buck" },
        .{ "build", "Bazel" },
        .{ "workspace", "Bazel" },
        .{ "bazelrc", "Bazel" },
        .{ "license", "Text" },
        .{ "readme", "Markdown" },
        .{ "readme.md", "Markdown" },
    });
    if (file_map.get(lower)) |v| {
        if (std.mem.eql(u8, v, "Lock (ignored)")) return null;
        return v;
    }

    // Extension-based.
    const ext = std.fs.path.extension(lower);
    if (ext.len == 0) return null;
    const e = if (ext[0] == '.') ext[1..] else ext;
    if (e.len == 0) return null;

    const ext_map = std.StaticStringMap([]const u8).initComptime(languageExtTable());
    return ext_map.get(e);
}

fn languageExtTable() []const struct { []const u8, []const u8 } {
    // Big-but-manageable set. GitHub uses linguist; we approximate with common extensions + configs.
    return &.{
        // Config & data
        .{ "yml", "YAML" }, .{ "yaml", "YAML" },
        .{ "toml", "TOML" },
        .{ "json", "JSON" }, .{ "jsonc", "JSONC" }, .{ "json5", "JSON5" },
        .{ "xml", "XML" }, .{ "plist", "XML (plist)" },
        .{ "ini", "INI" }, .{ "cfg", "INI" }, .{ "conf", "Config" }, .{ "config", "Config" },
        .{ "properties", "Properties" },
        .{ "env", "Env" },
        .{ "md", "Markdown" }, .{ "mdx", "MDX" }, .{ "rst", "reStructuredText" }, .{ "adoc", "AsciiDoc" }, .{ "asciidoc", "AsciiDoc" },
        .{ "txt", "Text" }, .{ "text", "Text" }, .{ "log", "Log" },
        .{ "csv", "CSV" }, .{ "tsv", "TSV" },
        .{ "sql", "SQL" }, .{ "psql", "SQL" }, .{ "mysql", "SQL" },
        .{ "graphql", "GraphQL" }, .{ "gql", "GraphQL" },
        .{ "proto", "Protocol Buffers" },
        .{ "avsc", "Avro Schema" },
        .{ "hcl", "HCL" }, .{ "tf", "Terraform" }, .{ "tfvars", "Terraform" },
        .{ "cue", "CUE" },
        .{ "nix", "Nix" },
        .{ "dhall", "Dhall" },
        .{ "rego", "Rego" },
        .{ "vim", "Vim Script" },

        // Web
        .{ "html", "HTML" }, .{ "htm", "HTML" },
        .{ "css", "CSS" }, .{ "scss", "SCSS" }, .{ "sass", "Sass" }, .{ "less", "Less" },
        .{ "js", "JavaScript" }, .{ "mjs", "JavaScript" }, .{ "cjs", "JavaScript" },
        .{ "ts", "TypeScript" }, .{ "mts", "TypeScript" }, .{ "cts", "TypeScript" },
        .{ "jsx", "JSX" }, .{ "tsx", "TSX" },
        .{ "vue", "Vue" }, .{ "svelte", "Svelte" },
        .{ "astro", "Astro" },
        .{ "php", "PHP" }, .{ "phtml", "PHP" },

        // Systems
        .{ "c", "C" }, .{ "h", "C/C++ Header" },
        .{ "cc", "C++" }, .{ "cpp", "C++" }, .{ "cxx", "C++" }, .{ "hpp", "C++ Header" }, .{ "hh", "C++ Header" }, .{ "hxx", "C++ Header" },
        .{ "m", "Objective-C" }, .{ "mm", "Objective-C++" },
        .{ "swift", "Swift" },
        .{ "rs", "Rust" },
        .{ "zig", "Zig" },
        .{ "go", "Go" },
        .{ "nim", "Nim" }, .{ "nims", "Nim" },
        .{ "d", "D" },
        .{ "cr", "Crystal" },
        .{ "jl", "Julia" },
        .{ "kt", "Kotlin" }, .{ "kts", "Kotlin" },
        .{ "scala", "Scala" }, .{ "sc", "Scala" },
        .{ "java", "Java" }, .{ "class", "Java (bytecode)" },
        .{ "cs", "C#" }, .{ "fs", "F#" }, .{ "fsx", "F#" }, .{ "vb", "VB.NET" },

        // Scripting
        .{ "py", "Python" }, .{ "pyi", "Python" }, .{ "pyw", "Python" },
        .{ "ipynb", "Jupyter Notebook" },
        .{ "rb", "Ruby" },
        .{ "pl", "Perl" }, .{ "pm", "Perl" }, .{ "t", "Perl" },
        .{ "lua", "Lua" },
        .{ "r", "R" }, .{ "rmd", "R Markdown" },
        .{ "sh", "Shell" }, .{ "bash", "Shell" }, .{ "zsh", "Shell" }, .{ "fish", "Shell" },
        .{ "ps1", "PowerShell" }, .{ "psm1", "PowerShell" }, .{ "psd1", "PowerShell" },
        .{ "bat", "Batch" }, .{ "cmd", "Batch" },

        // Functional / misc
        .{ "hs", "Haskell" }, .{ "lhs", "Haskell" },
        .{ "elm", "Elm" },
        .{ "clj", "Clojure" }, .{ "cljs", "ClojureScript" }, .{ "cljc", "Clojure" }, .{ "edn", "EDN" },
        .{ "ex", "Elixir" }, .{ "exs", "Elixir" },
        .{ "erl", "Erlang" }, .{ "hrl", "Erlang" },
        .{ "ml", "OCaml" }, .{ "mli", "OCaml" }, .{ "re", "ReasonML" },
        .{ "fsproj", "MSBuild" }, .{ "csproj", "MSBuild" }, .{ "vbproj", "MSBuild" }, .{ "sln", "Visual Studio Solution" },

        // Build / tooling
        .{ "gradle", "Gradle" }, .{ "bazel", "Bazel" }, .{ "bzl", "Bazel" },
        .{ "mk", "Make" },
        .{ "cmake", "CMake" },
        .{ "ninja", "Ninja" },
        .{ "dockerignore", "Docker" }, .{ "gitignore", "Git" }, .{ "gitattributes", "Git" }, .{ "gitmodules", "Git" },
        .{ "editorconfig", "EditorConfig" },

        // Docs
        .{ "tex", "TeX" }, .{ "bib", "BibTeX" },
    };
}
