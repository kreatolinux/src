# Common logging module for Kreato Linux tools
# Configurable per-application logging with support for:
# - Multiple log levels (trace, debug, info, warn, error, fatal)
# - File logging
# - Environment variable configuration
# - Config file configuration
# - Colored output
# - Timestamps

import os
import parsecfg
import strutils
import terminal
import times

type
  LogLevel* = enum
    lvlTrace = 0
    lvlDebug = 1
    lvlInfo = 2
    lvlWarn = 3
    lvlError = 4
    lvlFatal = 5
    lvlNone = 6

  ErrorCallback* = proc(msg: string) {.closure.}

  Logger* = ref object
    name*: string
    level*: LogLevel
    useColors*: bool
    showTimestamp*: bool
    errorCallback*: ErrorCallback
    fileLogging*: bool
    logFilePath*: string
    configPath*: string

var defaultLogger*: Logger = nil

proc initDefaultLogger(name: string = "app", configPath: string = "",
                       logFilePath: string = "") =
  ## Initialize the default logger with given parameters
  let defaultLogFile = if logFilePath != "": logFilePath
                       else: "/var/log/" & name & ".log"

  if defaultLogger == nil:
    defaultLogger = Logger(
      name: name,
      level: when defined(release): lvlInfo else: lvlDebug,
      useColors: stdout.isatty(),
      showTimestamp: false,
      errorCallback: nil,
      fileLogging: false,
      logFilePath: defaultLogFile,
      configPath: configPath
    )
  else:
    # Update existing logger
    defaultLogger.name = name
    defaultLogger.configPath = configPath
    defaultLogger.logFilePath = defaultLogFile

proc getDefaultLogger*(): Logger =
  if defaultLogger == nil:
    initDefaultLogger()
  return defaultLogger

proc parseLogLevel*(levelStr: string): LogLevel =
  ## Parses a string to LogLevel.
  case levelStr.toLowerAscii()
  of "trace": lvlTrace
  of "debug": lvlDebug
  of "info": lvlInfo
  of "warn", "warning": lvlWarn
  of "error", "err": lvlError
  of "fatal": lvlFatal
  of "none", "off": lvlNone
  else: lvlInfo

proc levelToString(level: LogLevel): string =
  case level
  of lvlTrace: "trace"
  of lvlDebug: "debug"
  of lvlInfo: "info"
  of lvlWarn: "warning"
  of lvlError: "error"
  of lvlFatal: "fatal"
  of lvlNone: "none"

proc levelToColor(level: LogLevel): ForegroundColor =
  case level
  of lvlTrace: fgWhite
  of lvlDebug: fgYellow
  of lvlInfo: fgBlue
  of lvlWarn: fgYellow
  of lvlError: fgRed
  of lvlFatal: fgRed
  of lvlNone: fgDefault

proc newLogger*(name: string, level: LogLevel = lvlInfo,
                configPath: string = "", logFilePath: string = ""): Logger =
  ## Creates a new logger.
  let defaultLogFile = if logFilePath != "": logFilePath
                       else: "/var/log/" & name & ".log"
  Logger(
    name: name,
    level: level,
    useColors: stdout.isatty(),
    showTimestamp: false,
    errorCallback: nil,
    fileLogging: false,
    logFilePath: defaultLogFile,
    configPath: configPath
  )

proc setLogLevel*(level: LogLevel) =
  getDefaultLogger().level = level

proc setLogLevel*(levelStr: string) =
  setLogLevel(parseLogLevel(levelStr))

proc getLogLevel*(): LogLevel =
  getDefaultLogger().level

proc isEnabled*(level: LogLevel): bool =
  ## Returns true if a log level is enabled.
  level >= getDefaultLogger().level

proc setErrorCallback*(callback: ErrorCallback) =
  getDefaultLogger().errorCallback = callback

proc setUseColors*(useColors: bool) =
  getDefaultLogger().useColors = useColors

proc setShowTimestamp*(showTimestamp: bool) =
  getDefaultLogger().showTimestamp = showTimestamp

proc setName*(name: string) =
  getDefaultLogger().name = name

proc setFileLogging*(enabled: bool, path: string = "") =
  let logger = getDefaultLogger()
  logger.fileLogging = enabled
  if path != "":
    logger.logFilePath = path

