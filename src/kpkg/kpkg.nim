# kpkg - Simple, efficient and fast package manager
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
include modules/logger
include modules/config
include build
include update
include remove
include upgrade
include info

clCfg.version = "kpkg v4"

dispatchMulti(
  [
  build, help = {
    "packages": "The package names",
    "root": "The directory the package is gonna be installed to",
    "yes": "Automatically say 'yes' to every question",
    "no": "Automatically say 'no' to every question",
    }
  ],

  [
  install, help = {
    "root": "The directory the package is gonna be installed to",
    "yes": "Automatically say 'yes' to every question",
    "no": "Automatically say 'no' to every question",
    "binrepo": "The kpkg binary mirror",
    "offline": "Offline mode, errors out if tarball is attempted to get downloaded off binrepo",
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
    "repo": "The kpkg repository Git URL",
    "path": "The kpkg repository path",
    "branch": "The kpkg repository branch. Also supports commits."
    }
  ],

  [
  upgrade, help = {
    "root": "The directory the packages are gonna be upgraded on",
    "builddir": "Set a custom build directory",
    "srcdir": "Set a custom source directory"
    }
  ],

  [
  info
  ]
)
