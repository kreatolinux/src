version = "3.0.0"
author = "Kreato"
description = "Efficient package manager"
license = "GPLv3"
srcDir = "src"
bin = @["nyaa"]
binDir = "out/"

requires "nim"
requires "cligen"
requires "libsha"

task prettify, "Run nimpretty":
  exec "nimpretty "&srcDir&"/*/*/*"

task ssl, "Build with SSL support":
  exec "nim c -d:release -d:ssl -o="&binDir&" "&srcDir&"/nyaa.nim"

task flto, "Build with -flto and SSL support, also optimizes for speed":
  exec "nim c -d:release -d:ssl --passC:-flto --passL:-flto --opt:speed -o="&binDir&" "&srcDir&"/nyaa.nim"

