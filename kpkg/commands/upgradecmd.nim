import os
import strutils
import buildcmd
import installcmd
import ../modules/config
import ../modules/logger
import ../modules/lockfile
import ../modules/runparser
import ../modules/processes

proc upgrade*(root = "/",
        builddir = "/tmp/kpkg/build", srcdir = "/tmp/kpkg/srcdir", yes = false,
                no = false) =
    ## Upgrade packages
    
    isKpkgRunning()
    checkLockfile()
    
    var packages: seq[string]
    var repo: string
    
    for i in walkDir("/var/cache/kpkg/installed"):
        if i.kind == pcDir:
            var localPkg: runFile
            try:
                localPkg = parse_runfile(i.path)
            except CatchableError:
                err("Unknown error while reading installed package")

            var isAReplacesPackage: bool

            for r in localPkg.replaces:
                if r == lastPathPart(i.path):
                    isAReplacesPackage = true

            if isAReplacesPackage:
                continue

            if localPkg.pkg in getConfigValue("Upgrade", "dontUpgrade").split(" "):
                info "skipping "&localPkg.pkg&": selected to not upgrade in kpkg.conf"
                continue

            when declared(localPkg.epoch):
                let epoch_local = epoch

            repo = findPkgRepo(lastPathPart(i.path))
            if isEmptyOrWhitespace(repo):
                warn "skipping "&localPkg.pkg&": not found in available repositories"
                continue

            var upstreamPkg: runFile
            try:
                upstreamPkg = parse_runfile(repo&"/"&lastPathpart(i.path))
            except CatchableError:
                err("Unknown error while reading package on repository, possibly broken repo?")

            if localPkg.version < upstreamPkg.version or localPkg.release <
              upstreamPkg.release or (localPkg.epoch != "no" and
                      localPkg.epoch < upstreamPkg.epoch):
                packages = packages&lastPathpart(i.path)

    if packages.len == 0 and isEmptyOrWhitespace(packages.join("")):
        success("done", true)

    if parseBool(getConfigValue("Upgrade", "buildByDefault")):
        discard build(yes = yes, no = no, packages = packages, root = root)
    else:
        discard install(packages, root, yes = yes, no = no)

    success("done", true)
