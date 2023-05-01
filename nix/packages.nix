# ------------------------------------------------------------------------------------------------
# declare packages
# ------------------------------------------------------------------------------------------------
{
  buildDeps,
  isStatic,
  nimBuild,
  pkgs,
}: rec {
  # ------------------------------------------------------------------------------------------------
  kpkg = nimBuild {
    name = "kpkg";
    nativeBuildInputs = with buildDeps; [cligen libsha];
    propagatedBuildInputs = let
      git = pkgs.git.override {doInstallCheck = false;};
    in
      (with pkgs; [libarchive shadow openssl])
      ++ (
        if isStatic
        then [git]
        else [pkgs.git]
      );
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
