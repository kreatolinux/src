import unittest
import tables
import ../../kpkg/modules/dephandler
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
