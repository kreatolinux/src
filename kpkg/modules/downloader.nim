import std/httpclient
import std/typedthreads
import std/locks
import terminal, math, strutils, os, times, ../../common/logging

proc onProgressChanged(total, progress, speed: BiggestInt) =
  stdout.eraseLine
  var p = "Downloaded "&formatSize(progress)

  if formatSize(total) != "0B":
    p = p&" of "&formatSize(total)

  p = p&" at "&formatSize(speed)&"/s"

  if $round(int(progress) / int(total)*100) != "inf":
    let percent = parseInt(formatBiggestFloat(round(int(progress) / int(
        total)*100), precision = -1))
    let perc = int(percent / 2)

    stdout.styledWriteLine(formatSize(total), "    ", fgWhite, "[", '-'.repeat (
        if perc >= 1: perc - 1 else: perc), ">", " ".repeat 50 - perc, "]",
        if percent > 50: fgGreen else: fgYellow, "    ", $percent, "% at ",
        formatSize(speed)&"/s")
    if percent != 100:
      cursorUp 1
    eraseLine()
  else:
    stdout.write(p)
    stdout.flushFile

proc download*(url: string, file: string, instantErrorIfFail = false,
    raiseWhenFail = false) =
  debug "downloader ran, attempting to download file from '"&url&"' to '"&file&"'"
  try:
    var client = newHttpClient()
    client.headers = newHttpHeaders({"Accept": "*/*"})
    client.onProgressChanged = onProgressChanged
    client.downloadFile(url, file&".partial")
    moveFile(file&".partial", file)
    echo ""
  except Exception:
    if instantErrorIfFail:
      if raiseWhenFail or not defined(release):
        raise getCurrentException()
      else:
        debug $(getCurrentException().getStackTrace())
        fatal "download failed"
    warn "download failed, retrying"
    debug $(getCurrentException().getStackTrace())
    download(url, file, true, raiseWhenFail)

# ---------------------- Parallel download support ---------------------------
# Fan-out download helper used by the install command. Downloads run on
# worker threads, each with its own keep-alive HTTP client. Files are written
# to a temp name next to the destination and atomically renamed into place,
# so concurrent operations never observe a half-written tarball.
#
# Progress is rendered as a compact multi-line table (one line per active
# download) by the main thread, so parallel output stays readable.

type
  DownloadJob* = object
    label*: string      # Short display name (usually the package name)
    urls*: seq[string]  # Full URLs to try in order (first success wins)
    destPath*: string   # Final path on disk
    idx*: int           # Internal: index in the submitted batch
    displayIdx*: int    # Progress row (may differ in a combined operation)
    ok*: bool
    errorMsg*: string

  ProgressMsg = object
    jobIdx: int
    displayIdx: int
    percent: int
    totalBytes: int64
    progressBytes: int64
    speedBps: int64
    started: bool
    finished: bool
    ok: bool

var
  workChan: Channel[DownloadJob]
  progressChan: Channel[ProgressMsg]
  statusLock: Lock
  latestStatus: seq[tuple[percent: int, speed: string, active: bool,
      finished: bool, ok: bool]]

initLock(statusLock)

# Number of lines currently drawn by renderProgress. Main-thread only.
var lastRenderedLines = 0
var progressTitle = "Progress"
var progressLabels: seq[string]

proc moveProgressTop() =
  if lastRenderedLines > 1:
    stdout.write("\27[" & $(lastRenderedLines - 1) & "A")
  stdout.write("\27[1G")

proc eraseRendered() =
  ## Erase the complete rendered block using absolute ANSI cursor movement.
  ## Unlike cursorDown/cursorUp, this remains correct when lines wrap.
  if lastRenderedLines == 0:
    return
  moveProgressTop()
  for i in 0 ..< lastRenderedLines:
    stdout.write("\27[2K")
    if i + 1 < lastRenderedLines:
      stdout.write("\27[1B\27[1G")
  moveProgressTop()
  lastRenderedLines = 0

