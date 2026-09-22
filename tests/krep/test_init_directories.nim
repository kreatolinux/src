import unittest
import os
import ../../krep/modules/commonProcs

suite "kreastrap initDirectories permissions":
  test "sets write permissions on critical rootfs directories":
    let tmp = getTempDir() / "kreastrap_init_test"
    removeDir(tmp)
    try:
      initDirectories(tmp, "x86_64", silent = true)

      # Root directory /
      check fpUserWrite in getFilePermissions(tmp)

      # /usr/bin and /usr/lib
      check fpUserWrite in getFilePermissions(tmp / "usr/bin")
      check fpUserWrite in getFilePermissions(tmp / "usr/lib")

      # /boot and /root
      check fpUserWrite in getFilePermissions(tmp / "boot")
      check fpUserWrite in getFilePermissions(tmp / "root")

      # Verify creating a directory inside /usr/lib (e.g. glibc postinstall) succeeds
      createDir(tmp / "usr/lib/locale")
      check dirExists(tmp / "usr/lib/locale")
    finally:
      removeDir(tmp)
