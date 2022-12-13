import std/httpclient

proc install_pkg(repo: string , package: string, root: string, binary=false) =
  ## Installs an package.
  
  if isAdmin() == false:
    err "you have to be root for this action."

  var tarball: string
  
  when declared(epoch):
    tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&"-"&epoch&".tar.gz"
  else:
    tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&".tar.gz"

  if sha256hexdigest(readAll(open(tarball)))&"  "&tarball != readAll(open(tarball&".sum")):
    err("sha256sum doesn't match", false)

  setCurrentDir("/etc/nyaa.tarballs")

  if binary == true:
    parse_runfile(repo&"/"&package&"-bin")
  else:
    parse_runfile(repo&"/"&package)
   
  discard existsOrCreateDir("/etc/nyaa.installed")
  removeDir("/etc/nyaa.installed/"&package)
  copyDir(repo&"/"&package, "/etc/nyaa.installed/"&package)

  writeFile("/etc/nyaa.installed/"&package&"/list_files", execProcess("tar -xvf"&tarball&" -C "&root))
  
proc install(packages: seq[string], root="/", yes=false, no=false, binrepo="mirror.kreato.dev", repo="/etc/nyaa-bin"): string =
  ## Download and install a package through a binary repository
  if packages.len == 0:
    err("please enter a package name", false)
    quit(1)

  if isAdmin() == false:
    err "you have to be root for this action."

  var deps: seq[string]
  var res: string

  for i in packages:
    if not dirExists(repo&"/"&i&"-bin"):
      err("package `"&i&"` does not exist", false)
      quit(1)
    else:
      deps = deduplicate(dephandler(i, repo).split(" "))
      res = res & deps.join(" ") & " " & i


  echo "Packages:"&res

  var output: string

  if yes != true and no != true:
    stdout.write "Do you want to continue? (y/N) "
    output = readLine(stdin)

  if output == "y" or output == "Y" or yes == true:
    for i in packages:
      parse_runfile(repo&"/"&i&"-bin")
      discard existsOrCreateDir("/etc/nyaa.tarballs")
      let tarball = "nyaa-tarball-"&i&"-"&version&"-"&release&".tar.gz"
      let chksum = tarball&".sum"
      setCurrentDir("/etc/nyaa.tarballs")
      echo "Downloading tarball"
      var client = newHttpClient()
      writeFile(tarball, client.getContent("https://"&binrepo&"/"&tarball))
      echo "Downloading tarball checksum"
      writeFile(chksum, client.getContent("https://"&binrepo&"/"&chksum))
      install_pkg(repo, i, root, true)
      return "Installation for "&i&" complete"
  else:
      return "nyaa: exiting"
