import unittest
import ../../kreastrap/package_sets

suite "kreastrap package sets":
  test "CA generation prerequisites include update-ca-trust provider":
    check caCertificatePackages() == @[
      "kpkg",
      "p11-kit",
      "ca-certificates-utils",
      "ca-certificates",
      "tzdb"
    ]
