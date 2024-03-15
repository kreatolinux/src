import std/os
import commonPaths
import logger
import std/strutils
import norm/[model, sqlite]

type
    Package* = ref object of Model
        name*: string
        version*: string
        deps*: string
        bdeps*: string
        manualInstall*: bool
        isGroup*: bool
        backup*: string
        replaces*: string

    File* = ref object of Model
        path*: string
        blake2Checksum*: string
        package*: Package


createDir(kpkgDbPath.parentDir())

var firstTime = false

if not fileExists(kpkgDbPath):
    firstTime = true

let kpkgDb = open(kpkgDbPath, "", "", "")

func newPackageInternal(name = "", version = "", deps = "", bdeps = "", backup = "", replaces = "", manualInstall = false, isGroup = false): Package =
    # Initializes a new Package.
    Package(name: name, version: version, deps: deps, bdeps: bdeps, manualInstall: manualInstall, isGroup: isGroup, backup: backup, replaces: replaces)

func newFileInternal(path = "", checksum = "", package = newPackageInternal()): File =
    # Initializes a new Package.
    File(path: path, blake2Checksum: checksum, package: package)

if firstTime:
    kpkgDb.createTables(newFileInternal())
    

proc newPackage*(name, version, deps, bdeps, backup, replaces: string, manualInstall, isGroup: bool): Package =
    # Initialize a new Package (wrapper)
    debug "newPackage ran"
    var res = newPackageInternal(name, version, deps, bdeps, backup, replaces, manualInstall, isGroup)
    kpkgDb.insert(res)
    return res

proc newFile*(path, checksum: string, package: Package) =
    # Initialize a File (wrapper)
    var res = newFileInternal(path, checksum, package)
    kpkgDb.insert(res)

proc pkgSumstoSQL*(file: string, package: Package) =
    # Converts pkgSums.ini into SQL
    for line in lines file:
        let splittedLine = line.split("=")
        if splittedLine.len != 2:
            newFile(splittedLine[0], "", package)
        else:
            newFile(splittedLine[0], splittedLine[1], package)

proc getPackage*(name: string): Package =
    # Gets Package from package name.
    var package = newPackageInternal()
    kpkgDb.select(package, "name = ?", name)
    return package


proc rmPackage*(name: string) =
    # Remove a package from the database.
    try:
        var package = getPackage(name)

        var file = @[newFileInternal()]
        kpkgDb.select(file, "package = ?", package)
    
        kpkgDb.delete(package)
        kpkgDb.delete(file)
    except NotFoundError:
        discard

proc packageExists*(name: string): bool =
    # Check if a package exists in the database.
    try:
        discard getPackage(name)
        return true
    except:
        return false

proc getListFiles*(packageName: string): seq[string] =
    # Gives a list of files.
    # comparable to list_files in kpkg <v6.
    
    var package = getPackage(packageName)

    var files = @[newFileInternal()]
    kpkgDb.select(files, "package = ?", package)
    
    var listFiles: seq[string]
    
    for file in files:
        listFiles = listFiles&file.path.replace("\"", "")
    
    return listFiles
