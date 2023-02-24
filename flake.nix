{
  description = "A basic flake with a shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nimble.url = "github:nix-community/flake-nimble";
  inputs.flake-compat = {
    url = "github:edolstra/flake-compat";
    flake = false;
  };

  outputs = {
    self,
    nixpkgs,
    nimble,
    flake-compat,
  }: let
    lastModifiedDate = self.lastModifiedDate or self.lastModified or "19700101";
    version = builtins.substring 0 8 lastModifiedDate;
    supportedSystems = ["x86_64-linux"];

    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    nixpkgsFor = forAllSystems (system:
      import nixpkgs {
        inherit system;
        overlays = [nimble.overlay];
      });
  in {
    packages =
      forAllSystems
      (system: let
        pkgs = nixpkgsFor.${system};

        libArgs = {name}: "-p:${pkgs.nimPackages.${name}}";

        nimBuild = {
          name,
          nativeBuild ? [],
          buildInputs ? [],
          args ? "",
        }: {
          ${name} = with pkgs;
            stdenv.mkDerivation rec {
              pname = name;
              inherit buildInputs version;

              src = ./.;
              nativeBuildInputs = [nim] ++ nativeBuild;

              buildPhase = ''
                nim compile -d:release -d:branch-master --threads:on -d:ssl --nimcache:.cache/ \
                  ${args} \
                  -o=./out/${pname} ./src/${pname}/${pname}.nim
              '';

              installPhase = ''
                mkdir -p $out/bin
                cp out/${pname} $out/bin/
              '';
            };
        };

        cligenArgs = libArgs {
          name = "cligen";
        };
        httpbeastArgs = libArgs {
          name = "httpbeast";
        };
        libshaArgs = libArgs {
          name = "libsha";
        };
      in
        with pkgs;
          (nimBuild {
            name = "kpkg";
            nativeBuild = with nimPackages; [cligen libsha];
            args = "${cligenArgs} ${libshaArgs}";
          })
          // (nimBuild {
            name = "chkupd";
            nativeBuild = with nimPackages; [cligen libsha];
            args = "${cligenArgs} ${libshaArgs}";
          })
          // (nimBuild {
            name = "mari";
            nativeBuild = with nimPackages; [httpbeast libsha];
            args = "${httpbeastArgs} ${libshaArgs}";
          })
          // (nimBuild {
            name = "purr";
            nativeBuild = with nimPackages; [cligen];
            args = cligenArgs;
            buildInputs = [self.packages.${system}.kpkg];
          })
          // (nimBuild {
            name = "kreastrap";
            buildInputs = [self.packages.${system}.purr];
            nativeBuild = buildInputs;
          }));

    checks = forAllSystems (system: let
      pkgs = nixpkgsFor.${system};
    in
      with pkgs; {
        nimpretty =
          runCommand "nimpretty" {
            buildInputs = [nim];
          }
          ''
            mkdir $out
            find ${./src} -type f -name '*.nim' | xargs nimpretty
          '';
      });

    defaultPackage = forAllSystems (system: self.packages.${system}.kpkg);

    devShell = forAllSystems (system: let
      pkgs = nixpkgsFor.${system};
    in
      with pkgs;
        mkShell {
          packages = with nimPackages; [gnumake nim cligen libsha];
        });
  };
}
