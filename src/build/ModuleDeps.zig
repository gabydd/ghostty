const ModuleDeps = @This();

const std = @import("std");
const Scanner = @import("zig_wayland").Scanner;
const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const GhosttyFrameData = @import("GhosttyFrameData.zig");

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: ?*MetallibStep,
unicode_tables: UnicodeTables,
framedata: GhosttyFrameData,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !ModuleDeps {
    var result: ModuleDeps = .{
        .config = cfg,
        .help_strings = try HelpStrings.init(b, cfg),
        .unicode_tables = try UnicodeTables.init(b),
        .framedata = try GhosttyFrameData.init(b),

        // Setup by retarget
        .options = undefined,
        .metallib = undefined,
    };
    try result.initTarget(b, cfg.target);
    return result;
}

/// Retarget our dependencies for another build target. Modifies in-place.
pub fn retarget(
    self: *const ModuleDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !ModuleDeps {
    var result = self.*;
    try result.initTarget(b, target);
    return result;
}

/// Change the exe entrypoint.
pub fn changeEntrypoint(
    self: *const ModuleDeps,
    b: *std.Build,
    entrypoint: Config.ExeEntrypoint,
) !ModuleDeps {
    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.exe_entrypoint = entrypoint;

    var result = self.*;
    result.config = config;
    return result;
}

fn initTarget(
    self: *ModuleDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !void {
    // Update our metallib
    self.metallib = MetallibStep.create(b, .{
        .name = "Ghostty",
        .target = target,
        .sources = &.{b.path("src/renderer/shaders/cell.metal")},
    });

    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.target = target;
    self.config = config;

    // Setup our shared build options
    self.options = b.addOptions();
    try self.config.addOptions(self.options);
}

pub fn add(
    self: *const ModuleDeps,
    module: *std.Build.Module,
) !LazyPathList {
    const b = module.owner;

    // We could use our config.target/optimize fields here but its more
    // correct to always match our step.
    const target = module.resolved_target.?;
    const optimize = module.optimize.?;
    const resolved_target = target.result;

    if (module.import_table.get("options") == null) {
        module.addAnonymousImport("options", .{
            .root_source_file = b.path("src/noop.zig"),
            .target = target,
            .optimize = optimize,
        });
    }

    // We maintain a list of our static libraries and return it so that
    // we can build a single fat static library for the final app.
    var static_libs = LazyPathList.init(b.allocator);
    errdefer static_libs.deinit();

    // Every exe gets build options populated
    module.addOptions("build_options", self.options);

    // Freetype
    _ = b.systemIntegrationOption("freetype", .{}); // Shows it in help
    if (self.config.font_backend.hasFreetype()) {
        const freetype_dep = b.dependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .@"enable-libpng" = true,
        });
        module.addImport("freetype", freetype_dep.module("freetype"));

        if (b.systemIntegrationOption("freetype", .{})) {
            module.linkSystemLibrary("bzip2", dynamic_link_opts);
            module.linkSystemLibrary("freetype2", dynamic_link_opts);
        } else {
            module.linkLibrary(freetype_dep.artifact("freetype"));
            try static_libs.append(freetype_dep.artifact("freetype").getEmittedBin());
        }
    }

    // Harfbuzz
    _ = b.systemIntegrationOption("harfbuzz", .{}); // Shows it in help
    if (self.config.font_backend.hasHarfbuzz()) {
        if (b.lazyDependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .@"enable-freetype" = true,
            .@"enable-coretext" = self.config.font_backend.hasCoretext(),
        })) |harfbuzz_dep| {
            module.addImport(
                "harfbuzz",
                harfbuzz_dep.module("harfbuzz"),
            );
            if (b.systemIntegrationOption("harfbuzz", .{})) {
                module.linkSystemLibrary("harfbuzz", dynamic_link_opts);
            } else {
                module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
                try static_libs.append(
                    harfbuzz_dep.artifact("harfbuzz").getEmittedBin(),
                );
            }
        }
    }

    // Fontconfig
    _ = b.systemIntegrationOption("fontconfig", .{}); // Shows it in help
    if (self.config.font_backend.hasFontconfig()) {
        if (b.lazyDependency("fontconfig", .{
            .target = target,
            .optimize = optimize,
        })) |fontconfig_dep| {
            module.addImport(
                "fontconfig",
                fontconfig_dep.module("fontconfig"),
            );

            if (b.systemIntegrationOption("fontconfig", .{})) {
                module.linkSystemLibrary("fontconfig", dynamic_link_opts);
            } else {
                module.linkLibrary(fontconfig_dep.artifact("fontconfig"));
                try static_libs.append(
                    fontconfig_dep.artifact("fontconfig").getEmittedBin(),
                );
            }
        }
    }

    // Libpng - Ghostty doesn't actually use this directly, its only used
    // through dependencies, so we only need to add it to our static
    // libs list if we're not using system integration. The dependencies
    // will handle linking it.
    if (!b.systemIntegrationOption("libpng", .{})) {
        if (b.lazyDependency("libpng", .{
            .target = target,
            .optimize = optimize,
        })) |libpng_dep| {
            module.linkLibrary(libpng_dep.artifact("png"));
            try static_libs.append(
                libpng_dep.artifact("png").getEmittedBin(),
            );
        }
    }

    // Zlib - same as libpng, only used through dependencies.
    if (!b.systemIntegrationOption("zlib", .{})) {
        if (b.lazyDependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })) |zlib_dep| {
            module.linkLibrary(zlib_dep.artifact("z"));
            try static_libs.append(
                zlib_dep.artifact("z").getEmittedBin(),
            );
        }
    }

    // Oniguruma
    if (b.lazyDependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
    })) |oniguruma_dep| {
        module.addImport(
            "oniguruma",
            oniguruma_dep.module("oniguruma"),
        );
        if (b.systemIntegrationOption("oniguruma", .{})) {
            module.linkSystemLibrary("oniguruma", dynamic_link_opts);
        } else {
            module.linkLibrary(oniguruma_dep.artifact("oniguruma"));
            try static_libs.append(
                oniguruma_dep.artifact("oniguruma").getEmittedBin(),
            );
        }
    }

    // Glslang
    if (b.lazyDependency("glslang", .{
        .target = target,
        .optimize = optimize,
    })) |glslang_dep| {
        module.addImport("glslang", glslang_dep.module("glslang"));
        if (b.systemIntegrationOption("glslang", .{})) {
            module.linkSystemLibrary("glslang", dynamic_link_opts);
            module.linkSystemLibrary(
                "glslang-default-resource-limits",
                dynamic_link_opts,
            );
        } else {
            module.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    }

    // Spirv-cross
    if (b.lazyDependency("spirv_cross", .{
        .target = target,
        .optimize = optimize,
    })) |spirv_cross_dep| {
        module.addImport(
            "spirv_cross",
            spirv_cross_dep.module("spirv_cross"),
        );
        if (b.systemIntegrationOption("spirv-cross", .{})) {
            module.linkSystemLibrary("spirv-cross", dynamic_link_opts);
        } else {
            module.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    }

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        module.linkSystemLibrary("simdutf", dynamic_link_opts);
    } else {
        if (b.lazyDependency("simdutf", .{
            .target = target,
            .optimize = optimize,
        })) |simdutf_dep| {
            module.linkLibrary(simdutf_dep.artifact("simdutf"));
            try static_libs.append(
                simdutf_dep.artifact("simdutf").getEmittedBin(),
            );
        }
    }

    // Sentry
    if (self.config.sentry) {
        if (b.lazyDependency("sentry", .{
            .target = target,
            .optimize = optimize,
            .backend = .breakpad,
        })) |sentry_dep| {
            module.addImport(
                "sentry",
                sentry_dep.module("sentry"),
            );
            module.linkLibrary(sentry_dep.artifact("sentry"));
            try static_libs.append(
                sentry_dep.artifact("sentry").getEmittedBin(),
            );

            // We also need to include breakpad in the static libs.
            if (sentry_dep.builder.lazyDependency("breakpad", .{
                .target = target,
                .optimize = optimize,
            })) |breakpad_dep| {
                try static_libs.append(
                    breakpad_dep.artifact("breakpad").getEmittedBin(),
                );
            }
        }
    }

    // Wasm we do manually since it is such a different build.
    if (resolved_target.cpu.arch == .wasm32) {
        const js_dep = b.dependency("zig_js", .{
            .target = target,
            .optimize = optimize,
        });
        module.addImport("zig-js", js_dep.module("zig-js"));

        return static_libs;
    }

    // On Linux, we need to add a couple common library paths that aren't
    // on the standard search list. i.e. GTK is often in /usr/lib/x86_64-linux-gnu
    // on x86_64.
    if (resolved_target.os.tag == .linux) {
        const triple = try resolved_target.linuxTriple(b.allocator);
        const path = b.fmt("/usr/lib/{s}", .{triple});
        if (std.fs.accessAbsolute(path, .{})) {
            module.addLibraryPath(.{ .cwd_relative = path });
        } else |_| {}
    }

    // C files
    module.link_libc = true;
    module.addIncludePath(b.path("src/stb"));
    module.addCSourceFiles(.{ .files = &.{"src/stb/stb.c"} });
    if (resolved_target.os.tag == .linux) {
        module.addIncludePath(b.path("src/apprt/gtk"));
    }

    // C++ files
    module.link_libcpp = true;
    module.addIncludePath(b.path("src"));
    {
        // From hwy/detect_targets.h
        const HWY_AVX3_SPR: c_int = 1 << 4;
        const HWY_AVX3_ZEN4: c_int = 1 << 6;
        const HWY_AVX3_DL: c_int = 1 << 7;
        const HWY_AVX3: c_int = 1 << 8;

        // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
        // To workaround this we just disable AVX512 support completely.
        // The performance difference between AVX2 and AVX512 is not
        // significant for our use case and AVX512 is very rare on consumer
        // hardware anyways.
        const HWY_DISABLED_TARGETS: c_int = HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3;

        module.addCSourceFiles(.{
            .files = &.{
                "src/simd/base64.cpp",
                "src/simd/codepoint_width.cpp",
                "src/simd/index_of.cpp",
                "src/simd/vt.cpp",
            },
            .flags = if (resolved_target.cpu.arch == .x86_64) &.{
                b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
            } else &.{},
        });
    }

    // We always require the system SDK so that our system headers are available.
    // This makes things like `os/log.h` available for cross-compiling.
    if (resolved_target.os.tag.isDarwin()) {
        try @import("apple_sdk").addPaths(b, module);

        const metallib = self.metallib.?;
        // metallib.output.addStepDependencies(&step.step);
        module.addAnonymousImport("ghostty_metallib", .{
            .root_source_file = metallib.output,
        });
    }

    // Other dependencies, mostly pure Zig
    if (b.lazyDependency("opengl", .{})) |dep| {
        module.addImport("opengl", dep.module("opengl"));
    }
    if (b.lazyDependency("vaxis", .{})) |dep| {
        module.addImport("vaxis", dep.module("vaxis"));
    }
    if (b.lazyDependency("wuffs", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        module.addImport("wuffs", dep.module("wuffs"));
    }
    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        module.addImport("xev", dep.module("xev"));
    }
    if (b.lazyDependency("z2d", .{})) |dep| {
        module.addImport("z2d", b.addModule("z2d", .{
            .root_source_file = dep.path("src/z2d.zig"),
            .target = target,
            .optimize = optimize,
        }));
    }
    if (b.lazyDependency("ziglyph", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        module.addImport("ziglyph", dep.module("ziglyph"));
    }
    if (b.lazyDependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    })) |dep| {
        module.addImport("zf", dep.module("zf"));
    }

    // Mac Stuff
    if (resolved_target.os.tag.isDarwin()) {
        if (b.lazyDependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        })) |objc_dep| {
            module.addImport(
                "objc",
                objc_dep.module("objc"),
            );
        }

        if (b.lazyDependency("macos", .{
            .target = target,
            .optimize = optimize,
        })) |macos_dep| {
            module.addImport(
                "macos",
                macos_dep.module("macos"),
            );
            module.linkLibrary(
                macos_dep.artifact("macos"),
            );
            try static_libs.append(
                macos_dep.artifact("macos").getEmittedBin(),
            );
        }

        if (self.config.renderer == .opengl) {
            module.linkFramework("OpenGL", .{});
        }

        // Apple platforms do not include libc libintl so we bundle it.
        // This is LGPL but since our source code is open source we are
        // in compliance with the LGPL since end users can modify this
        // build script to replace the bundled libintl with their own.
        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            module.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
    }

    // cimgui
    if (b.lazyDependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    })) |cimgui_dep| {
        module.addImport("cimgui", cimgui_dep.module("cimgui"));
        module.linkLibrary(cimgui_dep.artifact("cimgui"));
        try static_libs.append(cimgui_dep.artifact("cimgui").getEmittedBin());
    }

    // Highway
    if (b.lazyDependency("highway", .{
        .target = target,
        .optimize = optimize,
    })) |highway_dep| {
        module.linkLibrary(highway_dep.artifact("highway"));
        try static_libs.append(highway_dep.artifact("highway").getEmittedBin());
    }

    // utfcpp - This is used as a dependency on our hand-written C++ code
    if (b.lazyDependency("utfcpp", .{
        .target = target,
        .optimize = optimize,
    })) |utfcpp_dep| {
        module.linkLibrary(utfcpp_dep.artifact("utfcpp"));
        try static_libs.append(utfcpp_dep.artifact("utfcpp").getEmittedBin());
    }

    // If we're building an exe then we have additional dependencies.
    // if (module.kind != .lib) {
    // We always statically compile glad
    module.addIncludePath(b.path("vendor/glad/include/"));
    module.addCSourceFile(.{
        .file = b.path("vendor/glad/src/gl.c"),
        .flags = &.{},
    });

    // When we're targeting flatpak we ALWAYS link GTK so we
    // get access to glib for dbus.
    if (self.config.flatpak) module.linkSystemLibrary("gtk4", dynamic_link_opts);

    switch (self.config.app_runtime) {
        .none => {},

        .glfw => if (b.lazyDependency("glfw", .{
            .target = target,
            .optimize = optimize,
        })) |glfw_dep| {
            module.addImport(
                "glfw",
                glfw_dep.module("glfw"),
            );
        },

        .gtk => {},
    }
    // }

    self.help_strings.addModuleImport(module);
    self.unicode_tables.addModuleImport(module);
    self.framedata.addModuleImport(module);

    return static_libs;
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
