proc info(repo="/etc/nyaa", package: seq[string]): string = 
  ## Get information about packages
  discard parse_runfile(repo&"/"&package[0])
  echo "package name: "&pkg
  echo "package version: "&version
  echo "package release: "&release
  when declared(epoch):
    echo "package epoch: "&epoch
  if dirExists("/etc/nyaa.installed/"&package[0]):
    return "installed: yes"
  else:
    return "installed: no"

