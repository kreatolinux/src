const kpkgTempDir1* = "/opt/kpkg"
const kpkgTempDir2* = "/tmp/kpkg"
const kpkgCacheDir* = "/var/cache/kpkg"
const kpkgInstalledDir* = kpkgCacheDir&"/installed"
const kpkgArchivesDir* = kpkgCacheDir&"/archives"
const kpkgSourcesDir* = kpkgCacheDir&"/sources"
const kpkgEnvPath* = kpkgCacheDir&"/env"
const kpkgOverlayPath* = kpkgTempDir1&"/overlay"
const kpkgMergedPath* = kpkgTempDir1&"/merged"
const kpkgDbPath* = kpkgCacheDir&"/kpkg.sqlite"
