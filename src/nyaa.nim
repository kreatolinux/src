# nyaa3 - Simple, efficient and fast package manager
# Copyright 2022 Kreato
#
# This file is part of Kreato Linux.
#
# Kreato Linux is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Kreato Linux is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Kreato Linux.  If not, see <https://www.gnu.org/licenses/>.
import cligen
import sequtils
import parsecfg
import os
include nyaa/modules/logger
include nyaa/modules/config
include nyaa/build
include nyaa/update
include nyaa/upgrade
include nyaa/remove
include nyaa/info

clCfg.version = "nyaa v3.0.3"


if not fileExists("/etc/nyaa.conf"):
  initializeConfig()

dispatchMulti(
  [
  build, help = {
    "packages": "The package names",
    "root": "The directory the package is gonna be installed to",
    "yes": "Automatically say 'yes' to every question",
    "no": "Automatically say 'no' to every question"
    }
  ],

  [
  install, help = {
    "root": "The directory the package is gonna be installed to",
    "yes": "Automatically say 'yes' to every question",
    "no": "Automatically say 'no' to every question",
    "binrepo": "The nyaa binary mirror",
    }
  ],

  [
  info, help = {
    "repo": "Set nyaa repository"
    }
  ],

  [
  remove, help = {
    "yes": "Automatically say 'yes' to every question",
    "root": "The directory the package is gonna be removed from"
    }
  ],

  [
  update, help = {
    "repo": "The nyaa repository Git URL",
    "path": "The nyaa repository path"
    }
  ],

  [
  upgrade, help = {
    "root": "The directory the packages are gonna be upgraded on",
    "builddir": "Set a custom build directory",
    "srcdir": "Set a custom source directory"
    }
  ]
)
