{
  description = "openlv-dart devshell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    rust-overlay,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [rust-overlay.overlays.default];
      };
      uniffi-bindgen-dart = pkgs.rustPlatform.buildRustPackage (final: {
        pname = "uniffi-bindgen-dart";
        version = "0.2.0";
        src = pkgs.fetchCrate {
          inherit (final) pname version;
          hash = "sha256-YPf7deb2fYokM+gEuWFNF157t+3y7eQLuPNWkL+VG2I=";
        };
        cargoHash = "sha256-6k3zcYLxjziOTVwCClusucSiJhyaaVsGwYpg2A7d8eI=";
        doCheck = false;
      });
    in {
      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.rust-bin.stable.latest.default
          pkgs.flutter341
          uniffi-bindgen-dart
        ];
      };
    });
}
