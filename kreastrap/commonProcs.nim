import os
import ../common/logging

proc set_default_cc*(buildDir: string, cc: string) =
  ## Sets the default compiler.
  let files = ["/bin/gcc", "/bin/cc", "/bin/c99", "/bin/g++", "/bin/c++"]
  var file: string
  for i in files:
    file = buildDir&i
    if not fileExists(file):
      createSymlink(cc, file)

proc initDirectories*(buildDirectory: string, arch: string, silent = false) =
  # Initializes directories.

  #if dirExists(buildDirectory):
  #    info_msg "rootfs directory exist, removing"
  #    removeDir(buildDirectory)

  debug "Making initial rootfs directories"

  createDir(buildDirectory)
  createDir(buildDirectory&"/etc")
  createDir(buildDirectory&"/usr")
  createDir(buildDirectory&"/usr/bin")
  createDir(buildDirectory&"/usr/lib")
  createDir(buildDirectory&"/var")
  createDir(buildDirectory&"/var/cache")
  createDir(buildDirectory&"/var/lib")
  createDir(buildDirectory&"/var/cache/kpkg")
  createDir(buildDirectory&"/var/lib/kpkg")
  createDir(buildDirectory&"/boot")
  createDir(buildDirectory&"/root")
  createDir(buildDirectory&"/dev")
  createDir(buildDirectory&"/opt")
  createDir(buildDirectory&"/proc")
  createDir(buildDirectory&"/sys")
  createDir(buildDirectory&"/mnt")
  createDir(buildDirectory&"/media")
  createDir(buildDirectory&"/home")
  createDir(buildDirectory&"/tmp")
  createDir(buildDirectory&"/usr/local")
  createDir(buildDirectory&"/usr/local/lib")
  createDir(buildDirectory&"/usr/local/bin")
  createDir(buildDirectory&"/usr/local/sbin")
  createDir(buildDirectory&"/usr/local/include")
  createDir(buildDirectory&"/usr/include")

  # Set permissions for directories
  setFilePermissions(buildDirectory, {fpUserExec, fpUserRead, fpGroupExec,
          fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/etc", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/bin", {fpUserExec, fpUserRead,
          fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/lib", {fpUserExec, fpUserRead,
          fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/var", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/var/cache", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/var/lib", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/var/cache/kpkg", {fpUserExec,
          fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/var/lib/kpkg", {fpUserExec,
          fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/boot", {fpUserExec, fpUserRead,
          fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/root", {fpUserExec, fpUserRead,
          fpGroupExec, fpGroupRead})

  setFilePermissions(buildDirectory&"/dev", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/opt", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/proc", {fpUserExec, fpUserRead,
          fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/sys", {fpUserExec, fpUserRead,
          fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/mnt", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/media", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/home", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/tmp", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupWrite, fpGroupRead, fpOthersExec,
          fpOthersWrite, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/local", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/local/lib", {fpUserExec,
          fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/local/bin", {fpUserExec,
          fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/local/sbin", {fpUserExec,
          fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/local/include", {fpUserExec,
          fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  setFilePermissions(buildDirectory&"/usr/include", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  createDir(buildDirectory&"/var/cache/kpkg")
  createDir(buildDirectory&"/run")

  setFilePermissions(buildDirectory&"/run", {fpUserExec, fpUserWrite,
          fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  if arch == "amd64":
    createSymlink("usr/lib", buildDirectory&"/lib64")
    createSymlink("lib", buildDirectory&"/usr/lib64")

  createSymlink("usr/bin", buildDirectory&"/sbin")
  createSymlink("bin", buildDirectory&"/usr/sbin")
  createSymlink("usr/bin", buildDirectory&"/bin")
  createSymlink("usr/lib", buildDirectory&"/lib")

  if not silent:
    info_msg "Root directory structure created."
