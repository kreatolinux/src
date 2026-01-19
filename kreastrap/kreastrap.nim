import os
import times
import osproc
import cligen
import sequtils
import strutils
import parsecfg
import posix_utils
import commonProcs
import ../common/logging
import ../common/version
import ../kpkg/commands/buildcmd
import ../kpkg/commands/updatecmd
import ../kpkg/commands/installcmd
import ../kpkg/modules/commonTasks

## Kreato Linux's build tools.

# Initialize logging for kreastrap
initLogger("kreastrap", "", "/var/log/kreastrap.log")

clCfg.version = "kreastrap, built with commit "&commitVer


proc initKrelease(conf: Config) =
  # Initialize kreato-release.

  var config = newConfig()

  #
  # General
  #
  config.setSectionKey("General", "dateBuilt", getDateStr())
  config.setSectionKey("General", "klinuxVersion", conf.getSectionValue(
          "General", "klinuxVersion", "rolling"))
  config.setSectionKey("General", "srcCommit", commitVer)

  #
  # Core
  #
  config.setSectionKey("Core", "libc", conf.getSectionValue("Core", "Libc"))
  config.setSectionKey("Core", "compiler", conf.getSectionValue("Core", "Compiler"))
  config.setSectionKey("Core", "coreutils", conf.getSectionValue("Core", "Coreutils"))
  config.setSectionKey("Core", "tlsLibrary", conf.getSectionValue("Core", "TlsLibrary"))
  config.setSectionKey("Core", "init", conf.getSectionValue("Core", "Init"))

  #
  # Extras
  #
  config.setSectionKey("Extras", "extraPackages", conf.getSectionValue(
          "Extras", "ExtraPackages"))

  config.writeConfig(conf.getSectionValue("General",
          "BuildDirectory")&"/etc/kreato-release")

proc kreastrapInstall(package: string, installWithBinaries: bool,
        buildDir: string, useCacheIfPossible = true, target = kpkgTarget(buildDir)) =
  # Install a package.
  info "Installing package '"&package&"'"

  var targetFin = target

  if targetFin == "default":
    targetFin = kpkgTarget(buildDir)

  if installWithBinaries == true:
    debug "Installing package as a binary"
    discard install(toSeq([package]), buildDir, true, target = targetFin,
            basePackage = true)
  else:
    debug "Building package from source"
    discard build(yes = true, root = "/", packages = toSeq([
            package]),
            useCacheIfAvailable = useCacheIfPossible,
            forceInstallAll = true, target = targetFin)
    discard install(toSeq([package]), buildDir, true, offline = true,
            target = targetFin, basePackage = true)

  ok("Package "&package&" installed successfully")

proc converterArch(arch: string): string =
  # Converts architectures to the different name.
  case arch:
    of "amd64":
      return "x86_64"
    of "arm64":
      return "aarch64"
    else:
      return arch

