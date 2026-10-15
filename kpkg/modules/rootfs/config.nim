import std/[parseutils, strutils]
import ./[types, profile, kongue_document]

const
  configScalars = ["schema_version", "build_directory", "package_mode",
    "use_overlay", "arch", "os", "libc", "compiler", "coreutils", "init",
    "tls_library"]
  configLists = ["package_roots", "extra_packages"]

proc parseBoolField(value, key: string): bool =
  case value.toLowerAscii()
  of "true", "yes": true
  of "false", "no": false
  else: raise newException(ValueError, "invalid boolean '" & value &
      "' for rootfs field '" & key & "'")

proc parsePackageMode(value: string): PackageMode =
  case value.toLowerAscii()
  of "binary", "binaries": pmBinary
  of "build", "source": pmBuild
  else: raise newException(ValueError, "invalid rootfs package_mode '" & value & "'")

proc loadRootfsConfig*(path: string): RootfsConfig =
  let doc = loadDeclarativeKongue(path)
  requireKnownFields(doc, path, configScalars, configLists)
  let schema = doc.scalar("schema_version", "1")
  var parsedSchema: int
  if parseInt(schema, parsedSchema) != schema.len:
    raise newException(ValueError, path & ": invalid schema_version '" & schema & "'")
  result.schemaVersion = parsedSchema
  result.buildDirectory = doc.scalar("build_directory")
  result.packageMode = parsePackageMode(doc.scalar("package_mode", "binary"))
  result.useOverlay = parseBoolField(doc.scalar("use_overlay", "true"), "use_overlay")
  result.profile = RootfsProfile(
    schemaVersion: parsedSchema,
    arch: doc.scalar("arch"), os: doc.scalar("os", "linux"),
    libc: doc.scalar("libc"), compiler: doc.scalar("compiler"),
    coreutils: doc.scalar("coreutils"), init: doc.scalar("init"),
    tlsLibrary: doc.scalar("tls_library"),
    packageRoots: doc.list("package_roots"),
    extraPackages: doc.list("extra_packages"))
  validateProfile(result.profile)
  if result.profile.packageRoots.len == 0:
    result.profile.packageRoots = resolvedPackageRoots(result.profile)
  finalizeProfile(result.profile)
  if result.buildDirectory.len == 0:
    raise newException(ValueError, path & ": build_directory must not be empty")