proc renderProgress() =
  ## Render a readable multi-line status table on TTYs.
  if not stdout.isatty():
    return

  acquire(statusLock)
  var statuses = latestStatus
  release(statusLock)

  var completed = 0
  for status in statuses:
    if status.finished:
      inc completed

  var lines: seq[string] = @[]
  let hasHeader = progressTitle.len > 0
  if hasHeader:
    lines.add(progressTitle & " " & $completed & "/" & $progressLabels.len)
  for i, status in statuses:
    var label = progressLabels[i]
    if label.len > 20:
      label = label[0 ..< 19] & "…"
    while label.len < 20:
      label.add(" ")
    let width = 26
    let filled = max(0, min(width, status.percent * width div 100))
    let bar = "━".repeat(filled) & "─".repeat(width - filled)
    let marker = if status.finished: (if status.ok: "✓" else: "✗") else: "•"
    let percent = if status.speed == "queued": "--%"
                  else: $status.percent & "%"
    let speed = if status.finished:
                  (if status.speed.len > 0: status.speed
                   elif status.ok: "done" else: "failed")
                elif status.speed.len > 0: status.speed
                else: "waiting"
    lines.add(marker & " " & label & "  " & bar & "  " & percent & "  " & speed)

  eraseRendered()
  for i, line in lines:
    if i > 0:
      stdout.write("\n")
    let statusIndex = if hasHeader: i - 1 else: i
    let color = if hasHeader and i == 0: fgCyan
                elif statuses[statusIndex].finished:
                  (if statuses[statusIndex].ok: fgGreen else: fgRed)
                else: fgWhite
    stdout.styledWrite(color, line)
    stdout.flushFile()
  lastRenderedLines = lines.len

proc clearProgress() =
  ## Finish the display without erasing the completed table. Keeping the
  ## final rows visible makes download/install progress useful as history.
  if lastRenderedLines > 0:
    stdout.write("\n")
    lastRenderedLines = 0
  stdout.flushFile()


proc progressBegin*(labels: seq[string], title = "Progress") =
  ## Start a reusable multi-line progress display for non-download work.
  progressTitle = title
  progressLabels = labels
  acquire(statusLock)
  latestStatus = @[]
  for _ in labels:
    latestStatus.add((percent: 0, speed: "queued", active: true,
        finished: false, ok: false))
  release(statusLock)

proc progressUpdate*(idx, percent: int, finished = false, ok = true,
        detail = "") =
  ## Update one row of the reusable progress display.
  acquire(statusLock)
  if idx >= 0 and idx < latestStatus.len:
    latestStatus[idx].percent = max(0, min(100, percent))
    latestStatus[idx].finished = finished
    latestStatus[idx].active = not finished
    latestStatus[idx].ok = ok
    if detail.len > 0:
      latestStatus[idx].speed = detail
  release(statusLock)

proc progressRender*() =
  renderProgress()

proc progressFinish*() =
  clearProgress()

proc downloadWithResume(client: HttpClient, url, tmpPath: string) =
  ## Downloads `url` to `tmpPath`, resuming from an existing `.partial` file
  ## via an HTTP Range request when the server supports it (206). Falls back
  ## to a full download otherwise.

  var offset: BiggestInt = 0
  if fileExists(tmpPath):
    offset = getFileSize(tmpPath)

  if offset > 0:
    let savedHeaders = client.headers
    client.headers = newHttpHeaders({
      "Accept": "*/*",
      "Range": "bytes=" & $offset & "-"
    })
    var resp: Response
    try:
      resp = client.get(url)
    except CatchableError:
      client.headers = savedHeaders
      # Connection-level failure: let the caller retry (it recreates clients)
      raise
    client.headers = savedHeaders

    if resp.code == Http206:
      debug "downloader: resuming '" & url & "' from byte " & $offset
      let body = resp.body
      var f: File
      if not f.open(tmpPath, fmAppend):
        raise newException(IOError, "cannot open " & tmpPath & " for append")
      try:
        f.write(body)
      finally:
        f.close()
      return

    # Server ignored the Range request (e.g. 200): restart from scratch.
    debug "downloader: server did not honor Range for '" & url & "', restarting"

  client.downloadFile(url, tmpPath)

