## Inspect persistent package transactions and restore recorded package state.
import std/[os, strutils, times, terminal]
import ../modules/colors
import ../modules/transactions/history as historyStore
import ../modules/transactions/main
import ../modules/lockfile
import ../modules/processes
import ../../common/logging

const
  historyMuted = "\e[2m"
  historyBold = "\e[1m"
  historyGreen = "\e[0;32m"
  historyYellow = "\e[0;33m"
  historyRed = "\e[0;31m"

proc actionColor(action: string): string =
  case action
  of "install", "upgrade": historyGreen
  of "remove", "downgrade": historyRed
  of "reinstall": cyanColor
  else: historyYellow

proc stateColor(state: string): string =
  if state == "committed": historyGreen
  elif state == "undone": historyMuted
  else: historyYellow

proc historyTable*(entries: seq[HistoryEntry], color = false): seq[string] =
  ## Use the same column widths for headings and values, including long IDs.
  var idWidth = "ID".len
  var stateWidth = "STATE".len
  var actionWidth = "ACTION".len
  for entry in entries:
    idWidth = max(idWidth, entry.id.len)
    stateWidth = max(stateWidth, entry.state.len)
    actionWidth = max(actionWidth, entry.action.len)
  const dateWidth = 23 # yyyy-MM-dd HH:mm:ss UTC
  result.add(colorize(alignLeft("ID", idWidth) & "  " & alignLeft("DATE", dateWidth) &
      "  " & alignLeft("STATE", stateWidth) & "  " & alignLeft("ACTION", actionWidth) & "  PACKAGES", historyBold, color))
  for i in countdown(entries.high, 0):
    let entry = entries[i]
    let date = fromUnix(int64(entry.timestamp)).utc.format("yyyy-MM-dd HH:mm:ss") & " UTC"
    result.add(cyan(alignLeft(entry.id, idWidth), color) & "  " &
        colorize(alignLeft(date, dateWidth), historyMuted, color) & "  " &
        colorize(alignLeft(entry.state, stateWidth), stateColor(entry.state), color) & "  " &
        colorize(alignLeft(entry.action, actionWidth), actionColor(entry.action), color) & "  " &
        blue(entry.packages.join(" "), color))

proc showEntry(entry: HistoryEntry, color: bool) =
  echo cyan(entry.id, color)
  echo "  " & colorize("Date      ", historyMuted, color) &
      fromUnix(int64(entry.timestamp)).utc.format("yyyy-MM-dd HH:mm:ss") & " UTC"
  echo "  " & colorize("Packages  ", historyMuted, color) & blue(entry.packages.join(" "), color)
  echo "  " & colorize("Action    ", historyMuted, color) & colorize(entry.action, actionColor(entry.action), color)
  echo "  " & colorize("State     ", historyMuted, color) & colorize(entry.state, stateColor(entry.state), color)
  if entry.state == "undone":
    echo "  " & colorize("Undo      Already undone", historyMuted, color)
  elif entry.rollbackReason.len > 0:
    echo "  " & colorize("Undo      Unavailable: " & entry.rollbackReason, historyYellow, color)
  else:
    let effect = case entry.action
      of "install": "Remove the newly installed packages"
      of "remove": "Restore the removed packages"
      of "reinstall": "Restore the previous installation (packages remain installed)"
      of "upgrade", "downgrade": "Restore the previous package versions"
      else: "Restore the previous package state"
    echo "  " & colorize("Undo      ", historyMuted, color) & effect
    echo "            " & colorize("Subject to file and database checks", historyMuted, color)

