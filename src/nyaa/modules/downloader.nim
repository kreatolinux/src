import std/[asyncdispatch, httpclient]
import terminal, math

proc onProgressChanged(total, progress, speed: BiggestInt) {.async.} =
  stdout.eraseLine
  stdout.write("Downloaded ", formatSize(progress), " of ", formatSize(total), " at ", formatSize(speed), "/s ", round(int(progress) / int(total)*100),"% complete")
  stdout.flushFile

proc download(url: string, file: string) {.async.} =
  var client = newAsyncHttpClient()
  client.onProgressChanged = onProgressChanged
  await client.downloadFile(url, file)
  echo ""
