import os
import buildcmd
import installcmd
import strutils
import ../modules/config
import ../modules/logger
import ../modules/runparser

proc upgrade*(root = "/",
        builddir = "/tmp/kpkg/build", srcdir = "/tmp/kpkg/srcdir", yes = false,
                no = false) =
    ## Upgrade packages

    var packages: seq[string]
    var repo: string

    for i in walkDir("/var/cache/kpkg/installed"):
        if i.kind == pcDir:
            var localPkg: runFile
            try:
                localPkg = parse_runfile(i.path)
            except CatchableError:
                err("Unknown error while reading installed package", false)

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
                err("Unknown error while reading package on repository, possibly broken repo?", false)

            if localPkg.version < upstreamPkg.version or localPkg.release <
              upstreamPkg.release or (localPkg.epoch != "no" and
                      localPkg.epoch < upstreamPkg.epoch):
                packages = packages&lastPathpart(i.path)

    if packages.len == 0 and isEmptyOrWhitespace(packages.join("")):
        success("done", true)

    if getConfigValue("Upgrade", "buildByDefault") == "yes":
        discard build(yes = yes, no = no, packages = packages, root = root)
    else:
        discard install(packages, root, yes = yes, no = no)

    success("done", true)
