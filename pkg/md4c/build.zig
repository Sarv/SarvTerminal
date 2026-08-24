const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("md4c", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "md4c",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // zig 0.16: libc linkage is a module option; Compile.linkLibC() is gone.
            .link_libc = true,
        }),
        .linkage = .static,
    });
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    if (b.lazyDependency("md4c", .{})) |upstream| {
        const inc = upstream.path("src");
        lib.root_module.addIncludePath(inc);
        module.addIncludePath(inc);

        // The parser (md4c.c) + the HTML renderer (md4c-html.c) + its HTML
        // entity table (entity.c). No config header — md4c has no autoconf.
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .flags = &.{},
            .files = &.{
                "src/md4c.c",
                "src/md4c-html.c",
                "src/entity.c",
            },
        });
        lib.installHeader(upstream.path("src/md4c.h"), "md4c.h");
        lib.installHeader(upstream.path("src/md4c-html.h"), "md4c-html.h");

        // Self-test: proves the vendored C compiles, links, and renders GFM.
        if (target.query.isNative()) {
            const test_mod = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
            });
            test_mod.addIncludePath(inc);
            const test_exe = b.addTest(.{ .name = "test", .root_module = test_mod });
            test_exe.root_module.linkLibrary(lib);
            const tests_run = b.addRunArtifact(test_exe);
            const test_step = b.step("test", "Run md4c tests");
            test_step.dependOn(&tests_run.step);
        }
    }

    b.installArtifact(lib);
}
