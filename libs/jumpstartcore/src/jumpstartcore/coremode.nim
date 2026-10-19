## The operating mode of a Jumpstart daemon and its cores (jumpstart-cores §7).
##
## Kept in its own module so that code which only needs to name the mode, such
## as the environment builder, does not depend on the daemon's path and socket
## helpers in `jumpstart/cores/manifest/modes.nim`, which re-exports this type.
type
  CoreMode* = enum
    cmSystem, cmUser
