import unittest
import ../../kpkg/modules/archivemeta

suite "archive-root metadata":
  test "package file list metadata entries are recognized":
    check isArchiveRootMetadata("pkgsums.ini")
    check isArchiveRootMetadata("pkgInfo.ini")

  test "payload and nested entries are never treated as metadata":
    check not isArchiveRootMetadata("usr/bin/ls")
    check not isArchiveRootMetadata("etc/pkgsums.ini")
    check not isArchiveRootMetadata("pkgsums.ini.bak")
    check not isArchiveRootMetadata("")
