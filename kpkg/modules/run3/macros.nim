## Macro system for kpkg run3
## Implements build system helpers: extract, package, test, build
## This is kpkg-specific and NOT part of the core Kongue language

import os
import strutils
import ../../../kongue/builtins
import ../../../kongue/utils

const run3NoLibArchive* = defined(run3NoLibArchive)

when not run3NoLibArchive:
    import ../libarchive

type
    BuildSystem* = enum
        bsNone,
        bsMeson,
        bsCMake,
        bsNinja,
        bsMake,
        bsAutotools

proc parseMacroArgs*(args: seq[string]): tuple[buildSystem: BuildSystem,
        autocd: bool, prefix: string, passthroughArgs: string] =
    ## Parse macro arguments
    ## Returns internal options and passthrough args separately
    ## passthroughArgs is a string ready to append to build commands
    result.buildSystem = bsNone
    result.autocd = false
    result.prefix = "/usr"
    var passthrough: seq[string] = @[]

    for arg in args:
        if arg.startsWith("--"):
            let argName = arg[2..^1].split('=')[0]
            let argValue = if '=' in arg: arg.split('=', 1)[1] else: "true"

            case argName
            of "meson":
                result.buildSystem = bsMeson
            of "cmake":
                result.buildSystem = bsCMake
            of "ninja":
                result.buildSystem = bsNinja
            of "make":
                result.buildSystem = bsMake
            of "autotools", "configure":
                result.buildSystem = bsAutotools
            of "autocd":
                result.autocd = isTrueBoolean(argValue)
            of "prefix":
                result.prefix = argValue
            else:
                # Unknown -- flag, pass through to build system
                passthrough.add(arg)
        else:
            # Non -- args (like -Dfoo=bar or positional args), pass through
            passthrough.add(arg)

    result.passthroughArgs = if passthrough.len > 0: passthrough.join(" ") else: ""

proc macroExtract*(ctx: ExecutionContext, args: seq[string]): int =
    ## Extract all archives in the current directory using libarchive
    ## Supports --autocd=true/false
    let macroArgs = parseMacroArgs(args)

    when run3NoLibArchive:
        echo "Error: Extraction support is disabled in this build"
        return 1
    else:
        # Find all archives
        var archives: seq[string] = @[]
        for kind, path in walkDir(ctx.currentDir):
            if kind == pcFile:
                let ext = splitFile(path).ext.toLowerAscii()
                if ext in [".tar", ".gz", ".tgz", ".xz", ".txz", ".bz2",
                        ".tbz2", ".zip"]:
                    archives.add(path)

        # Extract each archive using libarchive
        for archive in archives:
            try:
                discard extract(archive, ctx.currentDir)
            except LibarchiveError as e:
                echo "Error extracting " & archive & ": " & e.msg
                return 1
            except OSError as e:
                echo "Error extracting " & archive & ": " & e.msg
                return 1

        # Auto-cd into extracted directory if there's only one (same behavior as buildcmd.nim)
        if macroArgs.autocd:
            var amountOfDirs: int = 0
            var targetDir: string = ""

            for kind, path in walkDir(ctx.currentDir):
                if kind == pcDir:
                    amountOfDirs = amountOfDirs + 1
                    targetDir = path

            if amountOfDirs == 1:
                discard ctx.builtinCd(targetDir)

proc macroPackage*(ctx: ExecutionContext, args: seq[string]): int =
    ## Run installation commands based on build system
    let macroArgs = parseMacroArgs(args)

    case macroArgs.buildSystem
    of bsMeson:
        return ctx.builtinExec("DESTDIR=" & ctx.destDir & " meson install -C build")

    of bsCMake:
        return ctx.builtinExec("cmake --install build --prefix " &
                macroArgs.prefix)

    of bsNinja:
        return ctx.builtinExec("DESTDIR=" & ctx.destDir & " ninja -C build install")

    of bsMake:
        return ctx.builtinExec("make DESTDIR=" & ctx.destDir & " install")

    of bsAutotools:
        return ctx.builtinExec("make DESTDIR=" & ctx.destDir & " install")

    of bsNone:
        # Try to detect build system
        if fileExists(ctx.currentDir / "build/build.ninja"):
            return ctx.builtinExec("DESTDIR=" & ctx.destDir & " ninja -C build install")
        elif fileExists(ctx.currentDir / "build/Makefile"):
            return ctx.builtinExec("make -C build DESTDIR=" & ctx.destDir & " install")
        elif fileExists(ctx.currentDir / "Makefile"):
            return ctx.builtinExec("make DESTDIR=" & ctx.destDir & " install")
        elif fileExists(ctx.currentDir / "build.ninja"):
            return ctx.builtinExec("DESTDIR=" & ctx.destDir & " ninja install")
        else:
            echo "Error: Could not detect build system"
            return 1

