import std/[unittest, tables, json]
import ../../../kpkg/modules/[dephandler, runparser]

proc package(name, repo: string,
        deps: seq[string] = @[], bdeps: seq[string] = @[],
        bsdeps: seq[string] = @[]): resolvedPackage =
  resolvedPackage(name: name, repo: repo,
      metadata: runFile(deps: deps, bdeps: bdeps, bsdeps: bsdeps))

proc fixture(reverseInsertion = false): dependencyGraph =
  result.nodes = initTable[string, resolvedPackage]()
  result.edges = initTable[string, seq[string]]()
  let entries = @[
    package("zeta", "/repo/zeta", @["runtime-z"], @["build-z"], @["seed-z"]),
    package("root\"pkg", "/repo/with\\slash"),
    package("alpha", "/repo/alpha")]
  if reverseInsertion:
    for i in countdown(entries.high, 0):
      result.nodes[entries[i].name] = entries[i]
  else:
    for entry in entries:
      result.nodes[entry.name] = entry
  if reverseInsertion:
    result.edges["root\"pkg"] = @[]
    result.edges["alpha"] = @["zeta", "root\"pkg"]
    result.edges["zeta"] = @["root\"pkg"]
  else:
    result.edges["zeta"] = @["root\"pkg"]
    result.edges["alpha"] = @["root\"pkg", "zeta"]
    result.edges["root\"pkg"] = @[]

suite "dependency JSON graph":
  test "uses schema v1 and dependency-to-dependent edge direction":
    let document = parseJson(generateDependencyJson(fixture(),
        @["zeta", "root\"pkg", "zeta"]))
    check document["schema_version"].getInt == 1
    check document["roots"].getElems == @[%"root\"pkg", %"zeta"]
    check document["nodes"].len == 3
    check document["nodes"][0]["name"].getStr == "alpha"
    check document["nodes"][1]["name"].getStr == "root\"pkg"
    check document["nodes"][1]["repo"].getStr == "/repo/with\\slash"
    check document["nodes"][2]["name"].getStr == "zeta"
    check document["nodes"][2]["depends"].getElems == @[%"runtime-z"]
    check document["nodes"][2]["build_depends"].getElems == @[%"build-z"]
    check document["nodes"][2]["bootstrap_depends"].getElems == @[%"seed-z"]
    check document["edges"].getElems == @[
      %*{"dependency": "alpha", "dependent": "root\"pkg"},
      %*{"dependency": "alpha", "dependent": "zeta"},
      %*{"dependency": "zeta", "dependent": "root\"pkg"}]

  test "escapes strings and is deterministic across table insertion order":
    let first = generateDependencyJson(fixture(), @["root\"pkg"])
    let second = generateDependencyJson(fixture(true), @["root\"pkg"])
    check first == second
    check parseJson(first)["nodes"][1]["repo"].getStr ==
        "/repo/with\\slash"
