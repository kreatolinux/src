{
  description = "A basic flake with a shell";

  # ------------------------------------------------------------------------------------------------

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nimble.url = "github:nix-community/flake-nimble";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  # ------------------------------------------------------------------------------------------------

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nimble,
    ...
  }: let
    inherit (self) lastModifiedDate;
    inherit (builtins) substring;
    version = substring 0 8 lastModifiedDate;

    inherit (flake-utils.lib) system eachSystem;
    systems = with system; [x86_64-linux aarch64-linux];

    packagesFn = pkgs: import ./nix {inherit pkgs version;};

    overlays = [nimble.overlay];
  in
    eachSystem systems (system: let
      pkgs = import nixpkgs {
        inherit system overlays;
      };
    in {
      packages = let
        packages = packagesFn pkgs;
      in
        packages // {default = packages.kpkg;};

      checks = let
        inherit (pkgs) nim runCommand;
      in {
        nimpretty =
          runCommand "nimpretty" {
            buildInputs = [nim];
          }
          ''
            mkdir $out
            find ${./src} -type f -name '*.nim' | xargs nimpretty
          '';
      };

      devShells = let
        inherit (pkgs) gnumake mkShell nim nimPackages;
      in {
        default = mkShell {
          packages = with nimPackages; [gnumake nim cligen libsha];
        };
      };
    })
    // (let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        inherit overlays;
      };
    in {
      # cross-compiled arm and static packages
      arm = let
        armPkgs = pkgs.pkgsCross.aarch64-multiplatform.pkgsStatic;
      in
        packagesFn armPkgs;

      static = packagesFn pkgs.pkgsStatic;
    });
}