proc macroTest*(ctx: ExecutionContext, args: seq[string]): int =
    ## Run test suite based on build system
    let macroArgs = parseMacroArgs(args)

    case macroArgs.buildSystem
    of bsMeson:
        return ctx.builtinExec("meson test -C build")

    of bsCMake:
        return ctx.builtinExec("ctest --test-dir build")

    of bsNinja:
        return ctx.builtinExec("ninja -C build test")

    of bsMake:
        return ctx.builtinExec("make test")

    of bsAutotools:
        return ctx.builtinExec("make check")

    of bsNone:
        # Try to detect build system
        if fileExists(ctx.currentDir / "build/build.ninja"):
            return ctx.builtinExec("ninja -C build test")
        elif fileExists(ctx.currentDir / "build/Makefile"):
            return ctx.builtinExec("make -C build test")
        elif fileExists(ctx.currentDir / "Makefile"):
            return ctx.builtinExec("make test")
        elif fileExists(ctx.currentDir / "build.ninja"):
            return ctx.builtinExec("ninja test")
        else:
            echo "Error: Could not detect build system"
            return 1

proc macroBuild*(ctx: ExecutionContext, args: seq[string]): int =
    ## Run build commands based on build system
    ## Extra arguments are passed through to the underlying build system
    let macroArgs = parseMacroArgs(args)
    let extraArgs = if macroArgs.passthroughArgs.len > 0: " " &
            macroArgs.passthroughArgs else: ""

    case macroArgs.buildSystem
    of bsMeson:
        result = ctx.builtinExec("meson setup build --prefix=" &
                macroArgs.prefix & " --default-library=both" & extraArgs)
        if result != 0: return result
        return ctx.builtinExec("meson compile -C build")

    of bsCMake:
        result = ctx.builtinExec("cmake -B build -DCMAKE_INSTALL_PREFIX=" &
                macroArgs.prefix & " -DBUILD_SHARED_LIBS=ON" & extraArgs)
        if result != 0: return result
        return ctx.builtinExec("cmake --build build")

    of bsNinja:
        return ctx.builtinExec("ninja -C build" & extraArgs)

    of bsMake:
        return ctx.builtinExec("make" & extraArgs)

    of bsAutotools:
        result = ctx.builtinExec("./configure --prefix=" & macroArgs.prefix & extraArgs)
        if result != 0: return result
        return ctx.builtinExec("make")

    of bsNone:
        # Try to detect build system
        if fileExists(ctx.currentDir / "meson.build"):
            result = ctx.builtinExec("meson setup build --prefix=" &
                    macroArgs.prefix & " --default-library=both" & extraArgs)
            if result != 0: return result
            return ctx.builtinExec("meson compile -C build")
        elif fileExists(ctx.currentDir / "CMakeLists.txt"):
            result = ctx.builtinExec("cmake -B build -DCMAKE_INSTALL_PREFIX=" &
                    macroArgs.prefix & " -DBUILD_SHARED_LIBS=ON" & extraArgs)
            if result != 0: return result
            return ctx.builtinExec("cmake --build build")
        elif fileExists(ctx.currentDir / "configure"):
            result = ctx.builtinExec("./configure --prefix=" &
                    macroArgs.prefix & extraArgs)
            if result != 0: return result
            return ctx.builtinExec("make")
        elif fileExists(ctx.currentDir / "Makefile"):
            return ctx.builtinExec("make" & extraArgs)
        else:
            echo "Error: Could not detect build system"
            return 1

proc executeMacro*(ctx: ExecutionContext, name: string, args: seq[string]): int =
    ## Execute a macro by name
    case name
    of "extract":
        return macroExtract(ctx, args)
    of "package":
        return macroPackage(ctx, args)
    of "test":
        return macroTest(ctx, args)
    of "build":
        return macroBuild(ctx, args)
    else:
        echo "Error: Unknown macro: " & name
        return 1
