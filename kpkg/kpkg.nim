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
import parsecfg
import std/exitprocs
import std/tables
import commands/repl
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
import commands/stalecmd
import commands/historycmd
import modules/config as kpkgConfig
import modules/telemetry/config as telemetryConfig
import modules/telemetry/main as telemetry
import ../common/logging
import ../common/version

# Initialize logging for kpkg
initLogger("kpkg", "/etc/kpkg/kpkg.conf", "/var/log/kpkg.log")

var telemetryCfg = newConfig()
for (key, defaultValue) in [
  ("enabled", "false"), ("endpoint", "localhost:4317"), ("tls", "false"),
  ("timeoutMs", "5000"), ("failurePolicy", "continue"),
  ("authType", "none"), ("username", ""), ("password", ""),
  ("bearerToken", ""), ("buildId", "")
]:
  telemetryCfg.setSectionKey("Telemetry", key,
      kpkgConfig.getConfigValue("Telemetry", key, defaultValue))
telemetry.initializeTelemetry(telemetryConfig.parseTelemetryConfig(telemetryCfg))
let commandName = if paramCount() > 0:
  telemetry.sanitizeCommandName(paramStr(1))
else:
  "unknown"
let commandSpan = telemetry.startSpan("kpkg.command",
    {"kpkg.command": commandName}.toTable)
addExitProc(proc() =
  telemetry.endSpan(commandSpan)
  telemetry.shutdownTelemetry()
)
# fatal() aborts bypass normal span unwinding; report them as failures.
setErrorCallback(telemetry.fatalExitCallback(commandSpan))

if commitVer != "unavailable":
  clCfg.version = "kpkg "&ver&", commit "&commitVer
else:
  clCfg.version = "kpkg "&ver


dispatchMultiGen(["init"], [sandbox, mergeNames = @["kpkg", "init"]], [package,
    mergeNames = @["kpkg", "init"]], #[ insert system here ]#
[override, mergeNames = @["kpkg", "init"]])

dispatchMultiGen(["history", cmdName = "kpkg history"],
  [historyList, cmdName = "list", dispatchName = "dispatchHistoryList",
    mergeNames = @["kpkg", "history", "list"],
    help = {"root": "Installation root",
        "color": "Use terminal colors (respects NO_COLOR)"}],
  [historyStatus, cmdName = "status", dispatchName = "dispatchHistoryStatus",
    mergeNames = @["kpkg", "history", "status"],
    help = {"root": "Installation root (read-only inspection)"}],
  [historyRecover, cmdName = "recover", dispatchName = "dispatchHistoryRecover",
    mergeNames = @["kpkg", "history", "recover"],
    help = {"root": "Installation root",
        "yes": "Recover without confirmation"}],
  [historyInfo, cmdName = "info", dispatchName = "dispatchHistoryInfo",
    mergeNames = @["kpkg", "history", "info"],
    help = {"id": "Transaction boundary ID", "root": "Installation root",
      "color": "Use terminal colors (respects NO_COLOR)"}],
  [historyUndo, cmdName = "undo", dispatchName = "dispatchHistoryUndo",
    mergeNames = @["kpkg", "history", "undo"],
    help = {"id": "Transaction boundary ID", "root": "Installation root",
      "yes": "Restore without confirmation",
      "color": "Use terminal colors (respects NO_COLOR)"}],
  [historyRollback, cmdName = "rollback",
    dispatchName = "dispatchHistoryRollback",
    mergeNames = @["kpkg", "history", "rollback"],
    help = {"id": "Transaction boundary ID", "root": "Installation root",
      "yes": "Restore without confirmation",
      "color": "Use terminal colors (respects NO_COLOR)"}])

dispatchMulti(
  [
  build, doc = "Build and install packages.", help = {
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
    "deferPostInstall": "Repair only: skip postinstall hooks and sandbox CA setup. Rebuild normally after repair; reinstall affected packages to run skipped hooks.",
    "bootstrap": "Perform bootstrap build",
    "noSandbox": "Build directly in root without the bwrap/overlay sandbox (for chroot/seed builds)"
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
    "ignoreDownloadErrors": "Ignore errors that may occur while downloading packages",
    "exclude": "Additional packages to exclude (comma-separated patterns)",
    "disableExcludes": "Disable all exclude patterns for this transaction"
    },
    suppress = @["isUpgrade", "basePackage"]
  ],

  [
  search, help = {
    "colors": "Enable color output",
    "showExcluded": "Show excluded packages in results"
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
    "srcdir": "Set a custom source directory",
    "exclude": "Additional packages to exclude (comma-separated patterns)",
    "disableExcludes": "Disable all exclude patterns for this transaction"
    }
  ],

  [
  clean, help = {
    "packages": "Package name(s) to clean cache for (if not specified, cleans all)",
    "sources": "Remove source tarballs from cache",
    "binaries": "Remove binary tarballs from cache",
    "cache": "Remove ccache directory",
    "environment": "Remove build environment directory",
    "transactions": "Remove history and backups older than DAYS (0: all, -1: disabled)",
    "root": "Installation root whose transaction history to clean",
    "yes": "Clean transactions without confirmation",
    "clearLock": "Clear a stale lock and recover interrupted repository checkouts"
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
  list, help = {
    "installed": "List only installed packages",
    "color": "Enable color output",
    "showExcluded": "Show excluded packages"
  }
  ],
  [
  init, doc = "Initialize multiple types of files", usage = "$doc\n",
  stopWords = @["sandbox", "package", "override", "hook"]
  ],
  [
  history, doc = "Inspect and restore package transactions",
  usage = """kpkg history <command> [options]

$doc

Commands:
  list      List recorded transactions, newest first
  status    Inspect interrupted history operations without changing files
  recover   Recover interrupted history operations under the package lock
  info      Show a transaction's action, packages, and state
  undo      Revert the selected transaction and everything after it
  rollback  Revert everything after the selected transaction; keep it

Run kpkg history <command> --help for arguments and options.
""",
    stopWords = @["list", "info", "undo", "rollback", "status", "recover"]
  ],
  [
  stale, help = {}
  ],
  [
  repl.repl, help = {
    "args": "Command to execute (e.g. 'set config.Upgrade.buildByDefault no')"
  }
  ]
)
