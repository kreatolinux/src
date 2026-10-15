import std/[algorithm, sequtils, strutils]
import ./[types, profile]

proc deterministic*(values: seq[string]): seq[string] =
  result = values.filterIt(it.len > 0).deduplicate()
  result.sort()

proc makeRootfsPlan*(profile: RootfsProfile, mode = rmEmpty,
    sourceProfile = RootfsProfile(), exclusions: seq[string] = @[]): RootfsPlan =
  result.profile = profile
  result.sourceProfile = sourceProfile
  result.mode = mode
  result.exclusions = deterministic(exclusions)
  result.install = resolvedPackageRoots(profile, result.exclusions)
  result.acquire = result.install
  if mode == rmSeeded and sourceProfile.schemaVersion != 0:
    let desiredIdentity = sourceProfileRoots(profile)
    result.remove = sourceProfileRoots(sourceProfile).filterIt(
        it notin desiredIdentity and it notin result.exclusions).deduplicate()

proc canonicalPlan*(plan: RootfsPlan): string =
  "profile=" & plan.profile.fingerprint & "\n" &
    "mode=" & $plan.mode & "\n" &
    "acquire=" & deterministic(plan.acquire).join(",") & "\n" &
    "remove=" & deterministic(plan.remove).join(",") & "\n" &
    "install=" & plan.install.join(",") & "\n" &
    "exclusions=" & plan.exclusions.join(",") & "\n"
