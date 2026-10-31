const std = @import("std");
const manifest = @import("build.zig.zon");

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
    for (&walkthroughs, [_][]const u8{ "tests/walkthroughs-local/walkthroughs.zon", "tests/walkthroughs/walkthroughs.zon" }) |*run, manifest_path| {
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

    // Evaluation tools (MODEL_EVALUATION.md): `zig build tools`
    // builds them into zig-out/bin; their tests run with `zig build test`.
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
            .root_source_file = b.path("tools/fetch.zig"),
            .target = b.graph.host,
        }),
    });
    const stories_step = b.step("stories", "Download Zork I-III (MIT) into games/");
    const stories = [_]struct { name: []const u8, version: []const u8, commit: []const u8, sha256: []const u8 }{
        .{ .name = "zork1", .version = "r119-880429", .commit = "97b7b3d68c075dd9af7da499c3e9690ada3471fd", .sha256 = "37084966477dff679282de42974b2077156b1bd68fad92a65d4ea94d8eb64d79" },
        .{ .name = "zork2", .version = "r63-860811", .commit = "3da9661098809788a99cef00f00c865c6c204f96", .sha256 = "3ae7d5558943e9721f3e4b273c8a7faec1a03a604e1ae4ee1cde472c21cb24ac" },
        .{ .name = "zork3", .version = "r25-860811", .commit = "3ec9ed412b5f3cafe65d83c727d07db1fe4a86a8", .sha256 = "b637a242865d059890184164ce8dec28554cc80901dcbf26c740b2d1ed0d4eb8" },
    };
    if (b.option(bool, "stories", "Download Zork I-III for `stories` and `walkthrough` (default true)") orelse true) {
        // Into games/ (ignored by git), named like the walkthrough scripts.
        const copy = b.addUpdateSourceFiles();
        stories_step.dependOn(&copy.step);
        for (stories) |story| {
            const fetch = b.addRunArtifact(fetcher);
            fetch.addArg(b.fmt("https://raw.githubusercontent.com/historicalsource/{s}/{s}/COMPILED/{s}.z3", .{ story.name, story.commit, story.name }));
            fetch.addArg(story.sha256);
            const file = fetch.addOutputFileArg(b.fmt("{s}.z3", .{story.name}));
            copy.addCopyFileToSource(file, b.fmt("games/{s}.{s}.z3", .{ story.name, story.version }));
            walkthroughs[1].addArg("--story");
            walkthroughs[1].addPrefixedFileArg(b.fmt("{s}=", .{story.name}), file);
        }
    } else {
        stories_step.dependOn(&b.addFail("Zork I-III aren't downloaded with -Dstories=false").step);
    }
}
