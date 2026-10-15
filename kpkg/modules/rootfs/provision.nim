import ./[types, provider]

proc provision*(plan: RootfsPlan, acquire: ArtifactProvider,
    remove, install: PackageMutation, phase: PhaseCallback = nil) =
  ## Acquire every artifact before the first destructive operation.
  var completed: seq[string]
  if phase != nil: phase(rpAcquiring, plan.acquire, completed)
  acquireAll(plan.acquire, plan.profile.target, acquire)
  if phase != nil: phase(rpAcquired, @[], completed)
  if phase != nil: phase(rpRemoving, plan.remove, completed)
  for package in plan.remove:
    remove(package)
    completed.add(package)
    if phase != nil:
      phase(rpRemoving, if completed.len < plan.remove.len:
        plan.remove[completed.len .. ^1] else: @[], completed)
  completed.setLen(0)
  if phase != nil: phase(rpInstalling, plan.install, completed)
  for package in plan.install:
    install(package)
    completed.add(package)
    if phase != nil:
      phase(rpInstalling, if completed.len < plan.install.len:
        plan.install[completed.len .. ^1] else: @[], completed)
