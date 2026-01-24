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

import os
import strutils
import strformat
import tables
import sequtils
import algorithm
import terminal
import ../../common/logging

type
  StaleProcess* = object
    pid*: string
    name*: string
    exe*: string
    user*: string
    uptime*: string

proc getProcessUser(pid: string): string =
  ## Get the username of the process owner
  try:
    let statusPath = "/proc" / pid / "status"
    if fileExists(statusPath):
      let content = readFile(statusPath)
      for line in content.splitLines():
        if line.startsWith("Uid:"):
          let uid = line.split()[1]
          # Try to resolve UID to username
          try:
            let passwdContent = readFile("/etc/passwd")
            for passwdLine in passwdContent.splitLines():
              let parts = passwdLine.split(':')
              if parts.len >= 3 and parts[2] == uid:
                return parts[0]
          except:
            discard
          return uid
  except:
    discard
  return "unknown"

proc getProcessUptime(pid: string): string =
  ## Get process uptime in human-readable format
  try:
    let statPath = "/proc" / pid / "stat"
    if fileExists(statPath):
      let content = readFile(statPath)
      let parts = content.split(')')
      if parts.len >= 2:
        let fields = parts[1].strip().split()
        if fields.len >= 20:
          let starttime = parseInt(fields[19])
          let uptimePath = "/proc/uptime"
          if fileExists(uptimePath):
            let uptimeContent = readFile(uptimePath).split()[0]
            let systemUptime = parseFloat(uptimeContent)
            let hertz = 100.0 # CONFIG_HZ, typically 100
            let processUptime = systemUptime - (float(starttime) / hertz)

            let uptimeInt = int(processUptime)
            let days = uptimeInt div 86400
            let hours = (uptimeInt mod 86400) div 3600
            let minutes = (uptimeInt mod 3600) div 60

            if days > 0:
              return fmt"{days}d {hours}h"
            elif hours > 0:
              return fmt"{hours}h {minutes}m"
            else:
              return fmt"{minutes}m"
  except:
    discard
  return "unknown"

proc getStaleProcesses*(): seq[StaleProcess] =
  ## Scans /proc for processes running with deleted executables.
  ## Returns a list of StaleProcess objects.
  result = @[]

  if not dirExists("/proc"):
    return result

  for entry in walkDir("/proc"):
    let pidDir = entry.path
    let pidName = lastPathPart(pidDir)

    # Skip non-numeric entries (not PIDs)
    if pidName.len == 0 or not pidName[0].isDigit():
      continue

    let exePath = pidDir / "exe"

    if not symlinkExists(exePath):
      continue

    try:
      let target = expandSymlink(exePath)
      # On Linux, deleted executables show as "/path/to/binary (deleted)"
      if target.endsWith(" (deleted)"):
        let commPath = pidDir / "comm"
        var name = pidName
        if fileExists(commPath):
          try:
            name = readFile(commPath).strip()
          except IOError:
            discard

        result.add(StaleProcess(
          pid: pidName,
          name: name,
          exe: target.replace(" (deleted)", ""),
          user: getProcessUser(pidName),
          uptime: getProcessUptime(pidName)
        ))
    except OSError:
      # Permission denied or process exited, skip
      continue

proc printStaleWarning*() =
  ## Prints a warning if there are stale processes running.
  let stale = getStaleProcesses()

  if stale.len == 0:
    return

  warn "The following processes are running with outdated binaries:"

  for p in stale:
    info "  " & p.name & " (PID: " & p.pid & ")"
  info "Consider restarting these processes or rebooting the system."

proc stale*() =
  ## Standalone command to check for stale processes.
  let staleProcs = getStaleProcesses()

  if staleProcs.len == 0:
    info "No processes are running with outdated binaries."
    return

  # Group processes by executable
  var grouped = initTable[string, seq[StaleProcess]]()
  for p in staleProcs:
    let exeName = p.exe.splitPath().tail
    if not grouped.hasKey(exeName):
      grouped[exeName] = @[]
    grouped[exeName].add(p)

  # Sort by executable name
  var sortedKeys = toSeq(grouped.keys)
  sortedKeys.sort()

  for exeName in sortedKeys:
    let procs = grouped[exeName]

    # Print header for the executable group
    if stdout.isatty():
      stdout.styledWrite(styleBright, fgCyan, exeName, resetStyle,
                        " (", $procs.len, " instance",
                        (if procs.len > 1: "s" else: ""), ")", "\n")
    else:
      echo exeName & " (" & $procs.len & " instance" & (if procs.len >
          1: "s" else: "") & ")"

    # Print each process in the group
    for p in procs:
      if stdout.isatty():
        stdout.styledWrite("  ", fgYellow, p.pid.alignLeft(8), resetStyle,
                          fgGreen, p.user.alignLeft(12), resetStyle,
                          p.name, "\n")
      else:
        echo "  " & p.pid.alignLeft(8) & p.user.alignLeft(12) & p.name

    echo "" # Empty line between groups
