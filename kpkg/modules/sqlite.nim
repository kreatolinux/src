import std/os
import commonPaths
import logger
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


var kpkgDb: DbConn
var connOn = false


func newPackageInternal(name = "", version = "", deps = "", bdeps = "", backup = "", replaces = "", desc = "", release = "", epoch = "", manualInstall = false, isGroup = false, basePackage = false): Package =
    # Initializes a new Package.
    Package(name: name, version: version, release: release, epoch: epoch, deps: deps, bdeps: bdeps, manualInstall: manualInstall, isGroup: isGroup, backup: backup, replaces: replaces, desc: desc, basePackage: basePackage)

func newFileInternal(path = "", checksum = "", package = newPackageInternal()): File =
    # Initializes a new Package.
    File(path: path, blake2Checksum: checksum, package: package)

proc closeDb*() =
    # Wrapper for close.
    if connOn:
        close kpkgDb
        connOn = false

proc rootCheck(root: string) =
    # Root checks (internal)
    closeDb()
    var firstTime = false
    
    if not fileExists(root&"/"&kpkgDbPath):
        createDir(kpkgLibDir)
        firstTime = true
    
    kpkgDb = open(root&"/"&kpkgDbPath, "", "", "")
    connOn = true

    if firstTime:
        kpkgDb.createTables(newFileInternal())



proc getFileByValue*(file = newFileInternal(), field = ""): string =
    # Get a file field by value.
    # usage: getPackageByValue(package, "name")

    # thanks to getchoo to make me not yanderedev this shit
    result = "File("&file.path&"):"
    for fieldName, value in file[].fieldPairs:
        if isEmptyOrWhitespace(field):
            when value is bool:
                result.add("\n\t" & fieldName & " is " & $value)
            elif value is Package:
                result.add("\n\t" & fieldName & " is Package(" & value.name & ")")
            else:
                if fieldName == "blake2Checksum":
                    # Add an alias
                    result.add("\n\t" & "blake2Checksum | b2Sum" & " '" & $value & "'")
                else:
                    result.add("\n\t" & fieldName & " '" & $value & "'")
        elif field == fieldName or (fieldName == "blake2Checksum" and field == "b2Sum"):
            when value is Package:
                return("\n\t" & fieldName & " is Package(" & value.name & ")")
            else:
                return $value

proc getFileByValueAll*(root: string, field = "") =
    # Return getPackageByValue for all packages.
    rootCheck(root)
    
    var files = @[newFileInternal()]
    kpkgDb.selectAll(files)
    
    for f in files:
        echo getFileByValue(f, field)&"\n"
    
proc newPackage*(name, version, release, epoch, deps, bdeps, backup, replaces, desc: string, manualInstall, isGroup, basePackage: bool, root: string): Package =
    # Initialize a new Package (wrapper)
    rootCheck(root)
    debug "newPackage ran"
    var res = newPackageInternal(name, version, deps, bdeps, backup, replaces, desc, release, epoch, manualInstall, isGroup, basePackage)
    kpkgDb.insert(res)
    return res

proc newFile*(path, checksum: string, package: Package, root: string) =
    # Initialize a File (wrapper)
    rootCheck(root)
    var res = newFileInternal(path, checksum, package)
    kpkgDb.insert(res)

proc pkgSumstoSQL*(file: string, package: Package, root: string) =
    # Converts pkgSums.ini into SQL
    for line in lines file:
        let splittedLine = line.split("=")
        if splittedLine.len != 2:
            newFile(splittedLine[0], "", package, root)
        else:
            newFile(splittedLine[0], splittedLine[1], package, root)

proc isReplaced*(name: string, root = "/"): tuple[replaced: bool, package: Package] =
    # Checks if a package is "replaced" or not.
    rootCheck(root)
    
    # feels wrong for some reason, hmu if theres a better way -kreatoo
    var packages = @[newPackageInternal()]
    kpkgDb.selectAll(packages)
     
    for package in packages:
        if name in package.replaces.split("!!k!!"):
            return (true, package)
    
    return (false, newPackageInternal())

