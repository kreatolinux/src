import unittest
import tables
import ../../kpkg/modules/dephandler
import ../../kpkg/modules/builder/sandbox
import ../../kpkg/modules/runparser

proc mkRunFile(name: string, bsdeps: seq[string] = @[]): runFile =
  runFile(
    pkg: name,
    version: "1",
    release: "1",
    epoch: "",
    versionString: "1-1",
    deps: @[],
    bdeps: @[],
    bsdeps: bsdeps
  )

proc mkResolved(name: string, bsdeps: seq[string] = @[]): resolvedPackage =
  resolvedPackage(name: name, repo: "/etc/kpkg/repos/main", metadata: mkRunFile(
      name, bsdeps))

suite "dephandler build queue":
  test "computeBuildQueue keeps build dependencies before target":
    var graph: dependencyGraph
    graph.nodes = initTable[string, resolvedPackage]()
    graph.edges = initTable[string, seq[string]]()

    graph.nodes["pkgconf"] = mkResolved("pkgconf")
    graph.nodes["meson"] = mkResolved("meson")
    graph.nodes["python"] = mkResolved("python")
    graph.nodes["xz-utils"] = mkResolved("xz-utils")
    graph.nodes["libxml2"] = mkResolved("libxml2")

    graph.edges["pkgconf"] = @["libxml2"]
    graph.edges["meson"] = @["libxml2"]
    graph.edges["python"] = @["libxml2"]
    graph.edges["xz-utils"] = @["libxml2"]
    graph.edges["libxml2"] = @[]

    let queue = computeBuildQueue(graph, @["libxml2"], bootstrap = false)

    check queue.find("pkgconf") != -1
    check queue.find("meson") != -1
    check queue.find("libxml2") != -1
    check queue.find("pkgconf") < queue.find("libxml2")
    check queue.find("meson") < queue.find("libxml2")
    check queue.find("python") < queue.find("libxml2")
    check queue.find("xz-utils") < queue.find("libxml2")

  test "computeBuildQueue moves bootstrap package to the end in non-bootstrap mode":
    var graph: dependencyGraph
    graph.nodes = initTable[string, resolvedPackage]()
    graph.edges = initTable[string, seq[string]]()

    graph.nodes["a"] = mkResolved("a")
    graph.nodes["b"] = mkResolved("b")
    graph.nodes["foo"] = mkResolved("foo", bsdeps = @["a"])

    graph.edges["a"] = @["foo"]
    graph.edges["b"] = @[]
    graph.edges["foo"] = @[]

    let queue = computeBuildQueue(graph, @["foo"], bootstrap = false)

    check queue[^1] == "foo"

  test "dynamic build deps include missing runtime deps first":
    var queue = @["openssl"]

    proc depsOf(pkg: string): seq[string] =
      case pkg
      of "meson": @["python", "samurai"]
      else: @[]

    proc installed(pkg: string): bool = pkg == "python"

    addPackageWithDepsToQueue(queue, "meson", depsOf, installed)

    check queue == @["openssl", "samurai", "meson"]

  test "dynamic build deps include build deps of runtime deps (regression)":
    # Regression: when a package is dynamically queued (e.g. as a runtime dep
    # of a build dep of a SONAME consumer), its OWN build deps must also be
    # queued and built before it. Previously only runtime deps were resolved,
    # so a package like libuv (build_depends: automake, autoconf) was built in
    # a sandbox missing automake/autoconf -> "aclocal: not found".
    var queue: seq[string] = @[]

    proc depsOf(pkg: string): seq[string] =
      case pkg
      of "cmake": @["libuv"]
      of "libuv": @["automake", "autoconf"]
      else: @[]

    proc installed(pkg: string): bool = false

    # cmake is the dynamically-added build dep; libuv is its runtime dep.
    # automake/autoconf are libuv's build deps and must be queued before libuv.
    addPackageWithDepsToQueue(queue, "cmake", depsOf, installed)

    check queue == @["automake", "autoconf", "libuv", "cmake"]
    check queue.find("libuv") < queue.find("cmake")
    check queue.find("automake") < queue.find("libuv")
    check queue.find("autoconf") < queue.find("libuv")
