import std/[os, posix, strutils, unittest]
import jumpstartcore/[errors, jsonlines, protocol]

proc makePipe(): tuple[reader, writer: cint] =
  var fds: array[2, cint]
  doAssert pipe(fds) == 0
  (fds[0], fds[1])

suite "jsonlines":
  test "writeAllFd and readLineFd round trip one line at a time":
    let (r, w) = makePipe()
    writeAllFd(w, "{\"a\":1}\n{\"b\":2}\n")
    check readLineFd(r) == "{\"a\":1}\n"
    check readLineFd(r) == "{\"b\":2}\n"
    discard close(w)
    expect ProtocolError: discard readLineFd(r)
    discard close(r)

  test "readLineFd returns an unterminated final line at EOF":
    let (r, w) = makePipe()
    writeAllFd(w, "tail")
    discard close(w)
    check readLineFd(r) == "tail"
    discard close(r)

  test "readLineFd rejects lines over the limit":
    let (r, w) = makePipe()
    writeAllFd(w, repeat('x', 40) & "\n")
    expect ProtocolError: discard readLineFd(r, 16)
    discard close(w); discard close(r)

  test "LineReader splits fed bytes into lines":
    let reader = newLineReader(-1)
    var line: string
    check not reader.nextLine(line)
    reader.feed("one\ntw")
    check reader.nextLine(line)
    check line == "one\n"
    check not reader.nextLine(line)
    reader.feed("o\nthree\n")
    check reader.nextLine(line) and line == "two\n"
    check reader.nextLine(line) and line == "three\n"
    check not reader.nextLine(line)

  test "LineReader enforces the line limit without a newline":
    let reader = newLineReader(-1, 8)
    var line: string
    reader.feed("123456789012")
    expect ProtocolError: discard reader.nextLine(line)

  test "LineReader fill honours timeouts and reports EOF":
    let (r, w) = makePipe()
    let reader = newLineReader(r)
    var line: string
    check not reader.fill(0)
    check not reader.eof
    writeAllFd(w, "a\nb\n")
    check reader.fill(1000)
    check reader.readLine(line) and line == "a\n"
    check reader.readLine(line) and line == "b\n"
    writeAllFd(w, "partial")
    discard close(w)
    check reader.readLine(line) and line == "partial"
    check not reader.readLine(line)
    check reader.eof
    discard close(r)

  test "a protocol message survives the transport":
    let (r, w) = makePipe()
    writeAllFd(w, encodeLine(cancel("abc")))
    let reader = newLineReader(r)
    var line: string
    check reader.readLine(line)
    check parseLine(line).kind == pmCancel
    discard close(w); discard close(r)
