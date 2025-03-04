const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = .{
        .skip_runtime_type_validation = b.option(
            bool,
            "skip_runtime_type_validation",
            "Skips the hashing and validation of types at runtime and does not include type hashes in serialization.",
        ) orelse false,
    };
    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }
    const options_module = options_step.createModule();

    _ = b.addModule("s2s", .{
        .root_source_file = b.path("s2s.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "s2s_options", .module = options_module },
        },
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("s2s.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("s2s_options", options_module);

    const test_step = b.step("test", "Run unit tests");
    const run_test = b.addRunArtifact(tests);
    test_step.dependOn(&run_test.step);
}
