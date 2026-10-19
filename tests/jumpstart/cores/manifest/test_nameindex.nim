import std/[os, sequtils, times, unittest]
import ../../../../jumpstart/cores/manifest/nameindex

proc tempRoot(label: string): string =
  result = getTempDir() / ("jumpstart-nameindex-" & label & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  createDir(result)

suite "core name indexes":
  test "refresh keeps one sorted unique name per line and replaces atomically":
    let root = tempRoot("refresh"); defer: removeDir(root)
    var store = initNameIndexStore(root)
    store.refresh("systemd", ["z.service", "a.service", "z.service"])
    check store.hasIndex("systemd")
    check store.indexedNames("systemd") == @["a.service", "z.service"]
    check readFile(store.nameIndexPath("systemd")) ==
      "a.service\nz.service\n"

    store.refreshAfterLoad("systemd", ["new.service"])
    check store.indexedNames("systemd") == @["new.service"]
    check readFile(store.nameIndexPath("systemd")) == "new.service\n"
    check toSeq(walkFiles(store.nameIndexPath("systemd") & ".tmp-*")).len == 0

  test "names that begin with a dash are indexed (§14.1)":
    let root = tempRoot("dash"); defer: removeDir(root)
    var store = initNameIndexStore(root)
    store.refresh("systemd", ["-.mount", "-.slice", "a.service"])
    check store.contains("systemd", "-.mount")
    check readFile(store.nameIndexPath("systemd")) == "-.mount\n-.slice\na.service\n"
    var loaded = loadNameIndexes(root, ["systemd"])
    check loaded.contains("systemd", "-.slice")

  test "owned resolution records requested and canonical spellings":
    let root = tempRoot("owned"); defer: removeDir(root)
    var store = initNameIndexStore(root)
    store.recordOwned("example", "alias", "canonical.service")
    check store.contains("example", "alias")
    check store.contains("example", "canonical.service")
    check readFile(store.nameIndexPath("example")) ==
      "alias\ncanonical.service\n"

    store.recordOwned("example", "second", "canonical.service")
    check store.indexedNames("example") ==
      @["alias", "canonical.service", "second"]

  test "load restores enabled indexes and ignores disabled index files":
    let root = tempRoot("load"); defer: removeDir(root)
    var writer = initNameIndexStore(root)
    writer.refresh("enabled", ["kept"])
    writer.refresh("disabled", ["ignored"])
    writer.refresh("empty", [])

    var loaded = loadNameIndexes(root, ["enabled", "empty", "missing"])
    check loaded.hasIndex("enabled")
    check loaded.contains("enabled", "kept")
    check loaded.hasIndex("empty")
    check loaded.indexedNames("empty").len == 0
    check not loaded.hasIndex("missing")
    check not loaded.hasIndex("disabled")
    check not loaded.contains("disabled", "ignored")
    check fileExists(writer.nameIndexPath("disabled"))

    loaded.load(["disabled"])
    check loaded.hasIndex("disabled")
    check not loaded.hasIndex("enabled")

  test "list refresh replaces resolve additions":
    let root = tempRoot("replace"); defer: removeDir(root)
    var store = initNameIndexStore(root)
    store.recordOwned("example", "alias", "canonical")
    store.refreshAfterList("example", ["listed"])
    check store.indexedNames("example") == @["listed"]

  test "invalid names do not alter memory or the persisted index":
    let root = tempRoot("invalid"); defer: removeDir(root)
    var store = initNameIndexStore(root)
    store.refresh("example", ["safe"])
    expect NameIndexError:
      store.recordOwned("example", "bad/name", "canonical")
    check store.indexedNames("example") == @["safe"]
    check readFile(store.nameIndexPath("example")) == "safe\n"

  test "malformed persisted indexes fail without replacing memory":
    let root = tempRoot("malformed"); defer: removeDir(root)
    var store = initNameIndexStore(root)
    store.refresh("example", ["old"])
    writeFile(store.nameIndexPath("example"), "unterminated")
    expect NameIndexError:
      store.load(["example"])
    check store.indexedNames("example") == @["old"]
