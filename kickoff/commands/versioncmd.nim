## `kickoff version` — print the version and exit.
##
## Present so the CLI has the same shape as krep's multi-command one, and because
## cligen's dispatchMulti needs more than one command.

import ../../common/version

proc versionCommand*() =
  ## Print the kickoff version.
  echo "kickoff " & ver & ", commit " & commitVer
