import os
import times
import osproc
import cligen
import sequtils
import strutils
import parsecfg
import posix_utils
import ../common/logging
import ../common/version
import ../kpkg/commands/buildcmd
import ../kpkg/modules/downloader
import ../kpkg/commands/updatecmd
import ../kpkg/commands/installcmd

## Kreato Linux's build tools.

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

proc initDirectories(buildDirectory: string, arch: string) =
    # Initializes directories.

    #if dirExists(buildDirectory):
    #    info_msg "rootfs directory exist, removing"
    #    removeDir(buildDirectory)

    debug "Making initial rootfs directories"

    createDir(buildDirectory)
    createDir(buildDirectory&"/etc")
    createDir(buildDirectory&"/usr")
    createDir(buildDirectory&"/usr/bin")
    createDir(buildDirectory&"/usr/lib")
    createDir(buildDirectory&"/var")
    createDir(buildDirectory&"/var/cache")
    createDir(buildDirectory&"/var/cache/kpkg")
    createDir(buildDirectory&"/boot")
    createDir(buildDirectory&"/root")
    createDir(buildDirectory&"/dev")
    createDir(buildDirectory&"/opt")
    createDir(buildDirectory&"/proc")
    createDir(buildDirectory&"/sys")
    createDir(buildDirectory&"/mnt")
    createDir(buildDirectory&"/media")
    createDir(buildDirectory&"/home")
    createDir(buildDirectory&"/tmp")
    createDir(buildDirectory&"/usr/local")
    createDir(buildDirectory&"/usr/local/lib")
    createDir(buildDirectory&"/usr/local/bin")
    createDir(buildDirectory&"/usr/local/sbin")
    createDir(buildDirectory&"/usr/local/include")
    createDir(buildDirectory&"/usr/include")

    # Set permissions for directories
    setFilePermissions(buildDirectory, {fpUserExec, fpUserRead, fpGroupExec,
            fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/etc", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/bin", {fpUserExec, fpUserRead,
            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/lib", {fpUserExec, fpUserRead,
            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/var", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/var/cache", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/var/cache/kpkg", {fpUserExec,
            fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/boot", {fpUserExec, fpUserRead,
            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/root", {fpUserExec, fpUserRead,
            fpGroupExec, fpGroupRead})

    setFilePermissions(buildDirectory&"/dev", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/opt", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/proc", {fpUserExec, fpUserRead,
            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/sys", {fpUserExec, fpUserRead,
            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/mnt", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/media", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/home", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/tmp", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupWrite, fpGroupRead, fpOthersExec,
            fpOthersWrite, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/local", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/local/lib", {fpUserExec,
            fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/local/bin", {fpUserExec,
            fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/local/sbin", {fpUserExec,
            fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/local/include", {fpUserExec,
            fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    setFilePermissions(buildDirectory&"/usr/include", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    createDir(buildDirectory&"/var/cache/kpkg/installed")
    createDir(buildDirectory&"/run")

    setFilePermissions(buildDirectory&"/run", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

    if arch == "amd64":
        createSymlink("usr/lib", buildDirectory&"/lib64")
        createSymlink("lib", buildDirectory&"/usr/lib64")

    createSymlink("usr/bin", buildDirectory&"/sbin")
    createSymlink("bin", buildDirectory&"/usr/sbin")
    createSymlink("usr/bin", buildDirectory&"/bin")
    createSymlink("usr/lib", buildDirectory&"/lib")

    info_msg "Root directory structure created."

proc kreastrapInstall(package: string, installWithBinaries: bool,
        buildDir: string, useCacheIfPossible = true, target = "default") =
    # Install a package.
    info_msg "Installing package '"&package&"'"
    if installWithBinaries == true:
        debug "Installing package as a binary"
        discard install(toSeq([package]), buildDir, true)
    else:
        debug "Building package from source"
        discard build(yes = true, root = "/", packages = toSeq([
                package]),
                useCacheIfAvailable = useCacheIfPossible,
                forceInstallAll = true, target = target)
        var arch = target.split("-")[0]
        if arch == "x86_64":
                arch = "amd64" # for compat purposes
        discard install(toSeq([package]), buildDir, true, offline = true, arch = arch)

    ok("Package "&package&" installed successfully")

proc set_default_cc(buildDir: string, cc: string) =
    ## Sets the default compiler.
    let files = ["/bin/gcc", "/bin/cc", "/bin/c99", "/bin/g++", "/bin/c++"]
    var file: string
    for i in files:
        file = buildDir&i
        if not fileExists(file):
            createSymlink(cc, file)

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
        error "You have to be root to continue."

    var conf: Config
    var target = "default"

    if fileExists(getAppDir()&"/arch/"&arch&"/configs/"&buildType&".conf"):
        conf = loadConfig(getAppDir()&"/arch/"&arch&"/configs/"&buildType&".conf")
    else:
        error("Config "&buildType&" does not exist!")

    info_msg "kreastrap, built with commit "&commitVer

    discard update()

    debug "Architecture is set as "&arch
    debug "Build type is "&buildType

    if converterArch(arch) != uname().machine:
        info_msg "cross-compiling to '"&arch&"'"
        target = converterArch(arch)&"-linux-"
        case conf.getSectionValue("Core", "Libc").normalize():
                of "glibc":
                        target = target&"gnu"
                of "musl":
                        target = target&"musl"
                else:
                        error conf.getSectionValue("Core","Libc")&" is not available as a Libc option."

    let buildDir = conf.getSectionValue("General", "BuildDirectory")

    initDirectories(buildDir, arch)

    if conf.getSectionValue("General", "useOverlay") != "false" and dirExists(
            getAppDir()&"/overlay"):
        info_msg "Overlay found, installing contents"

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

        # Installation of TLS library
        case conf.getSectionValue("Core", "TlsLibrary").normalize():
            of "openssl":
                info_msg "Installing OpenSSL as TLS Library"
                kreastrapInstall("openssl", installWithBinaries, buildDir, useCacheIfPossible, target)
            of "libressl":
                info_msg "Installing LibreSSL as TLS library"
                kreastrapInstall("libressl", installWithBinaries, buildDir, useCacheIfPossible, target)
            else:
                error conf.getSectionValue("Core",
                        "TlsLibrary")&" is not available as a TLS library option."

        # Installation of a Compiler
        case conf.getSectionValue("Core", "Compiler").normalize():
            of "gcc":
                info_msg "Installing GCC as Compiler"
                kreastrapInstall("gcc", installWithBinaries, buildDir, useCacheIfPossible, target)
                set_default_cc(buildDir, "gcc")
            of "clang":
                info_msg "Installing clang as Compiler"
                kreastrapInstall("llvm", installWithBinaries, buildDir, useCacheIfPossible, target)
                set_default_cc(buildDir, "clang")
            of "no":
                warn "Skipping compiler installation"
            else:
                error conf.getSectionValue("Core",
                        "Compiler")&" is not available as a Compiler option."

        # Installation of Libc
        case conf.getSectionValue("Core", "Libc").normalize():
            of "glibc":
                
                if conf.getSectionValue("Core", "Compiler").normalize() == "clang":
                  warn "Combination of glibc with clang is currently not supported, please don't make an issue about it."

                info_msg "Installing glibc as libc"
                kreastrapInstall("glibc", installWithBinaries, buildDir, useCacheIfPossible, target)
            of "musl":
                info_msg "Installing musl as libc"
                kreastrapInstall("musl", installWithBinaries, buildDir, useCacheIfPossible, target)
            else:
                error conf.getSectionValue("Core",
                        "Libc")&" is not available as a Libc option."

        # Installation of Core utilities
        case conf.getSectionValue("Core", "Coreutils").normalize():
            of "busybox":
                info_msg "Installing BusyBox as Coreutils"
                kreastrapInstall("busybox", installWithBinaries, buildDir, useCacheIfPossible, target)
            of "gnu":
                info_msg "Installing GNU Coreutils as Coreutils"
                kreastrapInstall("gnu-coreutils", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                # Install pigz and xz-utils because it is needed for kpkg tarballs
                kreastrapInstall("pigz", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("xz-utils", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("bash", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("gsed", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("bzip2", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("patch", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("diffutils", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("findutils", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("util-linux", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("bc", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("cpio", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                kreastrapInstall("which", installWithBinaries,
                        buildDir, useCacheIfPossible, target)

                createSymlink("/bin/bash", buildDir&"/bin/sh")
            else:
                error conf.getSectionValue("Core",
                        "Coreutils")&" is not available as a Coreutils option."

        case conf.getSectionValue("Core", "Init").normalize():
            of "busybox":
                if conf.getSectionValue("Core", "Coreutils").normalize() != "busybox":
                    error "You have to use busybox as coreutils to use it as the init system for now."
                else:
                    info_msg "Init system chosen as busybox init"
            of "jumpstart":
                info_msg "Installing Jumpstart as the init system"
                kreastrapInstall("jumpstart", installWithBinaries, buildDir, useCacheIfPossible, target)
                removeFile(buildDir&"/sbin/init")
                createSymlink("/bin/jumpstart", buildDir&"/sbin/init")
            of "openrc":
                info_msg "Installing OpenRC as the init system"
                kreastrapInstall("openrc", installWithBinaries, buildDir, useCacheIfPossible, target)
                removeFile(buildDir&"/sbin/init")
                createSymlink("/usr/bin/openrc-init", buildDir&"/sbin/init")
            of "systemd":
                info_msg "Installing systemd as the init system"
                kreastrapInstall("systemd", installWithBinaries, buildDir, useCacheIfPossible, target)
                kreastrapInstall("dbus", installWithBinaries, buildDir, useCacheIfPossible, target)
                removeFile(buildDir&"/sbin/init")
                createSymlink("/lib/systemd/systemd", buildDir&"/sbin/init")

        # Install shadow, and enable it
        kreastrapInstall("shadow", installWithBinaries, buildDir, useCacheIfPossible, target)

        let enableShadowedPw = execCmdEx("chroot "&buildDir&" /usr/sbin/pwconv")
        if enableShadowedPw.exitcode != 0:
            debug enableShadowedPw.output
            error "Enabling shadow failed"

        # Install kpkg, p11-kit and make-ca here
        kreastrapInstall("kpkg", installWithBinaries, buildDir, useCacheIfPossible, target)
        kreastrapInstall("p11-kit", installWithBinaries, buildDir, useCacheIfPossible, target)
        kreastrapInstall("make-ca", installWithBinaries, buildDir, useCacheIfPossible, target)

        # Install timezone database
        kreastrapInstall("tzdb", installWithBinaries, buildDir, useCacheIfPossible, target)

        # Generate certdata here
        info_msg "Generating CA certificates"

        setCurrentDir(buildDir)

        download("https://hg.mozilla.org/releases/mozilla-release/raw-file/default/security/nss/lib/ckfw/builtins/certdata.txt", "certdata.txt")

        let caCertCmd = execCmdEx("chroot "&buildDir&" /bin/sh -c '. /etc/profile && cd / && make-ca -C certdata.txt'")

        if caCertCmd.exitcode != 0:
            debug "CA certification generation output: "&caCertCmd.output
            error "Generating CA certificates failed"
        else:
            ok "Generated CA certificates"

        removeFile(buildDir&"/certdata.txt")

        info_msg "Installing Python"
        kreastrapInstall("python", installWithBinaries, buildDir, useCacheIfPossible, target)
        let ensurePip = execCmdEx("chroot "&buildDir&" /bin/sh -c 'python -m ensurepip'")

        if ensurePip.exitcode != 0:
            debug "ensurePip output: "&ensurePip.output
            error "Installing pip failed"
        else:
            ok "Installed pip"

        if conf.getSectionValue("Extras", "ExtraPackages") != "":
            info_msg "Installing extra packages"
            for i in conf.getSectionValue("Extras", "ExtraPackages").split(" "):
                kreastrapInstall(i, installWithBinaries, buildDir, useCacheIfPossible, target)

dispatch kreastrap, help = {
                "buildType": "Specify the build type",
                "arch": "Specify the architecture",
                "useCacheIfPossible": "Use already built packages if possible"
    }
