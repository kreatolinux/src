import std/[algorithm, os, sets, strutils, tables, tempfiles, unittest]
import ../../kickoff/modules/modules

const sampleDep = """
kernel/fs/erofs/erofs.ko: kernel/lib/lz4/lz4hc_compress.ko kernel/lib/lz4/lz4_decompress.ko
kernel/lib/lz4/lz4hc_compress.ko:
kernel/lib/lz4/lz4_decompress.ko:
kernel/fs/overlayfs/overlay.ko:
kernel/drivers/block/loop.ko:
kernel/fs/isofs/isofs.ko: kernel/fs/nls/nls_base.ko
kernel/fs/nls/nls_base.ko:
kernel/drivers/block/virtio_blk.ko:
kernel/fs/squashfs/squashfs.ko:
"""

const sampleBuiltin = """
kernel/drivers/block/virtio_blk.ko
kernel/drivers/scsi/sr_mod.ko
"""

proc sampleIndex(): ModuleIndex =
  result.root = "/nowhere"
  result.deps = parseModulesDep(sampleDep)
  for path in result.deps.keys:
    result.byName.mgetOrPut(path.extractFilename(), @[]).add path
  result.builtin = parseModulesBuiltin(sampleBuiltin)

suite "module selection":
  test "parses modules.dep: paths, deps, empty dep lists":
    let deps = parseModulesDep(sampleDep)
    check deps.len == 9
    check deps["kernel/fs/erofs/erofs.ko"] ==
      @["kernel/lib/lz4/lz4hc_compress.ko", "kernel/lib/lz4/lz4_decompress.ko"]
    check deps["kernel/fs/overlayfs/overlay.ko"].len == 0

  test "parses continuation lines":
    let deps = parseModulesDep("a.ko: b.ko\n  c.ko\nd.ko:\n")
    check deps["a.ko"] == @["b.ko", "c.ko"]
    check deps["d.ko"].len == 0

  test "layout selects the right module names":
    check requiredModuleNames(rlErofsDisk) == @["erofs", "overlay", "virtio_blk"]
    check requiredModuleNames(rlSquashfsDisk) ==
      @["squashfs", "loop", "overlay", "virtio_blk"]
    check requiredModuleNames(rlSquashfsIso) ==
      @["squashfs", "loop", "isofs", "overlay", "virtio_blk", "sr_mod", "cdrom"]

  test "block and optical drivers are listed but skipped when built in":
    # They are built into the Kreato kernel, so nothing is copied for them --
    # but listing them keeps the same layout working where they are modules.
    let idx = sampleIndex()
    let r = collectModules(idx, requiredModuleNames(rlSquashfsIso))
    check "virtio_blk" in r.skippedBuiltin

  test "parseLayout accepts aliases and rejects nonsense":
    check parseLayout("") == rlErofsDisk
    check parseLayout("EROFS") == rlErofsDisk
    check parseLayout("squashfs") == rlSquashfsDisk
    check parseLayout("iso") == rlSquashfsIso
    expect ValueError: discard parseLayout("xfs")

  test "collectModules resolves dependencies transitively":
    let idx = sampleIndex()
    let r = collectModules(idx, @["erofs"])
    # erofs plus both lz4 objects
    check r.files.len == 3
    check "kernel/fs/erofs/erofs.ko" in r.files
    check "kernel/lib/lz4/lz4hc_compress.ko" in r.files
    check r.missing.len == 0

  test "collectModules skips modules built into the kernel":
    let idx = sampleIndex()
    check idx.isBuiltin("virtio_blk")
    let r = collectModules(idx, @["virtio_blk"])
    check r.files.len == 0
    check "virtio_blk" in r.skippedBuiltin

  test "collectModules reports unknown modules rather than dropping them":
    let idx = sampleIndex()
    let r = collectModules(idx, @["nosuchmodule"])
    check r.missing == @["nosuchmodule"]

  test "collectModules handles a shared dependency only once":
    let idx = sampleIndex()
    let r = collectModules(idx, @["erofs", "isofs"])
    # erofs + 2 lz4, isofs + nls_base
    check r.files.len == 5
    var unique = initHashSet[string]()
    for f in r.files: unique.incl f
    check unique.len == r.files.len

  test "loadModuleIndex needs modules.dep and reports it clearly":
    let root = getTempDir() / "kickoff-modroot"
    removeDir(root)
    createDir(root / "usr/lib/modules/6.18.3")
    expect IOError:
      discard loadModuleIndex(root, "6.18.3")
    writeFile(root / "usr/lib/modules/6.18.3/modules.dep", sampleDep)
    writeFile(root / "usr/lib/modules/6.18.3/modules.builtin", sampleBuiltin)
    let idx = loadModuleIndex(root, "6.18.3")
    check idx.deps.len == 9
    check idx.isBuiltin("virtio_blk")


  test "loadOrder puts dependencies before dependents":
    let idx = sampleIndex()
    let r = collectModules(idx, @["isofs"])
    let order = loadOrder(idx, r.files)
    check order.len == r.files.len
    let iNls = order.find("kernel/fs/nls/nls_base.ko")
    let iIsofs = order.find("kernel/fs/isofs/isofs.ko")
    check iNls >= 0 and iIsofs >= 0
    check iNls < iIsofs           # dependency first

  test "loadOrder keeps erofs after its lz4 dependencies":
    let idx = sampleIndex()
    let r = collectModules(idx, @["erofs"])
    let order = loadOrder(idx, r.files)
    let iErofs = order.find("kernel/fs/erofs/erofs.ko")
    for dep in ["kernel/lib/lz4/lz4hc_compress.ko", "kernel/lib/lz4/lz4_decompress.ko"]:
      check order.find(dep) < iErofs

  test "loadOrder emits every input exactly once":
    let idx = sampleIndex()
    let r = collectModules(idx, @["erofs", "squashfs", "overlay"])
    let order = loadOrder(idx, r.files)
    check order.len == r.files.len
    var seen = initHashSet[string]()
    for f in order: seen.incl f
    check seen.len == order.len

  test "module paths are absolute and stay under the module root":
    let root = getTempDir() / "kickoff-modpaths"
    removeDir(root)
    createDir(root / "lib/modules/6.18.3")
    writeFile(root / "lib/modules/6.18.3/modules.dep", sampleDep)
    let idx = loadModuleIndex(root, "6.18.3")
    let r = collectModules(idx, @["squashfs"])
    let paths = moduleFilePaths(idx, r.files)
    check paths.len == 1
    check paths[0] == idx.root / "kernel/fs/squashfs/squashfs.ko"
