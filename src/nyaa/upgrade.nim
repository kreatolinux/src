include modules/removeInternal

proc upgrade(root = "/",
        builddir = "/tmp/nyaa_build", srcdir = "/tmp/nyaa_srcdir"): string =
    ## Upgrade packages
    var repo: string
    for i in walkDir("/etc/nyaa.installed"):
        if i.kind == pcDir:
            try:
                parse_runfile(i.path)
            except Exception:
                err("package on "&i.path&" doesn't have a runfile, possibly broken package", false)

            let pkg = lastPathPart(i.path)

            let version_local = version
            let release_local = release
            when declared(epoch):
                let epoch_local = epoch

            repo = findPkgRepo(pkg)
            if isEmptyOrWhitespace(repo):
                echo "skipping "&pkg&": not found in available repositories"
                continue

            parse_runfile(repo&"/"&pkg)

            let version_upstream = version
            let release_upstream = release

            if version_local < version_upstream or release_local <
              release_upstream:
                when declared(epoch):
                    let epoch_upstream = epoch
                    if epoch_local < epoch_upstream:
                        echo "Upgrading "&pkg&" from "&version_local&"-"&release_local&"-"&epoch_local&" to "&version_upstream&"-"&release_upstream&"-"&epoch_upstream
                    else:
                        echo "Upgrading "&pkg&" from "&version_local&"-"&release_local&" to "&version_upstream&"-"&release_upstream

                    discard removeInternal(pkg, root)
                    if getConfigValue("Upgrade", "buildByDefault") == "yes":
                        builder(pkg, root)
                    else:
                        discard install(@[pkg], root, true)

    return "nyaa: done"
