const std = @import("std");
const manifest = @import("build.zig.zon");
// What local/build.zig fetches; the root build uses its Zork stories.
const sources: struct {
    historicalsource: []const struct { name: []const u8, version: []const u8, commit: []const u8, sha256: []const u8 },
    eblong: []const u8,
    infodoc: []const u8,
    manuals: []const struct { path: []const u8, sha256: []const u8 },
} = @import("local/sources.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information");

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    // The modules, each importing only those before it. A module's
    // undeclared import doesn't build.
    const modules = [_]struct { name: []const u8, imports: []const []const u8 }{
        .{ .name = "vm", .imports = &.{} },
        .{ .name = "protocol", .imports = &.{} },
        .{ .name = "poly", .imports = &.{"protocol"} },
        .{ .name = "console", .imports = &.{"vm"} },
        .{ .name = "hub", .imports = &.{ "vm", "console" } },
        .{ .name = "inspector", .imports = &.{ "vm", "protocol" } },
        .{ .name = "web", .imports = &.{ "hub", "poly", "protocol" } },
        .{ .name = "mcp", .imports = &.{ "protocol", "build_options" } },
    };
    var imports: [modules.len + 1]std.Build.Module.Import = undefined;
    imports[0] = .{ .name = "build_options", .module = options.createModule() };
    const test_step = b.step("test", "Run unit tests");
    for (modules, 1..) |m, i| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{m.name})),
            .target = target,
            .optimize = optimize,
        });
        for (m.imports) |name| {
            const import = for (imports[0..i]) |import| {
                if (std.mem.eql(u8, import.name, name)) break import;
            } else std.debug.panic("{s} imports {s}, which isn't declared before it", .{ m.name, name });
            module.addImport(name, import.module);
        }
        imports[i] = .{ .name = m.name, .module = module };
        const tests = b.addTest(.{ .name = m.name, .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const exe = b.addExecutable(.{
        .name = "zmachine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &imports,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the interpreter");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{ .name = "app", .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Walkthroughs: local ones (scripts, stories and manifest stay out of
    // git) and committed ones for the open-source stories. Whatever is
    // missing is skipped, so the step passes anywhere.
    const runner = b.addExecutable(.{
        .name = "walkthrough",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/walkthrough.zig"),
            .target = b.graph.host,
        }),
    });
    const only = b.option([]const u8, "walkthrough", "Play only the walkthrough with this name");
    const update = b.option(bool, "update-walkthroughs", "Save each walkthrough's output as its expected transcript") orelse false;
    const walkthrough_step = b.step("walkthrough", "Play the walkthroughs and check their output");
    // The local walkthroughs, and the committed ones for the open-source
    // stories.
    var walkthroughs: [2]*std.Build.Step.Run = undefined;
    for (&walkthroughs, [_][]const u8{ "local/walkthroughs/zmachine/walkthroughs.zon", "tests/walkthroughs/walkthroughs.zon" }) |*run, manifest_path| {
        run.* = b.addRunArtifact(runner);
        run.*.setCwd(b.path("."));
        run.*.has_side_effects = true;
        run.*.addArtifactArg(exe);
        run.*.addArg(manifest_path);
        if (only) |name| run.*.addArgs(&.{ "--only", name });
        if (update) run.*.addArg("--update");
        walkthrough_step.dependOn(&run.*.step);
    }
    // One at a time, so their reports don't interleave.
    walkthroughs[1].step.dependOn(&walkthroughs[0].step);

    // Compatibility: every story in the Obsessively Complete Infocom Catalog
    // (but version 6), fetched into local/stories/eblong/ by local/build.zig,
    // played briefly and compared with dfrotz when there is one; its runs in
    // local/runs/compat/.
    const compat = b.addExecutable(.{
        .name = "compat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/compat.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "compat", .root_module = compat.root_module })).step);
    const compat_step = b.step("compat", "Play every catalog story briefly and compare with dfrotz (`zig build eblong` in local/ fetches them)");
    const compat_run = b.addRunArtifact(compat);
    compat_run.setCwd(b.path("."));
    compat_run.has_side_effects = true;
    compat_run.addArtifactArg(exe);
    compat_run.addArgs(&.{ "local/stories/eblong", "local/runs/compat" });
    compat_run.addArgs(&.{ "--frotz", b.option([]const u8, "frotz", "dfrotz to compare with in `compat` (default: dfrotz on the path, if any)") orelse "dfrotz" });
    if (b.option([]const u8, "compat", "Play only the catalog stories whose names start with this")) |prefix| compat_run.addArgs(&.{ "--only", prefix });
    compat_step.dependOn(&compat_run.step);

    // Tools for evaluating models as players: `zig build tools` builds
    // them into zig-out/bin; their tests run with `zig build test`.
    const tools_step = b.step("tools", "Build the evaluation tools: bot, relay, metrics, save");
    for ([_][]const u8{ "bot", "relay", "metrics", "save" }) |name| {
        const tool = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
                .target = b.graph.host,
            }),
        });
        tools_step.dependOn(&b.addInstallArtifact(tool, .{}).step);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = name, .root_module = tool.root_module })).step);
    }

    // Zork I-III are open source (MIT, Copyright (c) 2025 Microsoft). Their
    // compiled stories are downloaded from a pinned commit and checked
    // against a pinned SHA-256, only when `stories` or `walkthrough` needs
    // them (then cached); -Dstories=false skips them, as offline.
    const fetcher = b.addExecutable(.{
        .name = "fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("local/fetch.zig"),
            .target = b.graph.host,
        }),
    });
    const stories_step = b.step("stories", "Download Zork I-III (MIT) into local/stories/historicalsource/");
    if (b.option(bool, "stories", "Download Zork I-III for `stories` and `walkthrough` (default true)") orelse true) {
        // Into local/stories/historicalsource/, named like the walkthrough
        // scripts, as `zig build historicalsource` in local/ does.
        const copy = b.addUpdateSourceFiles();
        stories_step.dependOn(&copy.step);
        for (sources.historicalsource) |story| {
            const fetch = b.addRunArtifact(fetcher);
            fetch.addArg(b.fmt("https://raw.githubusercontent.com/historicalsource/{s}/{s}/COMPILED/{s}.z3", .{ story.name, story.commit, story.name }));
            fetch.addArg(story.sha256);
            const file = fetch.addOutputFileArg(b.fmt("{s}.z3", .{story.name}));
            copy.addCopyFileToSource(file, b.fmt("local/stories/historicalsource/{s}.{s}.z3", .{ story.name, story.version }));
            walkthroughs[1].addArg("--story");
            walkthroughs[1].addPrefixedFileArg(b.fmt("{s}=", .{story.name}), file);
        }
    } else {
        stories_step.dependOn(&b.addFail("Zork I-III aren't downloaded with -Dstories=false").step);
    }
}
