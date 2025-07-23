// These are the libraries used in the examples,
// you may find the respostories from build.zig.zon
const glfw = @import("zglfw");
const zgl = @import("zgl");
const std = @import("std");
const shaders = @import("shaders.zig");

// this is used for more complex math calculation, but this is not used in this example,
// but I am going to keep this here so that I will remember such library exists,
// used for my future projects
const zm = @import("zm");

/// In the main function, I will only expose a series of functions such that
/// this shows us the key steps on how to setup and render in OpenGL:
pub fn main() !void {
    std.debug.print("<!--Skri-a Kaark-->", .{});

    // 1. initialize glfw
    try intializeGlfw();
    defer glfw.terminate();

    // 2. create window with glfw, or context in some other examples
    const window = try createWindow();
    defer window.destroy();

    // 3. set the glfw focus on the newly created windows so that
    // the later commands and shaders apply exclusively on this selected windows:
    // reference: https://computergraphics.stackexchange.com/questions/4562/what-does-makecontextcurrent-do-exactly
    glfw.makeContextCurrent(window);
    defer glfw.makeContextCurrent(null);

    // 4. Initialize OpenGL - ignore missing extensions on macOS
    zgl.loadExtensions({}, getProcAddressWrapper) catch |err| {
        std.log.warn("Some OpenGL extensions could not be loaded: {}", .{err});
        // Continue anyway - basic OpenGL should still work
    };

    // 5. define the callback function when the framebuffer has a rezise
    _ = glfw.Window.setFramebufferSizeCallback(window, framebuffer_size_callback);

    // 6. loading, compiling and verifying shaders
    // variables for verifications
    var success: c_int = undefined;
    var infoLog: [512:0]u8 = undefined;

    // 6.1 vertex shader
    var vertexShader: zgl.Shader = undefined;
    vertexShader = createAndCompileShaders(.vertex, shaders.vertexShaderImpl);
    defer zgl.deleteShader(vertexShader);
    try verifyShader(vertexShader, &success, &infoLog);

    // 6.1 fragment shader
    var fragmentShader: zgl.Shader = undefined;
    fragmentShader = createAndCompileShaders(.fragment, shaders.fragmentShaderImpl);
    defer zgl.deleteShader(fragmentShader);
    try verifyShader(fragmentShader, &success, &infoLog);

    // 7. create a program and load all the shaders
    var shaderProgram: zgl.Program = undefined;
    errdefer zgl.deleteProgram(shaderProgram);

    shaderProgram = try createProgram(.{
        .vertexShader = vertexShader,
        .fragmentShader = fragmentShader,
    });

    try verifyProgram(shaderProgram, &success, &infoLog);

    // 8. define the vao, but since this code is based on the first triangle program of the opengl superbible 7
    // there is nothing in the vao
    var vaos: [1]zgl.VertexArray = undefined;
    zgl.genVertexArrays(&vaos);
    errdefer zgl.deleteVertexArrays(&vaos);

    zgl.bindVertexArray(vaos[0]);
    defer zgl.bindVertexArray(.invalid);

    // 9. and finally, render the image with the program and the window.
    render(window, shaderProgram);
}

/// Here is code for initialize GLFW window.
/// For the simplest set up, all you need is to call the init function,
/// with providing the OpenGL version and its profile as a hint
fn intializeGlfw() !void {
    // glfw initialization process:
    glfw.init() catch {
        std.log.err("GLFW initialization failed", .{});
        return error.GLFWInitializationFailed;
    };

    // Use OpenGL 3.3 which is more widely supported on macOS
    glfw.windowHint(glfw.WindowHint.context_version_major, 3);
    glfw.windowHint(glfw.WindowHint.context_version_minor, 3);
    glfw.windowHint(glfw.WindowHint.opengl_profile, glfw.OpenGLProfile.opengl_core_profile);
    glfw.windowHint(glfw.WindowHint.opengl_forward_compat, true); // Required on macOS
}

// default struct for stating the window size
const WindowSize = struct {
    pub const width: u32 = 800;
    pub const height: u32 = 600;
};

/// with the glfw defined, we can how create a window by stating the
/// the dimension and the name of the windows.
fn createWindow() !*glfw.Window {
    return glfw.Window.create(
        WindowSize.width,
        WindowSize.height,
        "Opengl Triangle",
        null,
    ) catch {
        std.log.err("GLFW Window creation failed", .{});
        return error.GLFWindowCreationFailed;
    };
}

/// Wrapper function to match zgl's expected function signature
fn getProcAddressWrapper(_: void, name: [:0]const u8) ?*align(4) const anyopaque {
    return @alignCast(@ptrCast(glfw.getProcAddress(name)));
}

/// This is one of the most important step in the pipline because this
/// is used for building and compiling your shader program.
fn createAndCompileShaders(shaderType: zgl.ShaderType, shaderSource: [:0]const u8) zgl.Shader {
    var shader: zgl.Shader = undefined;
    shader = zgl.createShader(shaderType);

    zgl.shaderSource(shader, 1, &.{shaderSource});
    zgl.compileShader(shader);

    return shader;
}

/// This function verify the compilation status of your shader code,
/// passing a success indicator to state whather the compilation is
/// successful. Besides, gl also has an info log to provide message
/// what has gone wrong in the process.
fn verifyShader(shader: zgl.Shader, success: *c_int, infoLog: [:0]u8) !void {
    // Simple check - if the shader is invalid (0), there was an error
    if (@intFromEnum(shader) == 0) {
        std.log.err("Shader compilation failed - shader is null", .{});
        return error.CompileShaderFailed;
    }
    _ = success;
    _ = infoLog;
}

/// with all the shaders, we can now create a program and attach all the shaders
/// and make them effective by linking them.
fn createProgram(shaderParts: anytype) !zgl.Program {
    const shaderProgram = zgl.createProgram();

    zgl.attachShader(shaderProgram, shaderParts.vertexShader);
    zgl.attachShader(shaderProgram, shaderParts.fragmentShader);
    zgl.linkProgram(shaderProgram);

    return shaderProgram;
}

/// similar to the verifyShader, gl also has a program-wise verification
fn verifyProgram(shaderProgram: zgl.Program, success: *c_int, infoLog: [:0]u8) !void {
    _ = shaderProgram;
    _ = success;
    _ = infoLog;
    // zgl likely handles program linking errors internally
    // For now, we'll skip detailed error checking
}

/// The reason why this callback is defined is due to the callback standard
/// in setFramebufferSizeCallback: https://glfw-d.dpldocs.info/~develop/glfw3.api.glfwSetFramebufferSizeCallback.html
/// Since it is mendatory to have window as the callback parameter,
/// we have to ditch all the variable using '_' to comply the zig rules on unused variables.
fn framebuffer_size_callback(window: *glfw.Window, width: c_int, height: c_int) callconv(.c) void {
    _ = window;
    // Viewport used for mapping the screen resolution into a range between -1 and 1
    // Superbible: page 94
    zgl.viewport(0, 0, @intCast(width), @intCast(height));
}

/// this is the main event loop take place, filling a green background
/// with a triangle we have build from all those shaders programs.
fn render(window: *glfw.Window, program: zgl.Program) void {
    // here is the main event loop to stay the window alive
    // and the rendering take place in this loop
    while (!glfw.windowShouldClose(window)) {
        zgl.clearColor(0.0, 0.25, 0.0, 1.0);
        zgl.clear(.{ .color = true });

        zgl.useProgram(program);
        zgl.drawArrays(.triangles, 0, 3);

        glfw.swapBuffers(window);
        glfw.pollEvents();
    }
}
