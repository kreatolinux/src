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

    # ------------------------------------------------------------------------------------------------

    inherit (flake-utils.lib) system eachSystem;
    systems = with system; [x86_64-linux aarch64-linux];

    # ------------------------------------------------------------------------------------------------

    packagesFn = pkgs: import ./nix {inherit pkgs version;};

    # ------------------------------------------------------------------------------------------------

    nixpkgsFor = nixpkgs.lib.genAttrs systems (system:
      import nixpkgs {
        inherit system;
        overlays = [nimble.overlay];
      });
  in
    eachSystem systems (system: let
      pkgs = nixpkgsFor.${system};
    in {
      # ------------------------------------------------------------------------------------------------
      packages = let
        packages = packagesFn pkgs;
      in
        packages // {default = packages.kpkg;};

      # ------------------------------------------------------------------------------------------------

      # statically compiled packages
      static = packagesFn pkgs.pkgsStatic;

      # ------------------------------------------------------------------------------------------------

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

      # ------------------------------------------------------------------------------------------------

      devShells = {
        default = with pkgs;
          mkShell {
            packages = [gnumake nim];
          };
      };
    })
    # ------------------------------------------------------------------------------------------------
    # cross-compiled and optionally static arm packages
    // (let
      pkgs = nixpkgsFor."x86_64-linux";
      inherit (pkgs.pkgsCross) aarch64-multiplatform;
    in {
      arm =
        packagesFn aarch64-multiplatform
        // {
          static = packagesFn aarch64-multiplatform.pkgsStatic;
        };
    });

  # ------------------------------------------------------------------------------------------------
}