proc workerThread() {.thread.} =
  {.cast(gcsafe).}:
    var client = newHttpClient(timeout = 300)
    client.headers = newHttpHeaders({"Accept": "*/*"})

    while true:
      let job = workChan.recv()
      if job.destPath == "\x00quit":
        break

      var lastProgress = 0.0
      let jobIdx = job.idx
      discard progressChan.trySend(ProgressMsg(jobIdx: jobIdx,
          displayIdx: job.displayIdx, percent: 0, speedBps: 0,
          started: true, finished: false, ok: false))

      proc onProgress(total, progress, speed: BiggestInt) {.closure.} =
        let now = epochTime()
        if now - lastProgress < 0.1 and progress < total:
          return
        lastProgress = now
        let percent = if total > 0: int(progress * 100 div total) else: 0
        discard progressChan.trySend(ProgressMsg(
          jobIdx: jobIdx, displayIdx: job.displayIdx,
          percent: percent, totalBytes: total, progressBytes: progress,
          speedBps: speed, finished: false, ok: false))

      client.onProgressChanged = onProgress

      let tmpPath = job.destPath & ".partial"
      var success = false

      # Mirror hedging: if a mirror stalls (no bytes for graceSeconds),
      # abandon it early and try the next mirror instead of waiting out the
      # full client timeout. The last available mirror always gets the full
      # timeout since there is nothing to hedge to.
      const graceSeconds = 8

      let urlCount = job.urls.len
      var urlPos = 0

      for url in job.urls:
        inc urlPos
        let perUrlTimeout = if urlPos < urlCount: graceSeconds else: 300
        try:
          client.timeout = perUrlTimeout
        except CatchableError:
          discard

        # Prime Content-Length and the keep-alive TLS connection before GET.
        # This lets the coordinator calculate progress from the growing
        # partial file even when HttpClient callbacks are sparse.
        try:
          let head = client.request(url, HttpHead)
          if head.code.is2xx:
            let lengthValue = head.headers.getOrDefault("content-length")
            if not isEmptyOrWhitespace(lengthValue):
              let expectedBytes = parseBiggestInt(lengthValue)
              discard progressChan.trySend(ProgressMsg(jobIdx: jobIdx,
                  displayIdx: job.displayIdx, percent: 0,
                  totalBytes: expectedBytes, progressBytes: 0,
                  speedBps: 0, started: true, finished: false, ok: false))
        except CatchableError:
          discard

        # One retry per URL: transient timeouts on a loaded mirror are common.
        # Retries resume from the bytes already on disk when the server
        # supports Range requests.
        for attempt in 0 ..< 2:
          debug "downloader: worker downloading '" & url & "' (attempt " & $attempt & ") to '" & tmpPath & "'"
          try:
            downloadWithResume(client, url, tmpPath)
            # Atomic finalize: rename over any existing/identical file
            moveFile(tmpPath, job.destPath)
            success = true
            break
          except CatchableError:
            debug "downloader: worker download failed for '" & url & "': " & getCurrentExceptionMsg()
            # Keep the .partial file: the next attempt resumes via Range.
            # downloadWithResume restarts from scratch if the server
            # ignores Range requests.
            # A failed transfer can leave the keep-alive connection with an
            # unread response body; recreate the client so the next attempt
            # starts from a clean connection.
            try:
              client.close()
            except CatchableError:
              discard
            client = newHttpClient(timeout = 300)
            client.headers = newHttpHeaders({"Accept": "*/*"})
            client.onProgressChanged = onProgress
        if success:
          break

      # Completion is not lossy: the coordinator must receive exactly one
      # terminal event per job or it could wait forever.
      progressChan.send(ProgressMsg(
        jobIdx: jobIdx, displayIdx: job.displayIdx,
        percent: 100, speedBps: 0, finished: true, ok: success))

    client.close()

