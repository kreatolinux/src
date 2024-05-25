const commitVer* = staticExec("git rev-parse --short HEAD 2> /dev/null || echo 'unavailable'")
const ver* {.strdefine.}: string = "v7.2"
