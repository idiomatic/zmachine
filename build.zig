const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information");

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const exe = b.addExecutable(.{
        .name = "zmachine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the interpreter");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // The walkthroughs, their stories and the manifest stay local; without
    // them the step skips them and passes.
    const runner = b.addExecutable(.{
        .name = "walkthrough",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/walkthrough.zig"),
            .target = b.graph.host,
        }),
    });
    const walkthrough = b.addRunArtifact(runner);
    walkthrough.setCwd(b.path("."));
    walkthrough.has_side_effects = true;
    walkthrough.addArtifactArg(exe);
    walkthrough.addArg("tests/walkthroughs/walkthroughs.zon");
    if (b.option([]const u8, "walkthrough", "Play only the walkthrough with this name")) |name| {
        walkthrough.addArgs(&.{ "--only", name });
    }
    if (b.option(bool, "update-walkthroughs", "Save each walkthrough's output as its expected transcript") orelse false) {
        walkthrough.addArg("--update");
    }
    const walkthrough_step = b.step("walkthrough", "Play the local walkthroughs and check their output");
    walkthrough_step.dependOn(&walkthrough.step);
}
