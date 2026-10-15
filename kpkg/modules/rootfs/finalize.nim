import std/[os, strutils]
import ./types

proc replaceSymlink(root, target, link: string) =
  let path = root / link.strip(chars = {'/'})
  createDir(parentDir(path))
  if fileExists(path) or symlinkExists(path): removeFile(path)
  createSymlink(target, path)

proc finalizeProfileLinks*(root: string, profile: RootfsProfile) =
  case profile.coreutils
  of "gnu": replaceSymlink(root, "/bin/bash", "/bin/sh")
  else: discard
  case profile.init
  of "jumpstart": replaceSymlink(root, "/bin/jumpstart", "/sbin/init")
  of "openrc": replaceSymlink(root, "/usr/bin/openrc-init", "/sbin/init")
  of "systemd": replaceSymlink(root, "/lib/systemd/systemd", "/sbin/init")
  of "busybox": discard
  else: raise newException(ValueError, "unsupported init finalizer '" &
      profile.init & "'")