proc kreastrap(buildType = "builder", arch = "amd64",
        useCacheIfPossible = true) =
  ## Build a Kreato Linux rootfs.

  if not isAdmin():
    fatal "You have to be root to continue."

  var conf: Config
  var target = "default"

  if fileExists(getAppDir()&"/arch/"&arch&"/configs/"&buildType&".conf"):
    conf = loadConfig(getAppDir()&"/arch/"&arch&"/configs/"&buildType&".conf")
  else:
    fatal("Config "&buildType&" does not exist!")

  info "kreastrap, built with commit "&commitVer

  discard update()

  debug "Architecture is set as "&arch
  debug "Build type is "&buildType

  if converterArch(arch) != uname().machine:
    info "cross-compiling to '"&arch&"'"
    target = converterArch(arch)&"-linux-"
    case conf.getSectionValue("Core", "Libc").normalize():
      of "glibc":
        target = target&"gnu"
      of "musl":
        target = target&"musl"
      else:
        fatal conf.getSectionValue("Core",
                "Libc")&" is not available as a Libc option."

  let buildDir = conf.getSectionValue("General", "BuildDirectory")

  initDirectories(buildDir, arch)

  if conf.getSectionValue("General", "useOverlay") != "false" and dirExists(
          getAppDir()&"/overlay"):
    info "Overlay found, installing contents"

    setCurrentDir(getAppDir()&"/overlay")

    for kind, path in walkDir("."):
      case kind:
        of pcFile:
          debug "Adding the file '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(path)&"'"
          copyFile(path, buildDir&"/"&lastPathPart(path))
        of pcDir:
          debug "Adding the directory '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(path)&"'"
          copyDir(path, buildDir&"/"&lastPathPart(path))
        of pcLinkToFile:
          debug "Adding the symlinked file '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(
                  path)&"' (will not follow symlink)"
          copyFile(path, buildDir&"/"&lastPathPart(path), options = {})
        of pcLinkToDir:
          debug "Adding the symlinked directory '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(path)&"'"
          copyDir(path, buildDir&"/"&lastPathPart(path))

  var installWithBinaries: bool

  if conf.getSectionValue("General", "BuildPackages").normalize() ==
          "true" or conf.getSectionValue("General", "BuildPackages") == "yes":
    installWithBinaries = false
  else:
    installWithBinaries = true

  initKrelease(conf)

  # Install kreato-fs-essentials
  kreastrapInstall("kreato-fs-essentials", installWithBinaries, buildDir,
          useCacheIfPossible, target)

  # Installation of TLS library
  case conf.getSectionValue("Core", "TlsLibrary").normalize():
    of "openssl":
      info "Installing OpenSSL as TLS Library"
      kreastrapInstall("openssl", installWithBinaries, buildDir,
              useCacheIfPossible, target)
    of "libressl":
      info "Installing LibreSSL as TLS library"
      kreastrapInstall("libressl", installWithBinaries, buildDir,
              useCacheIfPossible, target)
    else:
      fatal conf.getSectionValue("Core",
              "TlsLibrary")&" is not available as a TLS library option."

  # Installation of a Compiler
  case conf.getSectionValue("Core", "Compiler").normalize():
    of "gcc":
      info "Installing GCC as Compiler"
      kreastrapInstall("gcc", installWithBinaries, buildDir,
              useCacheIfPossible, target)
      set_default_cc(buildDir, "gcc")
      kreastrapInstall("gmake", installWithBinaries, buildDir,
              useCacheIfPossible, target)
    of "clang":
      info "Installing clang as Compiler"
      kreastrapInstall("llvm", installWithBinaries, buildDir,
              useCacheIfPossible, target)
      set_default_cc(buildDir, "clang")
      kreastrapInstall("gmake", installWithBinaries, buildDir,
              useCacheIfPossible, target)
    of "no":
      warn "Skipping compiler installation"
    else:
      fatal conf.getSectionValue("Core",
              "Compiler")&" is not available as a Compiler option."

  # Installation of Libc
  case conf.getSectionValue("Core", "Libc").normalize():
    of "glibc":

      if conf.getSectionValue("Core", "Compiler").normalize() == "clang":
        warn "Combination of glibc with clang is currently not supported, please don't make an issue about it."

      info "Installing glibc as libc"
      kreastrapInstall("glibc", installWithBinaries, buildDir,
              useCacheIfPossible, target)
    of "musl":
      info "Installing musl as libc"
      kreastrapInstall("musl", installWithBinaries, buildDir,
              useCacheIfPossible, target)
    else:
      fatal conf.getSectionValue("Core",
              "Libc")&" is not available as a Libc option."

  # Installation of Core utilities
  case conf.getSectionValue("Core", "Coreutils").normalize():
    of "busybox":
      info "Installing BusyBox as Coreutils"
      kreastrapInstall("busybox", installWithBinaries, buildDir,
              useCacheIfPossible, target)
    of "gnu":
      info "Installing GNU Coreutils as Coreutils"

      kreastrapInstall("gnu-core", installWithBinaries, buildDir,
              useCacheIfPossible, target)

      createSymlink("/bin/bash", buildDir&"/bin/sh")
    else:
      fatal conf.getSectionValue("Core",
              "Coreutils")&" is not available as a Coreutils option."

  case conf.getSectionValue("Core", "Init").normalize():
    of "busybox":
      if conf.getSectionValue("Core", "Coreutils").normalize() != "busybox":
        fatal "You have to use busybox as coreutils to use it as the init system for now."
      else:
        info "Init system chosen as busybox init"
    of "jumpstart":
      info "Installing Jumpstart as the init system"
      kreastrapInstall("jumpstart", installWithBinaries, buildDir,
              useCacheIfPossible, target)
      removeFile(buildDir&"/sbin/init")
      createSymlink("/bin/jumpstart", buildDir&"/sbin/init")
    of "openrc":
      info "Installing OpenRC as the init system"
      kreastrapInstall("openrc", installWithBinaries, buildDir,
              useCacheIfPossible, target)
      removeFile(buildDir&"/sbin/init")
      createSymlink("/usr/bin/openrc-init", buildDir&"/sbin/init")
    of "systemd":
      info "Installing systemd as the init system"
      kreastrapInstall("systemd", installWithBinaries, buildDir,
              useCacheIfPossible, target)
      kreastrapInstall("dbus", installWithBinaries, buildDir,
              useCacheIfPossible, target)
      removeFile(buildDir&"/sbin/init")
      createSymlink("/lib/systemd/systemd", buildDir&"/sbin/init")

  # Install shadow, and enable it
  kreastrapInstall("shadow", installWithBinaries, buildDir,
          useCacheIfPossible, target)

  let enableShadowedPw = execCmdEx("chroot "&buildDir&" /usr/sbin/pwconv")
  if enableShadowedPw.exitcode != 0:
    debug enableShadowedPw.output
    fatal "Enabling shadow failed"

  # Install kpkg, p11-kit and ca-certificates here
  kreastrapInstall("kpkg", installWithBinaries, buildDir, useCacheIfPossible, target)
  kreastrapInstall("p11-kit", installWithBinaries, buildDir,
          useCacheIfPossible, target)
  kreastrapInstall("ca-certificates", installWithBinaries, buildDir,
          useCacheIfPossible, target)

  # Install timezone database
  kreastrapInstall("tzdb", installWithBinaries, buildDir, useCacheIfPossible, target)

  # Generate certdata here
  info "Generating CA certificates"

  let caCertCmd = execCmdEx("chroot "&buildDir&" /bin/sh -c 'update-ca-trust'")

  if caCertCmd.exitcode != 0:
    debug "CA certification generation output: "&caCertCmd.output
    fatal "Generating CA certificates failed"
  else:
    ok "Generated CA certificates"

  removeFile(buildDir&"/certdata.txt")

  info "Installing Python (and pip)"
  kreastrapInstall("python", installWithBinaries, buildDir,
          useCacheIfPossible, target)
  kreastrapInstall("python-pip", installWithBinaries, buildDir,
          useCacheIfPossible, target)

  if conf.getSectionValue("Extras", "ExtraPackages") != "":
    info "Installing extra packages"
    for i in conf.getSectionValue("Extras", "ExtraPackages").split(" "):
      kreastrapInstall(i, installWithBinaries, buildDir,
              useCacheIfPossible, target)

when isMainModule:
  dispatch kreastrap, help = {
              "buildType": "Specify the build type",
              "arch": "Specify the architecture",
              "useCacheIfPossible": "Use already built packages if possible"
  }
