proc install_pkg(repo: string , package: string, root: string) =
  ## Installs an package.
  setCurrentDir("/etc/nyaa.tarballs")
  parse_runfile(repo&"/"&package)
    
  discard existsOrCreateDir("/etc/nyaa.installed")
  removeDir("/etc/nyaa.installed/"&package)
  copyDir(repo&"/"&package, "/etc/nyaa.installed/"&package)

  # TODO: check for sha256sum before proceeding

  when declared(epoch):
    writeFile("/etc/nyaa.installed/"&package&"/list_files", execProcess("tar -xvf /etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&"-"&epoch&".tar.gz -C "&root))
  else:
    writeFile("/etc/nyaa.installed/"&package&"/list_files", execProcess("tar -xvf /etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&".tar.gz -C "&root))
  
proc install(packages: seq[string], root="/", yes=false, no=false, binrepo="mirror.kreato.dev", repo="/etc/nyaa-bin"): string =
  ## Fast and efficient package manager
  if packages.len == 0:
    echo "error: please enter a package name"
    quit(1)

  var deps: seq[string]
  var res: string

  for i in packages:
    if not dirExists(repo&"/"&i&"-bin"):
      echo "error: package `"&i&"` does not exist"
      quit(1)
    else:
      deps = deduplicate(dephandler(i, repo).split(" "))
      res = res & deps.join(" ") & " " & i


  echo "Packages:"&res

  if yes != true and no != true:
    stdout.write "Do you want to continue? (y/N) "
    var output = readLine(stdin)

    if output == "y" or output == "Y" or yes == true:
      for i in packages:
        parse_runfile(repo&"/"&i&"-bin")
        discard existsOrCreateDir("/etc/nyaa.tarballs")
        let tarball = "nyaa-tarball-"&i&"-"&version&"-"&release&".tar.gz"
        let chksum = tarball&".sum"
        setCurrentDir("/etc/nyaa.tarballs")
        echo "https://"&binrepo&"/"&tarball
        writeFile(tarball, fetch("https://"&binrepo&"/"&tarball))
        writeFile(chksum, fetch("https://"&binrepo&"/"&chksum))

        install_pkg(repo, i&"-bin", root)
        echo "Installation for "&i&" complete"
    else:
      return "nyaa: exiting"
