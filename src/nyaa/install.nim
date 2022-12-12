proc install_pkg(repo: string , package: string, root: string): string =
  ## Installs an package.
  setCurrentDir("/etc/nyaa.tarballs")
  discard parse_runfile(repo&"/"&package)
    
  discard existsOrCreateDir("/etc/nyaa.installed")
  removeDir("/etc/nyaa.installed/"&package)
  copyDir(repo&"/"&package, "/etc/nyaa.installed/"&package)

  when declared(epoch):
    writeFile("/etc/nyaa.installed/"&package&"/list_files", execProcess("tar -xvf /etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&"-"&epoch&".tar.gz -C "&root))
  else:
    writeFile("/etc/nyaa.installed/"&package&"/list_files", execProcess("tar -xvf /etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&".tar.gz -C "&root))
  
proc install(packages: seq[string], root="/"): string =
  ## Fast and efficient package manager
  echo packages
