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
import os
import commands/getsetcmd
import commands/infocmd as infocmdModule
import commands/buildcmd
import commands/updatecmd
import commands/removecmd
import commands/upgradecmd
import commands/installcmd
import commands/searchcmd
import commands/cleancmd
import commands/auditcmd
import commands/providescmd
import commands/checkcmd
import commands/listcmd
import commands/initcmd
import commands/clearlockcmd
import commands/stalecmd
import modules/transaction
import ../common/logging
import ../common/version

# Initialize logging for kpkg
initLogger("kpkg", "/etc/kpkg/kpkg.conf", "/var/log/kpkg.log")

# Check for and recover from any incomplete transactions from previous runs
# This must happen early, before any other operations
if isAdmin():
  if recoverFromCrash():
    info "Recovered from incomplete transaction(s)"
  # Clean up old transaction journals periodically
  cleanupOldTransactions(7)

if commitVer != "unavailable":
  clCfg.version = "kpkg "&ver&", commit "&commitVer
else:
  clCfg.version = "kpkg "&ver


dispatchMultiGen(["init"], [sandbox, mergeNames = @["kpkg", "init"]], [package,
    mergeNames = @["kpkg", "init"]], #[ insert system here ]#
[override, mergeNames = @["kpkg", "init"]])

dispatchMulti(
  [
  build, help = {
    "packages": "The package names",
    "root": "The directory the package is gonna be installed to",
    "yes": "Automatically say 'yes' to every question",
    "no": "Automatically say 'no' to every question",
    "useCacheIfAvailable": "Uses cached build (if available)",
    "dontInstall": "Only build, don't install",
    "tests": "Enable/Disable Tests on packages",
    "forceInstallAll": "Force reinstall every dependency",
    "isInstallDir": "Build package from specified path",
    "ignorePostInstall": "Ignore if postInstall fails",
    "bootstrap": "Perform bootstrap build"
  },
    suppress = @["isUpgrade"] # Internal variable for commands/upgradecmd
  ],

  [
  install, help = {
    "root": "The directory the package is gonna be installed to",
    "yes": "Automatically say 'yes' to every question",
    "no": "Automatically say 'no' to every question",
    "offline": "Offline mode, errors out if tarball is attempted to get downloaded off binrepo",
    "downloadOnly": "Only download the binary, don't install",
    "ignoreDownloadErrors": "Ignore errors that may occur while downloading packages"
    },
    suppress = @["isUpgrade", "basePackage"] # Internal variable for commands/upgradecmd, Internal variable of kreastrap
  ],

  [
  search, help = {
    "colors": "Enable color output"
  }
  ],

  [
  remove, help = {
    "yes": "Automatically say 'yes' to every question",
    "root": "The directory the package is gonna be removed from",
    "force": "Ignore dependency checks",
    "autoRemove": "Remove unused dependencies",
    "configRemove": "Remove configuration"
    }
  ],

  [
  provides, help = {
    "files": "Files to search",
    "color": "Enable color output "
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
    "yes": "Automatically say 'yes' to every question",
    "no": "Automatically say 'no' to every question",
    "srcdir": "Set a custom source directory"
    }
  ],

  [
  clean, help = {
    "packages": "Package name(s) to clean cache for (if not specified, cleans all)",
    "sources": "Remove source tarballs from cache",
    "binaries": "Remove binary tarballs from cache",
    "cache": "Remove ccache directory",
    "environment": "Remove build environment directory"
  }
  ],

  [
  audit, help = {
    "description": "Show descriptions of CVEs",
    "fetch": "Fetch and build/install the vulnerability database",
    "fetchBinary": "Fetch already-built SQLite database"
    }
  ],

  [
  infocmdModule.info, help = {
  "testing": "Don't error if package isn't installed"
  }
  ],
  [
  check, help = {
    "root": "The directory the packages are gonna be checked on",
    "package": "Set a specific package to check"
  }
  ],
  [
  list
  ],
  [
  clearLock, doc = "Force clear the kpkg lockfile if it's stale"
  ],
  [
  init, doc = "Initialize multiple types of files", usage = "$doc\n",
  stopWords = @["sandbox", "package", "override", "hook"]
  ],
  [
  get, help = {
    "invocations": "The invocation(s) to read"
    }
  ],
  [
  getsetcmd.set, help = {
    "invocation": "The invocation to write",
    "file": "URL/Path to the file with invocations",
    "append": "Append to the value instead of replacing it"
    }
  ],
  [
  stale, help = {}
  ]
)
