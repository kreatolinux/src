## Shell-free command execution module for Jumpstart
##
## This module provides direct process execution without relying on /bin/sh.
## Uses Nim's std/cmdline.parseCmdLine for command parsing.

import std/cmdline
import osproc
import os
import strutils

proc execDirect*(cmd: string, options: set[ProcessOption] = {}): Process =
  ## Execute a command without shell interpretation.
  ## Parses the command string and calls startProcess directly.

  if cmd.isEmptyOrWhitespace():
    raise newException(ValueError, "Empty command")

  let parts = parseCmdLine(cmd)
  if parts.len == 0:
    raise newException(ValueError, "Empty command")

  let exe = if '/' in parts[0]: parts[0] else: findExe(parts[0])
  let args = if parts.len > 1: parts[1..^1] else: @[]

  result = startProcess(
    command = exe,
    args = args,
    options = options - {poEvalCommand}
  )

proc execDirectWait*(cmd: string, options: set[ProcessOption] = {}): int =
  ## Execute a command and wait for it to complete.
  ## Returns the exit code.

  if cmd.isEmptyOrWhitespace():
    return 0

  let process = execDirect(cmd, options)
  result = waitForExit(process)
  close(process)
