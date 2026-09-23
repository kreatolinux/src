import unittest

when not defined(kpkgInstallChannelTest):
  {.fatal: "compile with -d:kpkgInstallChannelTest".}

import ../../../kpkg/commands/installcmd

suite "install channel lifecycle":
  test "fresh channel state survives repeated installer batches":
    ## This calls the installcmd probe, rather than duplicating Channel setup.
    ## The probe exercises both work and result queues and closes each batch.
    check probeInstallChannelLifecycle(8)

  test "unwind cleanup stops workers and drains queued payloads":
    ## Simulates coordinator failure after work is queued. Cleanup sends one
    ## sentinel per worker, joins them, drains both queues, then closes them.
    check probeInstallChannelUnwind()

