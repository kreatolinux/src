import std/[asyncdispatch, httpclient]
import terminal, math, strutils

proc onProgressChanged(total, progress, speed: BiggestInt) {.async.} =
  stdout.eraseLine
  var p = "Downloaded "&formatSize(progress)&" of "&formatSize(
      total)&" at "&formatSize(speed)&"/s"

  if $round(int(progress) / int(total)*100) != "inf":
    p = p&" "&formatBiggestFloat(round(int(progress) / int(total)*100), precision = -1)&"% complete"

  stdout.write(p)
  stdout.flushFile

proc download*(url: string, file: string) {.async.} =
  var client = newAsyncHttpClient()
  client.onProgressChanged = onProgressChanged
  await client.downloadFile(url, file)
  echo ""
