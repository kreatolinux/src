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
        desc*: string

    File* = ref object of Model
        path*: string
        blake2Checksum*: string
        package*: Package

    Replace* = ref object of Model
        first*: Package
        second*: Package


createDir(kpkgDbPath.parentDir())

var firstTime = false

if not fileExists(kpkgDbPath):
    firstTime = true

var kpkgDb = open(kpkgDbPath, "", "", "")

func newPackageInternal(name = "", version = "", deps = "", bdeps = "", backup = "", replaces = "", desc = "", manualInstall = false, isGroup = false): Package =
    # Initializes a new Package.
    Package(name: name, version: version, deps: deps, bdeps: bdeps, manualInstall: manualInstall, isGroup: isGroup, backup: backup, replaces: replaces, desc: desc)

func newFileInternal(path = "", checksum = "", package = newPackageInternal()): File =
    # Initializes a new File.
    File(path: path, blake2Checksum: checksum, package: package)

func newReplaceInternal(first = newPackageInternal(), second = newPackageInternal()): Replace =
    # Initializes a new Replace.
    Replace(first: first, second: second)

if firstTime:
    kpkgDb.createTables(newFileInternal())
    kpkgDb.createTables(newReplaceInternal())

proc newPackage*(name, version, deps, bdeps, backup, replaces, desc: string, manualInstall, isGroup: bool): Package =
    # Initialize a new Package (wrapper)
    debug "newPackage ran"
    var res = newPackageInternal(name, version, deps, bdeps, backup, replaces, desc, manualInstall, isGroup)
    kpkgDb.insert(res)
    return res

proc newReplace(first, second: Package) =
    # Initialize a new Replace (wrapper)
    var res = newReplaceInternal(first, second)
    kpkgDb.insert(res)

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

proc getPackage*(name: string, root: string): Package =
    # Gets Package from package name.
    if root != "/":
        kpkgDb = open(root&"/"&kpkgDbPath, "", "", "")

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
    if root != "/":
        kpkgDb = open(root&"/"&kpkgDbPath, "", "", "")

    return kpkgDb.exists(Package, "name = ?", name)

proc getListPackages*(root = "/"): seq[string] =
    # Returns a list of packages.
    
    if root != "/":
        kpkgDb = open(root&"/"&kpkgDbPath, "", "", "")
    
    var packages = @[newPackageInternal()]
    kpkgDb.selectAll(packages)
    
    var packageList: seq[string]

    # feels wrong for some reason, hmu if theres a better way -kreatoo
    for p in packages:
        packageList = packageList&p.name    
    
    return packageList

proc isReplace*(name: string, root: string): bool =
    # Checks if a package is a Replace.
    # Returns false if package doesn't exist.
    
    if not packageExists(name, root):
        return false

    var package = getPackage(name, root)
    
    return kpkgDb.exists(Replace, "first = ?", package)

proc getListFiles*(packageName: string, root: string): seq[string] =
    # Gives a list of files.
    # comparable to list_files in kpkg <v6.
    
    if root != "/":
        kpkgDb = open(root&"/"&kpkgDbPath, "", "", "")
    
    var package = getPackage(packageName, root)

    var files = @[newFileInternal()]
    kpkgDb.select(files, "package = ?", package)
    
    var listFiles: seq[string]
    
    for file in files:
        listFiles = listFiles&file.path.replace("\"", "")
    
    return listFiles
