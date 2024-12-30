const ModuleDeps = @This();

const std = @import("std");
const Scanner = @import("zig_wayland").Scanner;
const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: ?*MetallibStep,
unicode_tables: UnicodeTables,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !ModuleDeps {
    var result: ModuleDeps = .{
        .config = cfg,
        .help_strings = try HelpStrings.init(b, cfg),
        .unicode_tables = try UnicodeTables.init(b),

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
        const harfbuzz_dep = b.dependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .@"enable-freetype" = true,
            .@"enable-coretext" = self.config.font_backend.hasCoretext(),
        });

        module.addImport(
            "harfbuzz",
            harfbuzz_dep.module("harfbuzz"),
        );
        if (b.systemIntegrationOption("harfbuzz", .{})) {
            module.linkSystemLibrary("harfbuzz", dynamic_link_opts);
        } else {
            module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
            try static_libs.append(harfbuzz_dep.artifact("harfbuzz").getEmittedBin());
        }
    }

    // Fontconfig
    _ = b.systemIntegrationOption("fontconfig", .{}); // Shows it in help
    if (self.config.font_backend.hasFontconfig()) {
        const fontconfig_dep = b.dependency("fontconfig", .{
            .target = target,
            .optimize = optimize,
        });
        module.addImport(
            "fontconfig",
            fontconfig_dep.module("fontconfig"),
        );

        if (b.systemIntegrationOption("fontconfig", .{})) {
            module.linkSystemLibrary("fontconfig", dynamic_link_opts);
        } else {
            module.linkLibrary(fontconfig_dep.artifact("fontconfig"));
            try static_libs.append(fontconfig_dep.artifact("fontconfig").getEmittedBin());
        }
    }

    // Libpng - Ghostty doesn't actually use this directly, its only used
    // through dependencies, so we only need to add it to our static
    // libs list if we're not using system integration. The dependencies
    // will handle linking it.
    if (!b.systemIntegrationOption("libpng", .{})) {
        const libpng_dep = b.dependency("libpng", .{
            .target = target,
            .optimize = optimize,
        });
        module.linkLibrary(libpng_dep.artifact("png"));
        try static_libs.append(libpng_dep.artifact("png").getEmittedBin());
    }

    // Zlib - same as libpng, only used through dependencies.
    if (!b.systemIntegrationOption("zlib", .{})) {
        const zlib_dep = b.dependency("zlib", .{
            .target = target,
            .optimize = optimize,
        });
        module.linkLibrary(zlib_dep.artifact("z"));
        try static_libs.append(zlib_dep.artifact("z").getEmittedBin());
    }

    // Oniguruma
    const oniguruma_dep = b.dependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("oniguruma", oniguruma_dep.module("oniguruma"));
    if (b.systemIntegrationOption("oniguruma", .{})) {
        module.linkSystemLibrary("oniguruma", dynamic_link_opts);
    } else {
        module.linkLibrary(oniguruma_dep.artifact("oniguruma"));
        try static_libs.append(oniguruma_dep.artifact("oniguruma").getEmittedBin());
    }

    // Glslang
    const glslang_dep = b.dependency("glslang", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("glslang", glslang_dep.module("glslang"));
    if (b.systemIntegrationOption("glslang", .{})) {
        module.linkSystemLibrary("glslang", dynamic_link_opts);
        module.linkSystemLibrary("glslang-default-resource-limits", dynamic_link_opts);
    } else {
        module.linkLibrary(glslang_dep.artifact("glslang"));
        try static_libs.append(glslang_dep.artifact("glslang").getEmittedBin());
    }

    // Spirv-cross
    const spirv_cross_dep = b.dependency("spirv_cross", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("spirv_cross", spirv_cross_dep.module("spirv_cross"));
    if (b.systemIntegrationOption("spirv-cross", .{})) {
        module.linkSystemLibrary("spirv-cross", dynamic_link_opts);
    } else {
        module.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
        try static_libs.append(spirv_cross_dep.artifact("spirv_cross").getEmittedBin());
    }

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        module.linkSystemLibrary("simdutf", dynamic_link_opts);
    } else {
        const simdutf_dep = b.dependency("simdutf", .{
            .target = target,
            .optimize = optimize,
        });
        module.linkLibrary(simdutf_dep.artifact("simdutf"));
        try static_libs.append(simdutf_dep.artifact("simdutf").getEmittedBin());
    }

    // Sentry
    if (self.config.sentry) {
        const sentry_dep = b.dependency("sentry", .{
            .target = target,
            .optimize = optimize,
            .backend = .breakpad,
        });

        module.addImport("sentry", sentry_dep.module("sentry"));

        // Sentry
        module.linkLibrary(sentry_dep.artifact("sentry"));
        try static_libs.append(sentry_dep.artifact("sentry").getEmittedBin());

        // We also need to include breakpad in the static libs.
        const breakpad_dep = sentry_dep.builder.dependency("breakpad", .{
            .target = target,
            .optimize = optimize,
        });
        try static_libs.append(breakpad_dep.artifact("breakpad").getEmittedBin());
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
        module.addLibraryPath(.{ .cwd_relative = b.fmt("/usr/lib/{s}", .{triple}) });
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
    if (resolved_target.isDarwin()) {
        try @import("apple_sdk").addPaths(b, module);

        const metallib = self.metallib.?;
        // metallib.output.addStepDependencies(&step.step);
        module.addAnonymousImport("ghostty_metallib", .{
            .root_source_file = metallib.output,
        });
    }

    // Other dependencies, mostly pure Zig
    module.addImport("opengl", b.dependency(
        "opengl",
        .{},
    ).module("opengl"));
    module.addImport("vaxis", b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    }).module("vaxis"));
    module.addImport("wuffs", b.dependency("wuffs", .{
        .target = target,
        .optimize = optimize,
    }).module("wuffs"));
    module.addImport("xev", b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev"));
    module.addImport("z2d", b.addModule("z2d", .{
        .root_source_file = b.dependency("z2d", .{}).path("src/z2d.zig"),
        .target = target,
        .optimize = optimize,
    }));
    module.addImport("ziglyph", b.dependency("ziglyph", .{
        .target = target,
        .optimize = optimize,
    }).module("ziglyph"));
    module.addImport("zf", b.dependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    }).module("zf"));

    // Mac Stuff
    if (resolved_target.isDarwin()) {
        const objc_dep = b.dependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        });
        const macos_dep = b.dependency("macos", .{
            .target = target,
            .optimize = optimize,
        });

        module.addImport("objc", objc_dep.module("objc"));
        module.addImport("macos", macos_dep.module("macos"));
        module.linkLibrary(macos_dep.artifact("macos"));
        try static_libs.append(macos_dep.artifact("macos").getEmittedBin());

        if (self.config.renderer == .opengl) {
            module.linkFramework("OpenGL", .{});
        }
    }

    // cimgui
    const cimgui_dep = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("cimgui", cimgui_dep.module("cimgui"));
    module.linkLibrary(cimgui_dep.artifact("cimgui"));
    try static_libs.append(cimgui_dep.artifact("cimgui").getEmittedBin());

    // Highway
    const highway_dep = b.dependency("highway", .{
        .target = target,
        .optimize = optimize,
    });
    module.linkLibrary(highway_dep.artifact("highway"));
    try static_libs.append(highway_dep.artifact("highway").getEmittedBin());

    // utfcpp - This is used as a dependency on our hand-written C++ code
    const utfcpp_dep = b.dependency("utfcpp", .{
        .target = target,
        .optimize = optimize,
    });
    module.linkLibrary(utfcpp_dep.artifact("utfcpp"));
    try static_libs.append(utfcpp_dep.artifact("utfcpp").getEmittedBin());

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

        .glfw => glfw: {
            const mach_glfw_dep = b.lazyDependency("mach_glfw", .{
                .target = target,
                .optimize = optimize,
            }) orelse break :glfw;
            module.addImport("glfw", mach_glfw_dep.module("mach-glfw"));
        },

        .gtk => {
            module.linkSystemLibrary("gtk4", dynamic_link_opts);
            if (self.config.adwaita) module.linkSystemLibrary("libadwaita-1", dynamic_link_opts);
            if (self.config.x11) module.linkSystemLibrary("X11", dynamic_link_opts);

            if (self.config.wayland) {
                const scanner = Scanner.create(b.dependency("zig_wayland", .{}), .{
                    // We shouldn't be using getPath but we need to for now
                    // https://codeberg.org/ifreund/zig-wayland/issues/66
                    .wayland_xml = b.dependency("wayland", .{})
                        .path("protocol/wayland.xml"),
                    .wayland_protocols = b.dependency("wayland_protocols", .{})
                        .path(""),
                });

                const wayland = b.createModule(.{ .root_source_file = scanner.result });

                const plasma_wayland_protocols = b.dependency("plasma_wayland_protocols", .{
                    .target = target,
                    .optimize = optimize,
                });
                scanner.addCustomProtocol(plasma_wayland_protocols.path("src/protocols/blur.xml"));

                scanner.generate("wl_compositor", 1);
                scanner.generate("org_kde_kwin_blur_manager", 1);

                module.addImport("wayland", wayland);
                module.linkSystemLibrary("wayland-client", dynamic_link_opts);
            }

            {
                const gresource = @import("../apprt/gtk/gresource.zig");

                const wf = b.addWriteFiles();
                const gresource_xml = wf.add("gresource.xml", gresource.gresource_xml);

                const generate_resources_c = b.addSystemCommand(&.{
                    "glib-compile-resources",
                    "--c-name",
                    "ghostty",
                    "--generate-source",
                    "--target",
                });
                const ghostty_resources_c = generate_resources_c.addOutputFileArg("ghostty_resources.c");
                generate_resources_c.addFileArg(gresource_xml);
                generate_resources_c.extra_file_dependencies = &gresource.dependencies;
                module.addCSourceFile(.{ .file = ghostty_resources_c, .flags = &.{} });

                const generate_resources_h = b.addSystemCommand(&.{
                    "glib-compile-resources",
                    "--c-name",
                    "ghostty",
                    "--generate-header",
                    "--target",
                });
                const ghostty_resources_h = generate_resources_h.addOutputFileArg("ghostty_resources.h");
                generate_resources_h.addFileArg(gresource_xml);
                generate_resources_h.extra_file_dependencies = &gresource.dependencies;
                module.addIncludePath(ghostty_resources_h.dirname());
            }
        },
    }
    // }

    self.help_strings.addModuleImport(module);
    self.unicode_tables.addModuleImport(module);

    return static_libs;
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