proc downloadParallel*(jobsIn: seq[DownloadJob], threads = 4,
        manageProgress = true, progressIndices: seq[int] = @[],
        progressStart = 0, progressEnd = 100,
        renderUpdates = true,
        onTick: proc() {.closure.} = nil): seq[DownloadJob] =
  ## Downloads the given jobs on up to `threads` worker threads.
  ## Returns the jobs with `ok` set appropriately. Errors are reported per
  ## job via `errorMsg` and logged; the caller decides how fatal they are.
  result = jobsIn
  if result.len == 0:
    return

  let workerCount = max(1, min(threads, result.len))

  for i in 0 ..< result.len:
    result[i].idx = i
    result[i].displayIdx = if i < progressIndices.len: progressIndices[i] else: i

  if manageProgress:
    var labels: seq[string] = @[]
    for job in result:
      labels.add(job.label)
    progressBegin(labels, "Downloads")

  # Buffered channels: a synchronous channel deadlocks when a worker blocks
  # on progressChan.send while the main thread is still blocked on
  # workChan.send handing out jobs.
  workChan.open(result.len + workerCount + 8)
  progressChan.open(4096)

  var workers = newSeq[Thread[void]](workerCount)
  for i in 0 ..< workerCount:
    createThread(workers[i], workerThread)

  var pending = result.len
  var doneCount = 0
  var knownTotals = newSeq[int64](result.len)
  var observedSizes = newSeq[int64](result.len)
  var observedAt = newSeq[float](result.len)
  var smoothedSpeeds = newSeq[float](result.len)
  for i in 0 ..< result.len:
    observedAt[i] = epochTime()
  for j in result:
    workChan.send(j)

  # One sentinel per worker so they exit cleanly after the queue drains
  for i in 0 ..< workerCount:
    workChan.send(DownloadJob(label: "", destPath: "\x00quit"))

  if onTick != nil:
    onTick()

  while doneCount < pending:
    var drained = false
    # Drain all currently available progress messages
    while progressChan.peek() > 0:
      let msg = progressChan.recv()
      drained = true
      let scaledPercent = progressStart +
          (msg.percent * (progressEnd - progressStart) div 100)
      if msg.displayIdx < 0 or msg.displayIdx >= latestStatus.len:
        result[msg.jobIdx].ok = false
        inc doneCount
        continue
      if msg.finished:
        acquire(statusLock)
        latestStatus[msg.displayIdx].active = not manageProgress and msg.ok
        latestStatus[msg.displayIdx].finished = manageProgress or not msg.ok
        latestStatus[msg.displayIdx].ok = msg.ok
        if msg.ok:
          latestStatus[msg.displayIdx].percent = progressEnd
          latestStatus[msg.displayIdx].speed = if manageProgress: "" else: "downloaded"
        else:
          latestStatus[msg.displayIdx].speed = "download failed"
        release(statusLock)
        result[msg.jobIdx].ok = msg.ok
        inc doneCount
      else:
        if msg.totalBytes > 0:
          knownTotals[msg.jobIdx] = msg.totalBytes
        if msg.progressBytes > observedSizes[msg.jobIdx]:
          observedSizes[msg.jobIdx] = msg.progressBytes
        acquire(statusLock)
        latestStatus[msg.displayIdx].percent = max(
            latestStatus[msg.displayIdx].percent, scaledPercent)
        if msg.started:
          # Some servers/HttpClient paths do not emit intermediate progress
          # callbacks, so this state covers both connection setup and body
          # transfer. Calling it "connecting" made long transfers misleading.
          latestStatus[msg.displayIdx].speed = "downloading"
        elif msg.speedBps > 0:
          latestStatus[msg.displayIdx].speed = formatSize(msg.speedBps) & "/s"
        release(statusLock)
    # HttpClient progress callbacks can be sparse. Observe partial-file growth
    # every tick for smoother percentages and throughput between callbacks.
    let observedNow = epochTime()
    for jobIdx, job in result:
      let partialPath = job.destPath & ".partial"
      if knownTotals[jobIdx] <= 0 or not fileExists(partialPath):
        continue
      let currentSize = getFileSize(partialPath)
      let elapsed = observedNow - observedAt[jobIdx]
      if currentSize > observedSizes[jobIdx] and elapsed > 0:
        let instantSpeed = float(currentSize - observedSizes[jobIdx]) / elapsed
        smoothedSpeeds[jobIdx] = if smoothedSpeeds[jobIdx] <= 0:
            instantSpeed else: smoothedSpeeds[jobIdx] * 0.65 + instantSpeed * 0.35
        observedSizes[jobIdx] = currentSize
        observedAt[jobIdx] = observedNow
        let displayIdx = job.displayIdx
        let rawPercent = int(currentSize * 100 div knownTotals[jobIdx])
        let observedPercent = progressStart +
            rawPercent * (progressEnd - progressStart) div 100
        acquire(statusLock)
        if displayIdx >= 0 and displayIdx < latestStatus.len:
          latestStatus[displayIdx].percent = max(
              latestStatus[displayIdx].percent, observedPercent)
          latestStatus[displayIdx].speed = formatSize(
              int64(smoothedSpeeds[jobIdx])) & "/s"
        release(statusLock)

    # Paint completion events too. Previously the final drain skipped this
    # render because doneCount == pending, making completed rows disappear.
    if onTick != nil:
      onTick()
    if drained and renderUpdates:
      renderProgress()
    sleep(150)

  # Always leave a fully completed table on screen, even when the last
  # progress and completion messages arrived in the same channel drain.
  if onTick != nil:
    onTick()
  if renderUpdates:
    renderProgress()
  if manageProgress:
    clearProgress()

  for w in workers.mitems:
    joinThread(w)

  workChan.close()
  progressChan.close()