proc packageExists*(name: string, root = "/"): bool =
    # Check if a package exists in the database.
    rootCheck(root)

    try:
        if isReplaced(name, root).replaced:
            return true
        else:
            let res = kpkgDb.exists(Package, "name = ?", name)
            return res
    except:
        return false

proc getPackage*(name: string, root: string): Package =
    # Gets Package from package name.
    rootCheck(root)

    debug "getPackage ran, name: '"&name&"', root: '"&root&"'"
    
    if not packageExists(name, root):
        err("internal: package '"&name&"' doesn't exist at '"&root&"', but attempted to getPackage anyway", false)

    var package = newPackageInternal()
    
    package = isReplaced(name, root).package

    if isEmptyOrWhitespace(package.name):
        kpkgDb.select(package, "name = ?", name)

    return package

proc getFile*(path: string, root: string): File =
    # Gets File from path.
    rootCheck(root)

    debug "getFile ran, path: '"&path&"', root: '"&root&"'"
    
    #if not packageExists(name, root):
    #    err("internal: package '"&name&"' doesn't exist at '"&root&"', but attempted to getPackage anyway", false)

    var file = newFileInternal()
    
    kpkgDb.select(file, "path = ?", "\""&path&"\"")

    return file

proc getFilesPackage*(package: Package, root: string): seq[File] =
    # Gets all File types from a package.
    # Recommended way to get the list of files from a package.
    rootCheck(root)

    var files = @[newFileInternal()]
    kpkgDb.select(files, "package = ?", package)
    
    return files


proc rmPackage*(name: string, root: string) =
    # Remove a package from the database.
    rootCheck(root)
    try:
        var package = getPackage(name, root)

        var file = @[newFileInternal()]
        kpkgDb.select(file, "package = ?", package)
    
        kpkgDb.delete(package)
        kpkgDb.delete(file)
    except NotFoundError:
        discard
    

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

proc getListPackagesType*(root = "/"): seq[Package] =
    # Returns a list of packages.
    # Similar to getListPackages, but returns a seq[Package] instead.
    
    rootCheck(root)
    
    var packages = @[newPackageInternal()]
    kpkgDb.selectAll(packages)
    
    return packages

proc newPackageFromRoot*(root, package, destdir: string) =
    # Gets package from root, and adds it to destdir.
    rootCheck(root)

    var og = getPackage(package, root)
     
    rootCheck(destdir)
    
    var res = newPackageInternal(og.name, og.version, og.deps, og.bdeps, og.backup, og.replaces, og.desc, og.release, og.epoch, og.manualInstall, og.isGroup)
    
    kpkgDb.insert(res)

proc getListFiles*(packageName: string, root: string, package = getPackage(packageName, root)): seq[string] =
    # Gives a list of files.
    # comparable to list_files in kpkg <v6.
    
    rootCheck(root)

    var files = @[newFileInternal()]
    kpkgDb.select(files, "package = ?", package)
    
    var listFiles: seq[string]
    
    for file in files:
        listFiles = listFiles&file.path.replace("\"", "")
    
    return listFiles

proc getPackageByValue*(package = newPackageInternal(), field = ""): string =
    # Get a package field by value.
    # usage: getPackageByValue(package, "name")
    
    if field == "listFiles":
        return getListFiles(package.name, "/", package).join("\n")

    # thanks to getchoo to make me not yanderedev this shit
    result = "Package("&package.name&"):"
    for fieldName, value in package[].fieldPairs:
        if isEmptyOrWhitespace(field):
            when value is bool:
                result.add("\n\t" & fieldName & " is " & $value)
            else:
                result.add("\n\t" & fieldName & " '" & $value & "'")
        elif field == fieldName:
            return $value
    result.add("\n\tlistFiles listFiles("&package.name&")")

proc getPackageByValueAll*(root: string, field = "") =
    # Return getPackageByValue for all packages.
    rootCheck(root)
    
    var packages = @[newPackageInternal()]
    kpkgDb.selectAll(packages)
    
    for f in packages:
        echo getPackageByValue(f, field)&"\n"
