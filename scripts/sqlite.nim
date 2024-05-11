import std/os
import ../kpkg/modules/commonPaths
import ../kpkg/modules/logger
import ../kpkg/modules/runparser
import std/strutils
import norm/[model, sqlite]

type
    Package* = ref object of Model
        name*: string
        version*: string
        release*: string
        epoch*: string
        deps*: string
        bdeps*: string
        manualInstall*: bool
        isGroup*: bool
        backup*: string
        replaces*: string
        desc*: string
        basePackage*: bool

    File* = ref object of Model
        path*: string
        blake2Checksum*: string
        package*: Package


createDir(kpkgDbPath.parentDir())

var firstTime = false

if not fileExists(kpkgDbPath):
    firstTime = true

var kpkgDb = open(kpkgDbPath, "", "", "")

func newPackageInternal(name = "", version = "", deps = "", bdeps = "", backup = "", replaces = "", desc = "", release = "", epoch = "", manualInstall = false, isGroup = false): Package =
    # Initializes a new Package.
    Package(name: name, version: version, release: release, epoch: epoch, deps: deps, bdeps: bdeps, manualInstall: manualInstall, isGroup: isGroup, backup: backup, replaces: replaces, desc: desc)

func newFileInternal(path = "", checksum = "", package = newPackageInternal()): File =
    # Initializes a new Package.
    File(path: path, blake2Checksum: checksum, package: package)

if firstTime:
    kpkgDb.createTables(newFileInternal())
    

proc newPackage*(name, version, release, epoch, deps, bdeps, backup, replaces, desc: string, manualInstall, isGroup: bool): Package =
    # Initialize a new Package (wrapper)
    debug "newPackage ran"
    var res = newPackageInternal(name, version, deps, bdeps, backup, replaces, desc, release, epoch, manualInstall, isGroup)
    kpkgDb.insert(res)
    return res

proc newFile*(path, checksum: string, package: Package) =
    # Initialize a File (wrapper)
    var res = newFileInternal(path, checksum, package)
    kpkgDb.insert(res)

proc rootCheck(root: string) =
    # Root checks (internal)
    if root != "/":
        var firstTime = false
        if not fileExists(root&"/"&kpkgDbPath):
            firstTime = true

        kpkgDb = open(root&"/"&kpkgDbPath, "", "", "")

        if firstTime:
            kpkgDb.createTables(newFileInternal())

proc pkgSumstoSQL*(file: string, package: Package) =
    # Converts pkgSums.ini into SQL
    for line in lines file:
        let splittedLine = line.split("=")
        if splittedLine.len != 2:
            newFile(splittedLine[0], "", package)
        else:
            newFile(splittedLine[0], splittedLine[1], package)

proc getPackage*(name: string, root: string): Package =
    # Gets Package from package name.
    rootCheck(root)

    var package = newPackageInternal()
    kpkgDb.select(package, "name = ?", name)
    return package


proc rmPackage*(name: string, root: string) =
    # Remove a package from the database.
    try:
        var package = getPackage(name, root)

        var file = @[newFileInternal()]
        kpkgDb.select(file, "package = ?", package)
    
        kpkgDb.delete(package)
        kpkgDb.delete(file)
    except NotFoundError:
        discard

proc packageExists*(name: string, root = "/"): bool =
    # Check if a package exists in the database.
    rootCheck(root)

    try:
        return kpkgDb.exists(Package, "name = ?", name)
    except:
        return false

proc getListPackages*(root = "/"): seq[string] =
    # Returns a list of packages.
    
    rootCheck(root)
    
    var packages = @[newPackageInternal()]
    kpkgDb.selectAll(packages)
    
    var packageList: seq[string]

    # feels wrong for some reason, hmu if theres a better way -kreatoo
    for p in packages:
        packageList = packageList&p.name    
    
    return packageList

proc isReplaced*(name: string, root = "/"): bool =
    # Checks if a package is "replaced" or not.
    rootCheck(root)
    
    # feels wrong for some reason, hmu if theres a better way -kreatoo
    var packages = @[newPackageInternal()]
    kpkgDb.selectAll(packages)
    
    for package in packages:
        if name in package.replaces.split("!!k!!"):
            return true

    return false



proc getListFiles*(packageName: string, root: string): seq[string] =
    # Gives a list of files.
    # comparable to list_files in kpkg <v6.
    
    rootCheck(root)
    
    var package = getPackage(packageName, root)

    var files = @[newFileInternal()]
    kpkgDb.select(files, "package = ?", package)
    
    var listFiles: seq[string]
    
    for file in files:
        listFiles = listFiles&file.path.replace("\"", "")
    
    return listFiles

for i in walkDirs("/var/cache/kpkg/installed/*"):
    echo i
    let runf = parseRunfile(i)
    let pkg =  newPackage(lastPathPart(i), runf.versionString, runf.release, runf.epoch, runf.deps.join("!!k!!"), runf.bdeps.join("!!k!!"), runf.backup.join("!!k!!"), runf.replaces.join("!!k!!"), runf.desc, true, runf.isGroup)
    for line in lines i&"/list_files":
        let lineSplit = line.split("=")
        if lineSplit.len == 2:
            newFile(lineSplit[0], lineSplit[1], pkg)
        else:
            newFile(lineSplit[0], "", pkg)
