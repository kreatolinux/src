## Blocking JSON-lines transport primitives for the exec protocol's
## descriptors (jumpstart-cores §17.1): one UTF-8 JSON object per line, at most
## 1 MiB per line.
##
## These helpers only move lines. Parsing and building messages is
## `protocol.nim`; the adapter side of the conversation is `adapterloop.nim`.
## `LineReader` is pure apart from `fill`, so an event loop that owns its
## descriptor can `feed` it bytes it read itself.
import std/[os, posix, strutils]
import ./[errors, protocol]

type
  LineReader* = ref object
    fd*: cint
    limit: int
    buffer: string
    pos: int
    eof*: bool
      ## Set once a read returned 0 bytes. Buffered data may still remain.

proc protocolFailure(message: string) {.noreturn.} =
  var e = newException(ProtocolError, message)
  e.code = ecProtocol
  e.message = message
  raise e

proc writeAllFd*(fd: cint; data: string) =
  ## Write all of `data`, retrying on `EINTR`. Raises `OSError` otherwise.
  var offset = 0
  while offset < data.len:
    let count = posix.write(fd, unsafeAddr data[offset], data.len - offset)
    if count > 0: offset += int(count)
    elif count < 0 and osLastError() == OSErrorCode(EINTR): discard
    else: raiseOSError(osLastError())

proc readLineFd*(fd: cint; limit = MaxProtocolLineBytes): string =
  ## Read one line, including its `\n`, one byte at a time so that nothing
  ## beyond the line is consumed. At EOF a final unterminated line is returned;
  ## EOF with no data raises `ProtocolError`.
  var ch: char
  while true:
    let count = posix.read(fd, addr ch, 1)
    if count == 1:
      result.add(ch)
      if result.len > limit + 1: protocolFailure("protocol line exceeds 1 MiB")
      if ch == '\n': return
    elif count == 0:
      if result.len == 0: protocolFailure("unexpected protocol EOF")
      return
    elif osLastError() != OSErrorCode(EINTR):
      raiseOSError(osLastError())

proc newLineReader*(fd: cint; limit = MaxProtocolLineBytes): LineReader =
  LineReader(fd: fd, limit: limit)

proc compact(reader: LineReader) =
  if reader.pos > 0:
    reader.buffer = reader.buffer[reader.pos .. ^1]
    reader.pos = 0

proc feed*(reader: LineReader; data: string) =
  ## Append bytes that were read elsewhere.
  reader.compact()
  reader.buffer.add data

proc nextLine*(reader: LineReader; line: var string): bool =
  ## Remove one complete buffered line (with its `\n`) into `line`. Raises
  ## `ProtocolError` when more than `limit` bytes are buffered without a
  ## newline.
  let newline = reader.buffer.find('\n', reader.pos)
  if newline < 0:
    if reader.buffer.len - reader.pos > reader.limit + 1:
      protocolFailure("protocol line exceeds 1 MiB")
    return false
  line = reader.buffer[reader.pos .. newline]
  reader.pos = newline + 1
  if reader.pos == reader.buffer.len:
    reader.buffer.setLen(0)
    reader.pos = 0
  true

proc fill*(reader: LineReader; timeoutMs = -1): bool =
  ## Wait up to `timeoutMs` (negative: forever, 0: only look) for the
  ## descriptor to become readable and read what is available. True when bytes
  ## were buffered; false on timeout or EOF (see `eof`).
  if reader.eof: return false
  var pfd = TPollfd(fd: reader.fd, events: POLLIN)
  while true:
    let ready = poll(addr pfd, 1, cint(timeoutMs))
    if ready > 0: break
    if ready == 0: return false
    if osLastError() != OSErrorCode(EINTR): raiseOSError(osLastError())
  var chunk: array[65536, char]
  while true:
    let count = posix.read(reader.fd, addr chunk[0], chunk.len)
    if count > 0:
      reader.compact()
      let start = reader.buffer.len
      reader.buffer.setLen(start + int(count))
      copyMem(addr reader.buffer[start], addr chunk[0], int(count))
      return true
    if count == 0:
      reader.eof = true
      return false
    if osLastError() != OSErrorCode(EINTR): raiseOSError(osLastError())

proc readLine*(reader: LineReader; line: var string): bool =
  ## Blocking read of the next line. False at EOF when nothing is left; an
  ## unterminated final line is returned as a line.
  while true:
    if reader.nextLine(line): return true
    if reader.eof:
      if reader.pos >= reader.buffer.len: return false
      line = reader.buffer[reader.pos .. ^1]
      reader.buffer.setLen(0)
      reader.pos = 0
      return true
    discard reader.fill(-1)
