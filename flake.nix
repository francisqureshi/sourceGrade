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
      ];

      shellHook = ''
        export VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d"
        export LD_LIBRARY_PATH="${pkgs.vulkan-loader}/lib:$LD_LIBRARY_PATH"
      '';
    };
  };
}
