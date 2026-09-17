import std/[os, tempfiles, unittest]
import ../../krep/modules/isokernel

proc modules(rootfs, version: string, base = "usr/lib/modules") =
  let target = rootfs / base / version
  createDir(target)
  writeFile(target / "modules.dep", "")

proc image(rootfs, name: string) =
  createDir(rootfs / "boot")
  writeFile(rootfs / "boot" / name, "test kernel")

suite "rootfs ISO kernel selection":
  setup:
    let work = createTempDir("krep-kernel-test-", "")
    let rootfs = work / "rootfs"
    createDir(rootfs)
  teardown:
    removeDir(work)

  test "selects the only version and its versioned image":
    modules(rootfs, "6.12.3-test+1")
    image(rootfs, "vmlinuz-6.12.3-test+1")
    let selected = selectKernel(rootfs)
    check selected.version == "6.12.3-test+1"
    check selected.image == rootfs / "boot/vmlinuz-6.12.3-test+1"
    check selected.modulesDir == rootfs / "usr/lib/modules/6.12.3-test+1"

  test "supports legacy lib modules and Image filenames":
    modules(rootfs, "6.12", "lib/modules")
    image(rootfs, "Image-6.12")
    let selected = selectKernel(rootfs)
    check selected.image == rootfs / "boot/Image-6.12"
    check selected.modulesDir == rootfs / "lib/modules/6.12"

  test "supports unversioned images with one module version":
    modules(rootfs, "6.12")
    image(rootfs, "Image")
    check selectKernel(rootfs).image == rootfs / "boot/Image"
    image(rootfs, "vmlinuz")
    check selectKernel(rootfs).image == rootfs / "boot/vmlinuz"
    image(rootfs, "Image-6.12")
    check selectKernel(rootfs).image == rootfs / "boot/Image-6.12"

  test "multiple module versions need an explicit version":
    modules(rootfs, "6.12")
    modules(rootfs, "6.13")
    image(rootfs, "vmlinuz-6.12")
    image(rootfs, "vmlinuz-6.13")
    expect ValueError: discard selectKernel(rootfs)
    check selectKernel(rootfs, "6.13").version == "6.13"
    check selectKernel(rootfs, "6.12").image == rootfs / "boot/vmlinuz-6.12"

  test "does not choose a version just because only one image exists":
    modules(rootfs, "6.12")
    modules(rootfs, "6.13")
    image(rootfs, "vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)

  test "generic image cannot disambiguate multiple module versions":
    modules(rootfs, "6.12")
    modules(rootfs, "6.13")
    image(rootfs, "vmlinuz")
    expect ValueError: discard selectKernel(rootfs, "6.12")
    # An explicit override asserts the image/version association.
    check selectKernel(rootfs, "6.12", "/boot/vmlinuz").version == "6.12"
    expect ValueError: discard selectKernel(rootfs,
        kernelImage = "/boot/vmlinuz")

  test "missing module tree and missing version are rejected":
    image(rootfs, "vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)
    modules(rootfs, "6.12")
    expect ValueError: discard selectKernel(rootfs, "6.13")
    expect ValueError: discard selectKernel(work / "absent")
    expect ValueError: discard selectKernel("")

  test "module index is required":
    createDir(rootfs / "usr/lib/modules/6.12")
    image(rootfs, "vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)

  test "missing image and mismatched image are rejected":
    modules(rootfs, "6.12")
    expect ValueError: discard selectKernel(rootfs)
    image(rootfs, "vmlinuz-6.13")
    expect ValueError: discard selectKernel(rootfs)

  test "usr merged modules are deduplicated with chroot symlink semantics":
    modules(rootfs, "6.12")
    createSymlink("/usr/lib", rootfs / "lib")
    image(rootfs, "vmlinuz-6.12")
    check selectKernel(rootfs).modulesDir == rootfs / "usr/lib/modules/6.12"

  test "conflicting same version trees are rejected":
    modules(rootfs, "6.12")
    modules(rootfs, "6.12", "lib/modules")
    image(rootfs, "vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)

  test "module version symlink to noncanonical dracut layout is rejected":
    createDir(rootfs / "opt/kernel-modules")
    writeFile(rootfs / "opt/kernel-modules/modules.dep", "")
    createDir(rootfs / "usr/lib/modules")
    createSymlink("/opt/kernel-modules", rootfs / "usr/lib/modules/6.12")
    image(rootfs, "vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)

  test "module symlinks cannot select host modules":
    let outside = work / "host-modules"
    createDir(outside)
    writeFile(outside / "modules.dep", "")
    createDir(rootfs / "usr/lib/modules")
    createSymlink(outside, rootfs / "usr/lib/modules/6.12")
    image(rootfs, "vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)

  test "absolute module index symlinks are unsafe for host dracut":
    modules(rootfs, "6.12")
    image(rootfs, "vmlinuz-6.12")
    let dep = rootfs / "usr/lib/modules/6.12/modules.dep"
    removeFile(dep)
    createDir(rootfs / "opt")
    writeFile(rootfs / "opt/modules.dep", "")
    createSymlink("/opt/modules.dep", dep)
    expect ValueError: discard selectKernel(rootfs)
    removeFile(dep)
    let outside = work / "host-modules.dep"
    writeFile(outside, "")
    createSymlink(outside, dep)
    expect ValueError: discard selectKernel(rootfs)

  test "relative module links confined to selected tree are supported":
    modules(rootfs, "6.12")
    image(rootfs, "vmlinuz-6.12")
    let tree = rootfs / "usr/lib/modules/6.12"
    createDir(tree / "kernel")
    writeFile(tree / "kernel/driver.ko", "module")
    createDir(tree / "updates")
    createSymlink("../kernel/driver.ko", tree / "updates/driver.ko")
    createSymlink("/usr/src/linux", tree / "build")
    createSymlink("/usr/src/linux", tree / "source")
    check selectKernel(rootfs).version == "6.12"

  test "host-facing module symlinks cannot escape or use development links":
    modules(rootfs, "6.12")
    image(rootfs, "vmlinuz-6.12")
    let tree = rootfs / "usr/lib/modules/6.12"
    createSymlink("/usr/src/linux", tree / "build")
    createDir(tree / "kernel")
    let link = tree / "kernel/driver.ko"
    for target in ["/opt/driver.ko", "../../driver.ko", "../build/driver.ko", "driver.ko"]:
      createSymlink(target, link)
      expect ValueError: discard selectKernel(rootfs)
      removeFile(link)

  test "module directory symlinks cannot expose host subtrees":
    modules(rootfs, "6.12")
    image(rootfs, "vmlinuz-6.12")
    let tree = rootfs / "usr/lib/modules/6.12"
    createDir(rootfs / "opt/drivers")
    writeFile(rootfs / "opt/drivers/driver.ko", "module")
    let outside = work / "host-drivers"
    createDir(outside)
    writeFile(outside / "driver.ko", "host module")
    for target in ["/opt/drivers", outside, "../../../../opt/drivers"]:
      createSymlink(target, tree / "updates")
      expect ValueError: discard selectKernel(rootfs)
      removeFile(tree / "updates")

  test "relative module directory and index links stay usable":
    modules(rootfs, "6.12")
    image(rootfs, "vmlinuz-6.12")
    let tree = rootfs / "usr/lib/modules/6.12"
    createDir(tree / "kernel")
    writeFile(tree / "kernel/driver.ko", "module")
    createSymlink("kernel", tree / "updates")
    moveFile(tree / "modules.dep", tree / "modules.dep.actual")
    createSymlink("modules.dep.actual", tree / "modules.dep")
    check selectKernel(rootfs).version == "6.12"

  test "directory aliases cannot hide unsafe nested module links":
    modules(rootfs, "6.12")
    image(rootfs, "vmlinuz-6.12")
    let tree = rootfs / "usr/lib/modules/6.12"
    createDir(tree / "kernel/nested")
    createSymlink("kernel", tree / "updates")
    createSymlink("/opt/host-driver.ko", tree / "kernel/nested/driver.ko")
    expect ValueError: discard selectKernel(rootfs)

  test "absolute kernel symlink resolves inside the rootfs":
    modules(rootfs, "6.12")
    createDir(rootfs / "opt")
    writeFile(rootfs / "opt/linux", "test kernel")
    createDir(rootfs / "boot")
    createSymlink("/opt/linux", rootfs / "boot/vmlinuz-6.12")
    check selectKernel(rootfs).image == rootfs / "opt/linux"

  test "relative kernel symlinks and symlinked boot directory work":
    modules(rootfs, "6.12")
    createDir(rootfs / "usr/boot")
    writeFile(rootfs / "usr/boot/kernel", "test kernel")
    createSymlink("kernel", rootfs / "usr/boot/vmlinuz-6.12")
    createSymlink("usr/boot", rootfs / "boot")
    check selectKernel(rootfs).image == rootfs / "usr/boot/kernel"

  test "symlink targets do not escape to host files":
    modules(rootfs, "6.12")
    let outside = work / "host-kernel"
    writeFile(outside, "not a target kernel")
    createDir(rootfs / "boot")
    createSymlink(outside, rootfs / "boot/vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)
    removeFile(rootfs / "boot/vmlinuz-6.12")
    createSymlink("../../host-kernel", rootfs / "boot/vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)

  test "symlink loops are rejected":
    modules(rootfs, "6.12")
    createDir(rootfs / "boot")
    createSymlink("vmlinuz-6.12", rootfs / "boot/vmlinuz-6.12")
    expect ValueError: discard selectKernel(rootfs)

  test "explicit image path stays inside rootfs":
    modules(rootfs, "6.12")
    createDir(rootfs / "opt")
    writeFile(rootfs / "opt/custom-kernel", "test kernel")
    check selectKernel(rootfs, kernelImage = "/opt/custom-kernel").image ==
      rootfs / "opt/custom-kernel"
    let outside = work / "host-kernel"
    writeFile(outside, "not a target kernel")
    expect ValueError: discard selectKernel(rootfs, kernelImage = outside)
    for path in ["boot/vmlinuz", "/", "/../host-kernel",
        "/boot/../../host-kernel", "/bad\npath"]:
      expect ValueError: discard selectKernel(rootfs, kernelImage = path)

  test "unsafe explicit versions are rejected":
    for version in ["..", ".", "../6.12", "/6.12", "6.12 bad", "6.12;true",
        "-option", "6.12\n"]:
      expect ValueError: discard selectKernel(rootfs, version)

  test "unsafe discovered version directories are rejected":
    modules(rootfs, "6.12 bad")
    image(rootfs, "vmlinuz")
    expect ValueError: discard selectKernel(rootfs)
