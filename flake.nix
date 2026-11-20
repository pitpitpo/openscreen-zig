{
  description = "OpenScreen - High-Performance Screen Recorder & Native Video Editor in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "openscreen";
          version = "1.0.0";
          src = ./.;

          nativeBuildInputs = with pkgs; [
            zig
            pkg-config
          ];

          buildInputs = with pkgs; [
            ffmpeg
            vulkan-loader
            vulkan-headers
            pipewire
            alsa-lib
            libpulseaudio
            xorg.libX11
            xorg.libXext
            xorg.libXfixes
            xorg.libXi
            dbus
          ];

          buildPhase = ''
            export XDG_CACHE_HOME="$TMPDIR/cache"
            zig build -Doptimize=ReleaseFast
          '';

          installPhase = ''
            mkdir -p $out/bin $out/share/applications $out/share/icons/hicolor/512x512/apps $out/share/openscreen
            cp zig-out/bin/openscreen $out/bin/
            cp packaging/linux/openscreen.desktop $out/share/applications/
            cp assets/openscreen.png $out/share/icons/hicolor/512x512/apps/
            cp -r assets $out/share/openscreen/
          '';
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/openscreen";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            ffmpeg
            vulkan-loader
            vulkan-headers
            pipewire
            alsa-lib
            libpulseaudio
            xorg.libX11
            xorg.libXext
            xorg.libXfixes
            xorg.libXi
            dbus
          ];
        };
      }
    );
}
