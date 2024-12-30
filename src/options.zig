const Metal = @import("renderer/Metal.zig");
const OpenGL = @import("renderer/OpenGL.zig");
const WebGL = @import("renderer/WebGL.zig");
const glfw = @import("apprt/glfw.zig");
const gtk = @import("apprt/gtk.zig");
const none = @import("apprt/none.zig");
const browser = @import("apprt/browser.zig");
const embedded = @import("apprt/embedded.zig");
const build_config = @import("build_config.zig");
const root = @import("root");

/// Stdlib-wide options that can be overridden by the root file.
pub const options: type = if (@hasDecl(root, "ghostty_options")) root.ghostty_options else Options;
const Options = struct {
    pub const Renderer = switch (build_config.renderer) {
        .metal => Metal,
        .opengl => OpenGL,
        .webgl => WebGL,
    };
    pub const runtime = switch (build_config.artifact) {
        .exe => switch (build_config.app_runtime) {
            .none => none,
            .glfw => glfw,
            .gtk => gtk,
        },
        .lib => embedded,
        .wasm_module => browser,
    };
};