proc configureFromEnv*(logger: Logger) =
  ## Configures the logger from environment variables.
  ## Uses {NAME}_LOG_LEVEL, {NAME}_ENABLE_DEBUG, {NAME}_LOG_TIMESTAMP, {NAME}_LOG_COLORS
  ## where NAME is the uppercase version of the logger name.
  let envPrefix = logger.name.toUpperAscii() & "_"

  let levelEnv = getEnv(envPrefix & "LOG_LEVEL", "")
  if levelEnv != "":
    logger.level = parseLogLevel(levelEnv)
  else:
    let debugEnv = getEnv(envPrefix & "ENABLE_DEBUG", "")
    if debugEnv != "":
      if parseBool(debugEnv):
        logger.level = lvlDebug
      else:
        logger.level = lvlInfo

  let timestampEnv = getEnv(envPrefix & "LOG_TIMESTAMP", "")
  if timestampEnv != "":
    logger.showTimestamp = parseBool(timestampEnv)

  let colorsEnv = getEnv(envPrefix & "LOG_COLORS", "")
  if colorsEnv != "":
    logger.useColors = parseBool(colorsEnv)

proc configureFromEnv*() =
  ## Configures the default logger from environment variables.
  configureFromEnv(getDefaultLogger())

proc configureFromConfig*(logger: Logger) =
  ## Configures the logger from its config file.
  if logger.configPath == "" or not fileExists(logger.configPath):
    return

  try:
    let config = loadConfig(logger.configPath)

    let levelVal = config.getSectionValue("Logging", "level", "")
    if levelVal != "":
      logger.level = parseLogLevel(levelVal)

    let timestampVal = config.getSectionValue("Logging", "timestamp", "")
    if timestampVal != "":
      logger.showTimestamp = timestampVal.toLowerAscii() in ["true", "yes", "1"]

    let colorsVal = config.getSectionValue("Logging", "colors", "")
    if colorsVal != "":
      logger.useColors = colorsVal.toLowerAscii() in ["true", "yes", "1"]

    let fileLoggingVal = config.getSectionValue("Logging", "fileLogging", "false")
    logger.fileLogging = fileLoggingVal.toLowerAscii() in ["true", "yes", "1"]

    let logFileVal = config.getSectionValue("Logging", "logFile", "")
    if logFileVal != "":
      logger.logFilePath = logFileVal
  except:
    discard

proc configureFromConfig*() =
  ## Configures the default logger from its config file.
  configureFromConfig(getDefaultLogger())

proc initLogger*(name: string, configPath: string = "",
                 logFilePath: string = "") =
  ## Initialize the logging system for an application.
  ## Call this at the start of your application.
  ##
  ## Parameters:
  ##   name: Application name (used for log prefix and env var prefix)
  ##   configPath: Path to config file (e.g., "/etc/kpkg/kpkg.conf")
  ##   logFilePath: Path to log file (defaults to "/var/log/{name}.log")
  ##
  ## Example:
  ##   initLogger("kpkg", "/etc/kpkg/kpkg.conf")
  ##   initLogger("jumpstart", "/etc/jumpstart/main.conf")
  initDefaultLogger(name, configPath, logFilePath)
  configureFromEnv()
  configureFromConfig()


### Internal implementation

proc formatContext(context: openArray[string]): string =
  if context.len == 0:
    return ""
  result = " ("
  for i, item in context:
    if i > 0:
      result.add(", ")
    result.add(item)
  result.add(")")

proc writeToLogFile(logger: Logger, level: LogLevel, module: string,
                    msg: string, contextStr: string) =
  if not logger.fileLogging:
    return

  try:
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    let levelStr = levelToString(level)
    let moduleStr = if module != "": "[" & module & "] " else: ""
    let logLine = timestamp & " " & logger.name & ": " & levelStr & ": " &
                  moduleStr & msg & contextStr & "\n"

    let f = open(logger.logFilePath, fmAppend)
    defer: f.close()
    f.write(logLine)
  except:
    discard

proc logImpl(logger: Logger, level: LogLevel, module: string, msg: string,
             context: openArray[string]) =
  if level < logger.level:
    return

  let output = if level >= lvlWarn: stderr else: stdout
  let isOutputTty = if level >= lvlWarn: stderr.isatty() else: stdout.isatty()
  let useColors = logger.useColors and isOutputTty

  var fullMsg = logger.name & ": "

  if logger.showTimestamp:
    fullMsg.add(now().format("yyyy-MM-dd HH:mm:ss") & " ")

  let levelStr = levelToString(level) & ": "
  let color = levelToColor(level)
  let moduleStr = if module != "": "[" & module & "] " else: ""
  let contextStr = formatContext(context)

  if useColors:
    output.styledWrite(fullMsg, color, levelStr, fgDefault, moduleStr, msg, contextStr)
    output.write("\n")
    output.flushFile()
  else:
    output.writeLine(fullMsg & levelStr & moduleStr & msg & contextStr)
    output.flushFile()

  writeToLogFile(logger, level, module, msg, contextStr)

