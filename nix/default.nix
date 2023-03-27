{
  pkgs,
  version,
  ...
} @ inputs: let
  # ------------------------------------------------------------------------------------------------
  # helper to add generate information about
  # nim dependenices to use in nimBuild.
  # takes in the name of the dependency as a string
  newDep = name: {
    ${name} = {
      buildArgs = ''-p:${pkgs.nimPackages.${name}}'';
      deps = pkgs.nimPackages.${name};
    };
  };

  # ------------------------------------------------------------------------------------------------

  buildDeps =
    newDep "cligen"
    // newDep "libsha"
    # // newDep "httpbeast"
    # ------------------------------------------------------------------------------------------------
    # TODO: remove this if asynctools is ever bumped in flake-nimble
    # https://github.com/nix-community/flake-nimble/issues/17
    // (let
      inherit (pkgs.nimPackages) nim;

      httpbeast = pkgs.nimPackages.httpbeast.overrideAttrs (_: let
        # ------------------------------------------------------------------------------------------------
        asynctools = pkgs.nimPackages.asynctools.overrideAttrs (_: let
          # using the latest commit as of 2023-03-24
          # this should be somewhat ok for the long term
          # as the project hasn't been updated in a while
          rev = "84ced6d002789567f2396c75800ffd6dff2866f7";
        in {
          version = builtins.substring 0 8 rev;
          src = pkgs.fetchFromGitHub {
            owner = "cheatfate";
            repo = "asynctools";
            inherit rev;
            sha256 = "sha256-mrO+WeSzCBclqC2UNCY+IIv7Gs8EdTDaTeSgXy3TgNM=";
          };
        });
        # ------------------------------------------------------------------------------------------------
      in {
        propagatedBuildInputs = [asynctools nim];
        doCheck = false; # the test suite tries to touch $HOME...no.
      });
      # ------------------------------------------------------------------------------------------------
    in {
      httpbeast = {
        buildArgs = ''-p:${httpbeast}/src'';
        deps = httpbeast;
      };
    });

  # ------------------------------------------------------------------------------------------------

  # generic builder for nim packages (since we don't use nimble
  # and can't take advantage of buildNimPackage)
  nimBuild = {
    name,
    version ? inputs.version,
    nativeBuildInputs ? [],
    propagatedBuildInputs ? [],
  }: let
    # ------------------------------------------------------------------------------------------------
    inherit (builtins) catAttrs concatStringsSep hasAttr;
    inherit (pkgs) openssl nim stdenv;
    inherit (pkgs.lib) flatten;

    # ------------------------------------------------------------------------------------------------

    isStatic = pkgs.attr.dontDisableStatic;

    # collect and flatten args from attrsets in
    # our generated buildDeps
    buildArgs =
      (concatStringsSep " " (flatten (catAttrs "buildArgs" nativeBuildInputs)))
      # extra flags for static builds
      + (
        if isStatic
        then " --passL:-lssl --dynlibOverride:ssl --passL:-lcrypto --dynlibOverride:crypto --clibdir:${openssl.out}/lib"
        else ""
      );

    # ditto but with their deps
    nat = map (dep:
      if hasAttr "deps" dep
      then dep.deps
      else dep)
    nativeBuildInputs;
  in
    # ------------------------------------------------------------------------------------------------
    stdenv.mkDerivation rec {
      pname = name;
      inherit version propagatedBuildInputs;

      src = ../.;

      nativeBuildInputs = [nim] ++ nat;

      buildPhase = ''
        nim compile -d:release -d:branch-master --threads:on -d:ssl --nimcache:$TMPDIR \
          ${buildArgs} \
          -o=./out/${pname} ./src/${pname}/${pname}.nim
      '';

      installPhase = ''
        mkdir -p $out/bin
        cp out/${pname} $out/bin/
      '';
    };
in rec {
  # ------------------------------------------------------------------------------------------------
  kpkg = nimBuild {
    name = "kpkg";
    nativeBuildInputs = with buildDeps; [cligen libsha];
  };

  # ------------------------------------------------------------------------------------------------

  chkupd = nimBuild {
    name = "chkupd";
    nativeBuildInputs = with buildDeps; [cligen libsha];
  };

  # ------------------------------------------------------------------------------------------------

  mari = nimBuild {
    name = "mari";
    nativeBuildInputs = with buildDeps; [httpbeast libsha];
  };

  # ------------------------------------------------------------------------------------------------

  purr = nimBuild {
    name = "purr";
    nativeBuildInputs = with buildDeps; [cligen libsha];
    propagatedBuildInputs = [kpkg];
  };

  # ------------------------------------------------------------------------------------------------

  kreastrap = nimBuild rec {
    name = "kreastrap";
    nativeBuildInputs = with buildDeps; [cligen libsha];
    propagatedBuildInputs = [purr];
  };

  # ------------------------------------------------------------------------------------------------

  # dummy package to build everything at once
  all =
    pkgs.runCommand "build-all" {
      buildInputs = [kpkg chkupd mari purr kreastrap];
    } ''
      mkdir $out
    '';
}
