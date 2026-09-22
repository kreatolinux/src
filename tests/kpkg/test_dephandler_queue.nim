import unittest
import tables
import sets
import strutils
import ../../kpkg/modules/dephandler
import ../../kpkg/modules/builder/sandbox
import ../../kpkg/modules/builder/cache
import ../../kpkg/modules/runparser

proc mkRunFile(name: string, deps: seq[string] = @[], bdeps: seq[string] = @[],
               bsdeps: seq[string] = @[]): runFile =
  runFile(
    pkg: name,
    version: "1",
    release: "1",
    epoch: "",
    versionString: "1-1",
    deps: deps,
    bdeps: bdeps,
    bsdeps: bsdeps
  )

proc mkResolved(name: string, bsdeps: seq[string] = @[]): resolvedPackage =
  resolvedPackage(name: name, repo: "/etc/kpkg/repos/main", metadata: mkRunFile(
      name, bsdeps = bsdeps))

suite "dephandler build queue":
  test "normal retry keeps bootstrap seeds as explicit roots":
    let roots = finalRetryPackages(@["gnome"], @["glib"])

    check roots == @["gnome", "glib"]

    var graph: dependencyGraph
    graph.nodes = initTable[string, resolvedPackage]()
    graph.edges = initTable[string, seq[string]]()
    graph.nodes["gobject-introspection"] = mkResolved("gobject-introspection")
    graph.nodes["glib"] = mkResolved("glib", bsdeps = @["meson"])
    graph.nodes["gnome"] = mkResolved("gnome")
    # bootstrapSatisfied suppresses glib -> gobject-introspection, while
    # the normal GLib build edge remains GI -> GLib.
    graph.edges["gobject-introspection"] = @["glib"]
    graph.edges["glib"] = @["gnome"]
    graph.edges["gnome"] = @[]

    var bootstrapSatisfied = initHashSet[string]()
    bootstrapSatisfied.incl("glib")
    let queue = computeBuildQueue(graph, roots, bootstrap = false,
        bootstrapSatisfied = bootstrapSatisfied)
    check queue.find("gobject-introspection") < queue.find("glib")
    check queue.find("glib") < queue.find("gnome")

  test "bootstrap retry breaks cyclic dependency between cmake, doxygen and libxml2":
    let roots = finalRetryPackages(@["libxml2"], @["cmake"])
    check roots == @["libxml2", "cmake"]

    var graph: dependencyGraph
    graph.nodes = initTable[string, resolvedPackage]()
    graph.edges = initTable[string, seq[string]]()
    graph.nodes["cmake"] = mkResolved("cmake", bsdeps = @["gmake"])
    graph.nodes["doxygen"] = mkResolved("doxygen")
    graph.nodes["libxml2"] = mkResolved("libxml2")

    graph.edges["cmake"] = @[]
    graph.edges["doxygen"] = @["libxml2"]
    graph.edges["libxml2"] = @["cmake"]

    var bootstrapSatisfied = initHashSet[string]()
    bootstrapSatisfied.incl("cmake")
    let queue = computeBuildQueue(graph, roots, bootstrap = false,
        bootstrapSatisfied = bootstrapSatisfied)
    check queue.find("doxygen") < queue.find("libxml2")
    check queue.find("libxml2") < queue.find("cmake")

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

  test "dynamic sandbox deps include the package runtime closure":
    var metadata = initTable[string, runFile]()
    metadata["automake"] = mkRunFile("automake", @["perl", "autoconf",
        "libtool"], @["gmake"])
    metadata["autoconf"] = mkRunFile("autoconf", @["m4"])
    metadata["gmake"] = mkRunFile("gmake")
    metadata["perl"] = mkRunFile("perl")
    metadata["libtool"] = mkRunFile("libtool")
    metadata["m4"] = mkRunFile("m4")

    let deps = collectDynamicSandboxDeps("automake",
        proc(pkg: string): runFile = metadata[pkg])

    check deps == @["gmake", "perl", "autoconf", "m4", "libtool"]

  test "sandbox keeps installed runtime deps omitted from rebuild graph":
    let deps = collectInstalledDirectRuntimeDeps(@["glib>=2.80", "dbus"],
        proc(dep: string): string =
      if dep.startsWith("glib"): "glib" else: dep,
        proc(pkg: string): bool = pkg == "glib")

    check deps == @["glib"]

  test "bootstrap package metadata uses bootstrap dependencies":
    let pkg = runFile(
      pkg: "gobject-introspection",
      version: "1.86.0",
      release: "4",
      epoch: "",
      versionString: "1.86.0-4",
      deps: @["python", "glib"],
      bdeps: @["meson", "ninja"],
      bsdeps: @["python", "meson", "ninja"]
    )

    check packageDepsForMetadata(pkg, useBootstrapDeps = false) == @["python", "glib"]
    check packageDepsForMetadata(pkg, useBootstrapDeps = true) == @["python",
        "meson", "ninja"]

  test "forced resolution skips only bootstrap-satisfied installed dependencies":
    var rootPackages = initHashSet[string]()
    var bootstrapSatisfied = initHashSet[string]()
    bootstrapSatisfied.incl("gobject-introspection")

    check shouldSkipInstalledDependency(true, "noupgrade",
        "gobject-introspection", rootPackages, false, bootstrapSatisfied)
    check not shouldSkipInstalledDependency(true, "noupgrade",
        "gobject-introspection", rootPackages, true, initHashSet[string]())
    check shouldSkipInstalledDependency(true, "noupgrade",
        "gobject-introspection", rootPackages, true, bootstrapSatisfied)
    check not shouldSkipInstalledDependency(true, "noupgrade", "glib",
        rootPackages, true, bootstrapSatisfied)
    rootPackages.incl("gobject-introspection")
    check shouldSkipInstalledDependency(true, "noupgrade",
        "gobject-introspection", rootPackages, false, bootstrapSatisfied)
    check shouldSkipInstalledDependency(true, "noupgrade",
        "gobject-introspection", rootPackages, true, bootstrapSatisfied)
    check not shouldSkipInstalledDependency(true, "noupgrade", "glib",
        rootPackages, true, bootstrapSatisfied)
    check shouldSkipInstalledDependency(false, "noupgrade",
        "gobject-introspection", rootPackages, false, bootstrapSatisfied)
    check shouldSkipInstalledDependency(false, "upgrade",
        "gobject-introspection", rootPackages, true, bootstrapSatisfied)
    check shouldSkipInstalledDependency(true, "upgrade",
        "gobject-introspection", rootPackages, true, bootstrapSatisfied)


suite "builder cache identity":
  test "bootstrap and normal archives have different paths":
    let pkg = mkRunFile("glib")
    let normal = cacheArchivePath("glib", pkg, "aarch64-linux-gnu")
    let bootstrap = cacheArchivePath("glib", pkg, "aarch64-linux-gnu",
        isBootstrap = true)

    check normal != bootstrap
    check "/system/aarch64-linux-gnu/glib-1-1.kpkg" in normal
    check "/bootstrap/aarch64-linux-gnu/glib-1-1.kpkg" in bootstrap
