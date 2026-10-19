# Package
version       = "2.2.0"
author        = "Kreato Linux"
description   = "Reusable library for Jumpstart cores: exec protocol, operation registry, error codes, process spawn, cgroups, reaper"
license       = "LGPL-3.0-or-later"
srcDir        = "src"

# Source-only library: no binaries, no dependencies beyond Nim's standard library.
requires "nim >= 2.2.0"

task test, "Run the jumpstartcore tests (from a Kreato Linux source checkout)":
  exec "sh ../../build.sh -T jumpstartcore"
