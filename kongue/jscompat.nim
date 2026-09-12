## Browser (JS target) compatibility layer for Kongue.
##
## Kongue drives real builds natively: it spawns processes and writes to disk.
## A browser has neither. This module gives the JS target a small, deterministic
## stand-in so the language itself stays unchanged:
##
##   * ``vfs`` - a virtual filesystem backing read, write and append
##   * no environment variables
##   * one fixed working directory
##
## The module is empty on native targets. Native builds keep using ``os`` and
## ``osproc`` exactly as before.

when defined(js):
  import strutils
  import tables

  ## Where playground scripts "live". Absolute and POSIX-style, so a relative
  ## path in a script resolves the same way on every machine and every run.
  const playgroundDir* = "/playground"

  var vfs* = initTable[string, string]()
    ## Virtual filesystem: absolute path -> file contents.

  proc resetVfs*() =
    ## Forget every recorded file. Call this before each run so runs stay
    ## independent of one another.
    vfs.clear()

  proc readFile*(path: string): string =
    ## Read from the virtual filesystem. A missing path reads as empty rather
    ## than raising, which matches how the playground treats absent files.
    if vfs.hasKey(path):
      return vfs[path]
    return ""

  proc writeFile*(path: string, content: string) =
    ## Replace (or create) a file in the virtual filesystem.
    vfs[path] = content

  proc fileExists*(path: string): bool =
    vfs.hasKey(path)

  proc existsFile*(path: string): bool =
    vfs.hasKey(path)

  proc existsDir*(path: string): bool =
    ## True for the playground root, and for any directory that has a recorded
    ## file underneath it. There are no empty directories in the vfs.
    if path.len == 0 or path == playgroundDir:
      return true
    var prefix = path
    if not prefix.endsWith("/"):
      prefix.add('/')
    for p in vfs.keys:
      if p.startsWith(prefix):
        return true
    return false

  proc dirExists*(path: string): bool =
    existsDir(path)
