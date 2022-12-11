include ../dephandler

proc build(repo="/etc/nyaa", packages: seq[string]): int =
  ## Build and install packages
  var deps: seq[string]
  var res: string
  for i in packages:
    deps = deduplicate(dephandler(i, repo).split(" "))
    res = res & deps.join(" ") & " " & i
  echo res
  result = 0