proc runHistory(args: seq[string], root = "/", yes = false, color = true) =
  ## List transactions, inspect an ID, or restore package state.
  ## rollback ID keeps ID and reverts newer entries. undo ID also reverts ID.
  let useColor = color and stdout.isatty() and not existsEnv("NO_COLOR") and getEnv("TERM") != "dumb"
  let historyRoot = normalizedPath(absolutePath(if root.len == 0: "/" else: root))
  let action = if args.len == 0: "list" else: args[0]
  if action notin ["list", "info", "undo", "rollback"] or
      (action == "list" and args.len > 1) or
      (action != "list" and args.len != 2):
    fatal("usage: kpkg history [list | info ID | undo ID | rollback ID] [--root=PATH] [--yes]")
  try:
    if action in ["undo", "rollback"] and hasHistoryRestore():
      if not isAdmin(): fatal("you have to be root for this action.")
      checkLockfile()
      createLockfile() # Completes durable recovery before reading the chain.
      removeLockfile()
      clearErrorCallback()
    let entries = listHistory(historyRoot)
    if action == "list":
      if entries.len == 0:
        echo "No package history recorded for " & historyRoot
      else:
        echo colorize("Package history", historyBold, useColor) & "  " &
            colorize(historyRoot & " | " & $entries.len & " transactions | newest first", historyMuted, useColor)
        echo ""
        for line in historyTable(entries, useColor): echo line
      return
    let id = args[1]
    var target = -1
    for i, entry in entries:
      if entry.id == id: target = i
    if target < 0:
      raise newException(ValueError, "unknown history boundary ID: " & id)
    if action == "info":
      showEntry(entries[target], useColor)
      return
    if not isAdmin():
      fatal("you have to be root for this action.")
    isKpkgRunning()
    checkLockfile()
    if entries[target].state != "committed":
      raise newException(ValueError, "target is no longer on the active history chain")
    var count = 0
    echo colorize("Transactions to undo (newest first)", historyBold, useColor)
    echo ""
    for i in countdown(entries.high, target + (if action == "undo": 0 else: 1)):
      if entries[i].state == "committed":
        showEntry(entries[i], useColor)
        echo ""
        inc count
    if count == 0:
      echo "Nothing to undo."
      return
    if not yes:
      stdout.write "Restore these package files and database records? (y/N) "
      if stdin.readLine().strip().toLowerAscii() notin ["y", "yes"]:
        echo "Cancelled."
        return
    # Check again after the interactive prompt.
    checkLockfile()
    createLockfile()
    try:
      if action == "undo": undoHistory(id, historyRoot)
      else: rollbackHistory(id, historyRoot)
    finally:
      removeLockfile()
      clearErrorCallback()
    echo "Package history restored."
  except CatchableError as e:
    fatal("history: " & e.msg)

proc historyList*(root = "/", color = true) =
  ## List recorded package transactions, newest first.
  runHistory(@["list"], root = root, color = color)

proc historyInfo*(id: seq[string], root = "/", color = true) =
  ## Show a transaction's action, packages, state, and undo availability.
  runHistory(@["info"] & id, root = root, color = color)

proc historyUndo*(id: seq[string], root = "/", yes = false, color = true) =
  ## Revert the selected transaction and everything after it.
  runHistory(@["undo"] & id, root = root, yes = yes, color = color)

proc historyRollback*(id: seq[string], root = "/", yes = false, color = true) =
  ## Revert everything after the selected transaction; keep it.
  runHistory(@["rollback"] & id, root = root, yes = yes, color = color)

proc historyStatus*(root = "/") =
  ## Inspect interrupted history work without taking a mutation lock.
  let historyRoot = normalizedPath(absolutePath(if root.len == 0: "/" else: root))
  try:
    let pending = inspectPendingHistory(historyRoot)
    let restorePending = hasHistoryRestore()
    if restorePending:
      echo "An interrupted history restore awaits automatic recovery under the package lock."
    for line in pending: echo line
    if pending.len == 0 and not restorePending:
      echo "No pending history recovery for " & historyRoot
  except CatchableError as e:
    fatal("history: " & e.msg)

proc historyRecover*(root = "/", yes = false) =
  ## Recover interrupted history work after confirmation and under exclusivity.
  let historyRoot = normalizedPath(absolutePath(if root.len == 0: "/" else: root))
  try:
    let pending = inspectPendingHistory(historyRoot)
    let restorePending = hasHistoryRestore()
    if restorePending:
      echo "An interrupted history restore will resume under the package lock."
    for line in pending: echo line
    if pending.len == 0 and not restorePending:
      echo "No pending history recovery for " & historyRoot
      return
    if not isAdmin():
      fatal("you have to be root for this action.")
    if not yes:
      stdout.write "Recover interrupted history operations? (y/N) "
      if stdin.readLine().strip().toLowerAscii() notin ["y", "yes"]:
        echo "Cancelled."
        return
    # No lock checks before confirmation: checkLockfile can remove stale files.
    isKpkgRunning()
    checkLockfile()
    createLockfile() # Resumes durable .restore recovery before pending history.
    var recovered = 0
    try:
      recovered = recoverPendingHistory(historyRoot)
    finally:
      removeLockfile()
      clearErrorCallback()
    echo "History recovery complete: " & $recovered & " pending operations recovered."
  except CatchableError as e:
    fatal("history: " & e.msg)
