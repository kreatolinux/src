## Internal binary-archive metadata entries.
##
## Packaging registers archive-root metadata (pkgsums.ini, pkgInfo.ini) as
## package files, but installed roots never contain these generated files.
## Environment copies must skip them instead of failing strict checks or
## copying them as if they were payload.

const archiveRootMetadata* = ["pkgsums.ini", "pkgInfo.ini"]

proc isArchiveRootMetadata*(path: string): bool =
  ## True only for archive-root metadata entries (no directory component).
  result = path in archiveRootMetadata
