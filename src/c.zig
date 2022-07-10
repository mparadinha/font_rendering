pub const c = struct {
    usingnamespace @cImport({
        @cInclude("unistd.h");
        @cDefine("GLFW_INCLUDE_NONE", "1");
        @cInclude("GLFW/glfw3.h");
    });
};
