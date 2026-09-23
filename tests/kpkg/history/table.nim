import std/[unittest, strutils]
import ../../../kpkg/commands/historycmd
import ../../../kpkg/modules/transactions/history

suite "history table":
  test "headings and mixed length values share column positions":
    let entries = @[
      HistoryEntry(id: "short-1", state: "undone", action: "remove",
          packages: @["short"], timestamp: 0),
      HistoryEntry(id: "long-package-name-1790192127378", state: "committed",
          action: "reinstall", packages: @["long-package-name", "dependency"], timestamp: 1)]
    let rows = historyTable(entries)
    check rows.len == 3
    let dateColumn = rows[0].find("DATE")
    let stateColumn = rows[0].find("STATE")
    let actionColumn = rows[0].find("ACTION")
    check rows[1].find("reinstall") == actionColumn
    check rows[2].find("remove") == actionColumn
    let packageColumn = rows[0].find("PACKAGES")
    check rows[1].find("1970-") == dateColumn
    check rows[2].find("1970-") == dateColumn
    check rows[1].find("committed") == stateColumn
    check rows[2].find("undone") == stateColumn
    check rows[1][packageColumn .. ^1] == "long-package-name dependency"
    check rows[2][packageColumn .. ^1] == "short"
    check rows[1].startsWith(entries[1].id)

  test "color leaves visible text and column alignment unchanged":
    let entries = @[HistoryEntry(id: "python-123", state: "undone",
        action: "reinstall", packages: @["python"], timestamp: 0)]
    let plain = historyTable(entries)
    let colored = historyTable(entries, true)
    check plain.len == colored.len
    for i in 0 ..< plain.len:
      var visible = colored[i]
      for code in ["\e[0m", "\e[1m", "\e[2m", "\e[0;36m", "\e[0;34m",
          "\e[0;32m", "\e[0;33m", "\e[0;31m"]:
        visible = visible.replace(code, "")
      check visible == plain[i]
      check "\e[" notin plain[i]
      check "\e[" in colored[i]
