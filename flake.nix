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
    nimBuild = "nim c -d:release -d:branch-master --threads:on -d:ssl --nimcache:.cache/";
  in {
    packages =
      forAllSystems
      (system: let
        pkgs = nixpkgsFor.${system};
      in rec {
        kpkg = pkgs.stdenv.mkDerivation rec {
          pname = "kpkg";
          inherit version;

          src = ./.;
          nativeBuildInputs = with pkgs; with pkgs.nimPackages; [nim cligen libsha];

          buildPhase = ''
            ${nimBuild} -p:${pkgs.nimPackages.cligen} -p:${pkgs.nimPackages.libsha} -o=./out/${pname} ./src/${pname}/${pname}.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp out/${pname} $out/bin/
          '';
        };
        chkupd = pkgs.stdenv.mkDerivation rec {
          pname = "chkupd";
          inherit version;

          src = ./.;
          nativeBuildInputs = with pkgs; with pkgs.nimPackages; [nim cligen libsha];

          buildPhase = ''
            ${nimBuild} -p:${pkgs.nimPackages.cligen} -p:${pkgs.nimPackages.libsha} -o=./out/${pname} ./src/${pname}/${pname}.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp out/${pname} $out/bin/
          '';
        };
        mari = pkgs.stdenv.mkDerivation rec {
          pname = "mari";
          inherit version;

          src = ./.;
          nativeBuildInputs = with pkgs; with pkgs.nimPackages; [nim httpbeast libsha];

          buildPhase = ''
            ${nimBuild} -o=./out/${pname} ./src/${pname}/${pname}.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp out/${pname} $out/bin/
          '';
        };
        purr = pkgs.stdenv.mkDerivation rec {
          pname = "purr";
          inherit version;

          src = ./.;

          buildInputs = [kpkg];
          nativeBuildInputs = with pkgs; with pkgs.nimPackages; [nim cligen] ++ buildInputs;

          buildPhase = ''
            ${nimBuild} -p:${pkgs.nimPackages.libsha} -p:${pkgs.nimPackages.cligen} -o=./out/${pname} ./src/${pname}/${pname}.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp out/${pname} $out/bin
          '';
        };
        kreastrap = pkgs.stdenv.mkDerivation rec {
          pname = "kreastrap";
          inherit version;

          src = ./.;

          buildInputs = [purr];
          nativeBuildInputs = with pkgs; [nim] ++ buildInputs;

          buildPhase = ''
            ${nimBuild} -p:${pkgs.nimPackages.cligen} -p:${pkgs.nimPackages.libsha} -o=./out/${pname} ./src/${pname}/${pname}.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp out/${pname} $out/bin
          '';
        };
      });

    defaultPackage = forAllSystems (system: self.packages.${system}.kpkg);

    devShell = forAllSystems (system: let
      pkgs = nixpkgsFor.${system};
    in
      with pkgs;
      with pkgs.nimPackages;
        mkShell {
          packages = [gnumake nim cligen libsha];
        });

    meta = with nixpkgs.lib; {
      homepage = "https://github.com/kreatolinux/src";
      description = "Kreato Linux source tree";
      longDescription = ''
        The toolset with everything you need to build, test, and maintain Kreato Linux
      '';
      platforms = platforms.linux;
      license = licenses.gpl3Only;
      maintainers = with maintainers; [kreato getchoo];
    };
  };
}
