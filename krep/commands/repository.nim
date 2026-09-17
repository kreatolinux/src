## Repository maintenance commands with explicit read-only/update modes.
import std/os
import ./checkcmd as upstream
import ./cleancmd as archives

proc check*(package: string, repo: string, backend = "repology",
    verbose = false) =
  ## Check upstream versions without updating package files.
  upstream.check(package, absolutePath(repo), backend, autoUpdate = false,
          verbose = verbose)

proc update*(package: string, repo: string, backend = "repology",
        skipIfDownloadFails = false, verbose = false) =
  ## Update package versions and checksums when an upstream update is found.
  upstream.check(package, absolutePath(repo), backend, autoUpdate = true,
          skipIfDownloadFails = skipIfDownloadFails, verbose = verbose)

proc clean*(verbose = false, dir = "/var/cache/kpkg/archives/arch/amd64") =
  ## Remove outdated package archives (requires root).
  archives.cleanup(verbose, absolutePath(dir))
