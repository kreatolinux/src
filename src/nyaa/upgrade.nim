proc upgrade(repo = "/etc/nyaa", packages = "all", destdir = "/",
        root = "/tmp/nyaa_build", srcdir = "/tmp/nyaa_srcdir"): string =
    ## Upgrade packages
    if packages == "all":
        for i in walkDir("/etc/nyaa.installed"):
            if i.kind == pcDir:
                let epoch = ""
                try:
                    parse_runfile(i.path)
                except Exception:
                    err("package on "&i.path&" doesn't have a runfile, possibly broken package", false)

                let version_local = version
                let release_local = release
                when declared(epoch):
                    let epoch_local = epoch

                parse_runfile(repo&"/"&lastPathPart(i.path))

                let version_upstream = version
                let release_upstream = release

                if version_local < version_upstream or release_local <
                        release_upstream or isEmptyOrWhitespace(epoch) == false:
                    when declared(epoch):
                        let epoch_upstream = epoch
                        if epoch_local < epoch_upstream:
                            echo "Upgrading "&lastPathPart(
                                i.path)&" from "&version_local&"-"&release_local&"-"&epoch_local&" to "&version_upstream&"-"&release_upstream&"-"&epoch_upstream
                    else:
                        echo "Upgrading "&lastPathPart(
                            i.path)&" from "&version_local&"-"&release_local&" to "&version_upstream&"-"&release_upstream


                    discard builder(repo, repo&"/"&lastPathPart(i.path), destdir)

    return "done"
