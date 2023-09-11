import std/httpclient
import terminal, math, strutils, os, logger

proc onProgressChanged(total, progress, speed: BiggestInt) =
  stdout.eraseLine
  var p = "Downloaded "&formatSize(progress)
  if formatSize(total) != "0B":
    p = p&" of "&formatSize(total)

  p = p&" at "&formatSize(speed)&"/s"

  if $round(int(progress) / int(total)*100) != "inf":
    p = p&" "&formatBiggestFloat(round(int(progress) / int(total)*100),
        precision = -1)&"% complete"

  stdout.write(p)
  stdout.flushFile

proc download*(url: string, file: string, instantErrorIfFail = false) =
  try:
    var client = newHttpClient()
    client.onProgressChanged = onProgressChanged
    client.downloadFile(url, file&".partial")
    moveFile(file&".partial", file)
    echo ""
  except Exception:
    if instantErrorIfFail:
      err "download failed"
    warn "download failed, retrying"
    download(url, file, true)
