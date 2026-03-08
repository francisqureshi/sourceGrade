{
  description = "sourceGrade dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-overlay.follows = "zig-overlay";
    };
  };

  outputs = { self, nixpkgs, zig-overlay, zls }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    zig = zig-overlay.packages.${system}."master";
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        zig
        zls.packages.${system}.default

        # Vulkan runtime and dev tools
        # (headers are bundled via vulkan-zig in build.zig.zon)
        pkgs.vulkan-loader           # runtime ICD loader
        pkgs.vulkan-validation-layers # validation layers for debugging
        pkgs.vulkan-tools            # vulkaninfo
        pkgs.shaderc                 # glslc - GLSL/HLSL -> SPIR-V compiler
        pkgs.spirv-tools             # SPIR-V utilities

        # we need to link all the 'graphical' dependencies so sdl can actually initialize
        pkgs.libGL
        pkgs.wayland
        pkgs.libxkbcommon
        pkgs.libdecor
        pkgs.xorg.libX11
        pkgs.xorg.libXcursor
        pkgs.xorg.libXrandr
        pkgs.xorg.libXi
      ];

      shellHook = ''
        export VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d"
        export LD_LIBRARY_PATH="${pkgs.vulkan-loader}/lib:${pkgs.libGL}/lib:${pkgs.wayland}/lib:${pkgs.libxkbcommon}/lib:${pkgs.libdecor}/lib:${pkgs.xorg.libX11}/lib:${pkgs.xorg.libXcursor}/lib:${pkgs.xorg.libXrandr}/lib:${pkgs.xorg.libXi}/lib:$LD_LIBRARY_PATH"
      '';
    };
  };
}
