//! Fetches what local/ holds that can be had again: `zig build` here
//! fetches everything, or one source at a time.
//!
//!     zig build historicalsource  Zork I-III into stories/historicalsource/
//!     zig build eblong            the catalog into stories/eblong/
//!     zig build infodoc           manuals into manuals/infodoc/
//!
//! Everything else in local/ is made here or came from elsewhere by hand.

const std = @import("std");

const Sources = struct {
    historicalsource: []const struct { name: []const u8, version: []const u8, commit: []const u8, sha256: []const u8 },
    eblong: []const u8,
    infodoc: []const u8,
    manuals: []const struct { path: []const u8, sha256: []const u8 },
};
const sources: Sources = @import("sources.zon");

pub fn build(b: *std.Build) void {
    const fetch = b.addExecutable(.{
        .name = "fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fetch.zig"),
            .target = b.graph.host,
        }),
    });

    const historicalsource = b.step("historicalsource", "Download Zork I-III (MIT) into stories/historicalsource/");
    const stories = b.addUpdateSourceFiles();
    for (sources.historicalsource) |story| {
        const run = b.addRunArtifact(fetch);
        run.addArg(b.fmt("https://raw.githubusercontent.com/historicalsource/{s}/{s}/COMPILED/{s}.z3", .{ story.name, story.commit, story.name }));
        run.addArg(story.sha256);
        const file = run.addOutputFileArg(b.fmt("{s}.z3", .{story.name}));
        stories.addCopyFileToSource(file, b.fmt("stories/historicalsource/{s}.{s}.z3", .{ story.name, story.version }));
    }
    historicalsource.dependOn(&stories.step);

    const eblong = b.step("eblong", "Download the Infocom catalog's story files into stories/eblong/");
    const catalog = b.addRunArtifact(fetch);
    catalog.setCwd(b.path("."));
    catalog.has_side_effects = true;
    catalog.addArgs(&.{ "--catalog", sources.eblong, "stories/eblong" });
    eblong.dependOn(&catalog.step);

    const infodoc = b.step("infodoc", "Download manuals from the Infocom Documentation Project into manuals/infodoc/");
    const manuals = b.addUpdateSourceFiles();
    for (sources.manuals) |manual| {
        const run = b.addRunArtifact(fetch);
        const name = std.fs.path.basename(manual.path);
        run.addArg(b.fmt("{s}{s}", .{ sources.infodoc, manual.path }));
        run.addArg(manual.sha256);
        manuals.addCopyFileToSource(run.addOutputFileArg(name), b.fmt("manuals/infodoc/{s}", .{name}));
    }
    infodoc.dependOn(&manuals.step);

    for ([_]*std.Build.Step{ historicalsource, eblong, infodoc }) |step| b.default_step.dependOn(step);
}
