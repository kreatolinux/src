import os
import times
import osproc
import sequtils
import strutils
import parsecfg
import posix_utils
import ../modules/commonProcs
import ../../common/logging
import ../../common/version
import ../../kpkg/commands/buildcmd
import ../../kpkg/commands/updatecmd
import ../../kpkg/commands/installcmd
import ../../kpkg/modules/commonTasks
import ../modules/package_sets
import ../modules/resources

## Kreato Linux's build tools.


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
        buildDir: string, useCacheIfPossible = true, target = kpkgTarget(
            buildDir),
        noSandbox = false) =
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
            forceInstallAll = true, target = targetFin,
            noSandbox = noSandbox)
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

proc runRootfs*(buildType = "builder", arch = "amd64",
        useCacheIfPossible = true, noSandbox = false, dataDir = "",
        configPath = "", overlayPath = "") =
  ## Build a Kreato Linux rootfs.
  ##
  ## With noSandbox, every source build skips the kpkg sandbox and builds
  ## directly in the root it runs on. Use this when kreastrap itself runs
  ## inside a chroot or seed image (e.g. bootstrapping a foreign arch from a
  ## Ubuntu base): there is no kpkg environment or overlay stack to set up
  ## there, and the chroot is already the isolation boundary.

  if not isAdmin():
    fatal "You have to be root to continue."

  let invocationDir = getCurrentDir()
  defer:
    if dirExists(invocationDir):
      setCurrentDir(invocationDir)

  var conf: Config
  var target = "default"

  var resources: string
  try:
    resources = resolveResourceDir("rootfs", dataDir)
  except ValueError as exc:
    fatal exc.msg
  let configFile = if configPath.len > 0: absolutePath(configPath)
                   else: resources / "arch" / arch / "configs" / (buildType & ".conf")
  let overlayDir = if overlayPath.len > 0: absolutePath(overlayPath)
                   else: resources / "overlay"
  if fileExists(configFile):
    conf = loadConfig(configFile)
  else:
    fatal("Config does not exist: " & configFile)
  if overlayPath.len > 0 and not dirExists(overlayDir):
    fatal("Overlay does not exist: " & overlayDir)

  # kpkg can change cwd during updates and builds. Resolve the output path
  # once, against the caller's cwd, and keep kreato-release on that same path.
  let configuredBuildDir = conf.getSectionValue("General", "BuildDirectory")
  if configuredBuildDir.len == 0:
    fatal("General.BuildDirectory must not be empty")
  let buildDir = absolutePath(configuredBuildDir, invocationDir)
  conf.setSectionKey("General", "BuildDirectory", buildDir)

  info "rootfs, built with commit "&commitVer

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

  initDirectories(buildDir, arch)

  if conf.getSectionValue("General", "useOverlay") != "false" and dirExists(
          overlayDir):
    info "Overlay found, installing contents"

    for kind, path in walkDir(overlayDir):
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
          useCacheIfPossible, target, noSandbox)

  # Installation of TLS library
  case conf.getSectionValue("Core", "TlsLibrary").normalize():
    of "openssl":
      info "Installing OpenSSL as TLS Library"
      kreastrapInstall("openssl", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
    of "libressl":
      info "Installing LibreSSL as TLS library"
      kreastrapInstall("libressl", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
    else:
      fatal conf.getSectionValue("Core",
              "TlsLibrary")&" is not available as a TLS library option."

  # Installation of a Compiler
  case conf.getSectionValue("Core", "Compiler").normalize():
    of "gcc":
      info "Installing GCC as Compiler"
      kreastrapInstall("gcc", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
      set_default_cc(buildDir, "gcc")
      kreastrapInstall("gmake", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
    of "clang":
      info "Installing clang as Compiler"
      kreastrapInstall("llvm", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
      set_default_cc(buildDir, "clang")
      kreastrapInstall("gmake", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
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
              useCacheIfPossible, target, noSandbox)
    of "musl":
      info "Installing musl as libc"
      kreastrapInstall("musl", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
    else:
      fatal conf.getSectionValue("Core",
              "Libc")&" is not available as a Libc option."

  # Installation of Core utilities
  case conf.getSectionValue("Core", "Coreutils").normalize():
    of "busybox":
      info "Installing BusyBox as Coreutils"
      kreastrapInstall("busybox", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
    of "gnu":
      info "Installing GNU Coreutils as Coreutils"

      kreastrapInstall("gnu-core", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)

      # /bin/sh may already exist (e.g. busybox) from the base rootfs;
      # replace it so GNU coreutils environments get bash as the default sh.
      if fileExists(buildDir&"/bin/sh") or symlinkExists(buildDir&"/bin/sh"):
        removeFile(buildDir&"/bin/sh")
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
              useCacheIfPossible, target, noSandbox)
      removeFile(buildDir&"/sbin/init")
      createSymlink("/bin/jumpstart", buildDir&"/sbin/init")
    of "openrc":
      info "Installing OpenRC as the init system"
      kreastrapInstall("openrc", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
      removeFile(buildDir&"/sbin/init")
      createSymlink("/usr/bin/openrc-init", buildDir&"/sbin/init")
    of "systemd":
      info "Installing systemd as the init system"
      kreastrapInstall("systemd", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
      kreastrapInstall("dbus", installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
      removeFile(buildDir&"/sbin/init")
      createSymlink("/lib/systemd/systemd", buildDir&"/sbin/init")

  # Install libxcrypt before shadow: shadow's pwconv links libcrypt.so.1
  # (the glibc-ABI soname), which only exists if libxcrypt was built with
  # --enable-obsolete-api=yes (the runfile on master does this).
  info "Installing libxcrypt (libcrypt provider)"
  kreastrapInstall("libxcrypt", installWithBinaries, buildDir,
          useCacheIfPossible, target, noSandbox)

  # Install shadow, and enable it
  kreastrapInstall("shadow", installWithBinaries, buildDir,
          useCacheIfPossible, target, noSandbox)

  # kpkg removes its source dir after builds; kreastrap's cwd may then point
  # into the removed tree, which makes the chroot execs below fail with an
  # unhandled ENOENT. Move to a directory that always exists first.
  setCurrentDir(getAppDir())

  let enableShadowedPw = execCmdEx("chroot "&buildDir&" /usr/sbin/pwconv")
  if enableShadowedPw.exitcode != 0:
    debug enableShadowedPw.output
    fatal "Enabling shadow failed"

  for package in caCertificatePackages():
    kreastrapInstall(package, installWithBinaries, buildDir,
            useCacheIfPossible, target, noSandbox)

  # Generate certdata here
  info "Generating CA certificates"

  # kpkg may have deleted its source dir (and kreastrap's cwd with it)
  # while installing the ca-certificates chain.
  setCurrentDir(getAppDir())

  let caCertCmd = execCmdEx("chroot "&buildDir&" /bin/sh -c 'update-ca-trust'")

  if caCertCmd.exitcode != 0:
    debug "CA certification generation output: "&caCertCmd.output
    fatal "Generating CA certificates failed"
  else:
    ok "Generated CA certificates"

  removeFile(buildDir&"/certdata.txt")

  info "Installing Python (and pip)"
  kreastrapInstall("python", installWithBinaries, buildDir,
          useCacheIfPossible, target, noSandbox)
  kreastrapInstall("python-pip", installWithBinaries, buildDir,
          useCacheIfPossible, target, noSandbox)

  if conf.getSectionValue("Extras", "ExtraPackages") != "":
    info "Installing extra packages"
    for i in conf.getSectionValue("Extras", "ExtraPackages").split(" "):
      kreastrapInstall(i, installWithBinaries, buildDir,
              useCacheIfPossible, target, noSandbox)
