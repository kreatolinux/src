import ./types

proc acquireAll*(packages: seq[string], target: string,
    acquire: ArtifactProvider) =
  ## This phase is intentionally complete before provision mutates a root.
  for package in packages:
    acquire(package, target)