proc log*(logger: Logger, level: LogLevel, module: string, msg: string,
          context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(logger, level, module, msg, contextSeq)

proc log*(level: LogLevel, module: string, msg: string,
          context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), level, module, msg, contextSeq)

proc log*(level: LogLevel, msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), level, "", msg, contextSeq)


### Convenience functions with module context

proc trace*(module, msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlTrace, module, msg, contextSeq)

proc debug*(module, msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlDebug, module, msg, contextSeq)

proc info*(module, msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlInfo, module, msg, contextSeq)

proc warn*(module, msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlWarn, module, msg, contextSeq)

proc error*(module, msg: string, context: varargs[string, `$`]) =
  ## Logs an error message. Does NOT exit.
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlError, module, msg, contextSeq)

proc fatal*(module, msg: string, context: varargs[string, `$`]) =
  ## Logs a fatal error and exits. Invokes error callback if set.
  let logger = getDefaultLogger()
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(logger, lvlFatal, module, msg, contextSeq)

  stderr.writeLine(logger.name & ": if you think this is a bug, please open an issue at https://github.com/kreatolinux/src")
  stderr.flushFile()

  if logger.errorCallback != nil:
    logger.errorCallback(msg)

  when not defined(release):
    if logger.level <= lvlDebug:
      raise newException(OSError, message = msg)

  quit(1)


### Convenience functions without module context

proc trace*(msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlTrace, "", msg, contextSeq)

proc debug*(msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlDebug, "", msg, contextSeq)

proc info*(msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlInfo, "", msg, contextSeq)

proc warn*(msg: string, context: varargs[string, `$`]) =
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlWarn, "", msg, contextSeq)

proc error*(msg: string, context: varargs[string, `$`]) =
  ## Logs an error message. Does NOT exit.
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(getDefaultLogger(), lvlError, "", msg, contextSeq)

proc fatal*(msg: string, context: varargs[string, `$`]) =
  ## Logs a fatal error and exits. Invokes error callback if set.
  let logger = getDefaultLogger()
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  logImpl(logger, lvlFatal, "", msg, contextSeq)

  stderr.writeLine(logger.name & ": if you think this is a bug, please open an issue at https://github.com/kreatolinux/src")
  stderr.flushFile()

  if logger.errorCallback != nil:
    logger.errorCallback(msg)

  when not defined(release):
    if logger.level <= lvlDebug:
      raise newException(OSError, message = msg)

  quit(1)


### Success logging (ok)

proc okImpl(logger: Logger, module: string, msg: string,
            context: openArray[string]) =
  ## Internal implementation for ok logging
  if lvlInfo < logger.level:
    return

  let output = stdout
  let isOutputTty = stdout.isatty()
  let useColors = logger.useColors and isOutputTty

  var fullMsg = logger.name & ": "

  if logger.showTimestamp:
    fullMsg.add(now().format("yyyy-MM-dd HH:mm:ss") & " ")

  let levelStr = "ok: "
  let moduleStr = if module != "": "[" & module & "] " else: ""
  let contextStr = formatContext(context)

  if useColors:
    output.styledWrite(fullMsg, fgGreen, levelStr, fgDefault, moduleStr, msg, contextStr)
    output.write("\n")
    output.flushFile()
  else:
    output.writeLine(fullMsg & levelStr & moduleStr & msg & contextStr)
    output.flushFile()

  writeToLogFile(logger, lvlInfo, module, msg, contextStr)

proc ok*(module, msg: string, context: varargs[string, `$`]) =
  ## Logs a success message with green "ok" prefix.
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  okImpl(getDefaultLogger(), module, msg, contextSeq)

proc ok*(msg: string, context: varargs[string, `$`]) =
  ## Logs a success message with green "ok" prefix.
  var contextSeq: seq[string] = @[]
  for item in context:
    contextSeq.add(item)
  okImpl(getDefaultLogger(), "", msg, contextSeq)
