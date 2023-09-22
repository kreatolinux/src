import os
import osproc
import ../kpkg/modules/runparser

proc cleanup*(verbose = false, dir = "/var/cache/kpkg/archives/arch/amd64") =
  ## Cleans up outdated packages from the archives.

  if not isAdmin():
    echo "You have to be admin for this action."
    quit(1)

  removeDir("/tmp/chkupd-temp-cleanup")
  createDir("/tmp/chkupd-temp-cleanup")
  setCurrentDir("/tmp/chkupd-temp-cleanup")
  discard execCmdEx("git clone https://github.com/kreatolinux/kpkg-repo")
  setCurrentDir("/tmp/chkupd-temp-cleanup/kpkg-repo")
  var dontDelete: seq[string]

  for i in walkDirs("*"):
    let runf = parse_runfile(i)
    let tname = "kpkg-tarball-"&i&"-"&runf.versionString&".tar.gz"
    if fileExists(dir&"/"&tname):
      dontDelete = dontDelete&tname

  setCurrentDir(dir)

  for i in walkFiles("*.tar.gz"):
    if not (i in dontDelete):
      if verbose:
        echo "Deleting: "&i&"(.sum)"
      removeFile(i&".sum")
      removeFile(i)

  echo "Cleanup complete."
