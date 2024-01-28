import unicode
import nimcrypto/sha2
import nimcrypto/blake2

const bufferLength = 8192

proc getSumSha2(hash: var Sha2Context, f: File) =
    hash.init()
    var buffer = newString(bufferLength)

    while true:
        let length = readChars(f, buffer)
        if length == 0:
            break
        buffer.setLen(length)
        hash.update(buffer)
        if length != bufferLength:
            break
    close(f)


proc getSumBlake2(hash: var Blake2Context, f: File) =
    hash.init()
    var buffer = newString(bufferLength)

    while true:
        let length = readChars(f, buffer)
        if length == 0:
            break
        buffer.setLen(length)
        hash.update(buffer)
        if length != bufferLength:
            break
    close(f)


proc getSum*(file: string, sumType = "sha256"): string =
    ## Gets sum of a file, and returns it.
    let f = open(file)
    case sumType:
        of "sha256":
            var hash: sha256
            getSumSha2(hash, f)
            return ($hash.finish()).toLower()
        of "sha512":
            var hash: sha512
            getSumSha2(hash, f)
            return ($hash.finish()).toLower()
        of "blake2", "blake2_512", "b2":
            var hash: blake2_512
            getSumBlake2(hash, f)
            return ($hash.finish()).toLower()
