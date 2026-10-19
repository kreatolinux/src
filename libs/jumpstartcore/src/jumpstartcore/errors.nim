## Complete typed error model from jumpstart-cores section 18.
import std/strutils

type
  CoreErrorCode* = enum
    ecUsage, ecName, ecLayout, ecManifest, ecVersion, ecPermission, ecState,
    ecCoreState, ecUnitState, ecCoreUnloaded, ecCoreFailed, ecNotFound,
    ecAmbiguous, ecUnsupported, ecDelegation, ecSandbox, ecCgroup, ecTimeout,
    ecCancelled, ecBusy, ecLimit, ecShutdown, ecBackend, ecPartial, ecProtocol,
    ecDegraded, ecInit, ecIo
  CoreError* = object of CatchableError
    code*: CoreErrorCode
    core*: string
    message*: string
    cores*: seq[string]
  CoreResult*[T] = object
    case ok*: bool
    of true: value*: T
    of false: error*: CoreError

const ErrorNames*: array[CoreErrorCode, string] = [
  "E_USAGE", "E_NAME", "E_LAYOUT", "E_MANIFEST", "E_VERSION", "E_PERMISSION",
  "E_STATE", "E_CORE_STATE", "E_UNIT_STATE", "E_CORE_UNLOADED", "E_CORE_FAILED",
  "E_NOT_FOUND", "E_AMBIGUOUS", "E_UNSUPPORTED", "E_DELEGATION", "E_SANDBOX",
  "E_CGROUP", "E_TIMEOUT", "E_CANCELLED", "E_BUSY", "E_LIMIT", "E_SHUTDOWN",
  "E_BACKEND", "E_PARTIAL", "E_PROTOCOL", "E_DEGRADED", "E_INIT", "E_IO"]
proc errorName*(code: CoreErrorCode): string {.inline.} = ErrorNames[code]
proc codeName*(code: CoreErrorCode): string {.inline.} = errorName(code)
proc exitCode*(code: CoreErrorCode): int =
  case code
  of ecUsage: 2
  of ecUnsupported: 3
  of ecTimeout, ecCancelled: 4
  else: 1
proc tryParseErrorCode*(name: string; code: var CoreErrorCode): bool =
  ## True when `name` is one of the codes defined in §18.
  for candidate in CoreErrorCode:
    if ErrorNames[candidate] == name:
      code = candidate
      return true
  false
proc isErrorCodeName*(name: string): bool =
  var ignored: CoreErrorCode
  tryParseErrorCode(name, ignored)
proc parseErrorCode*(name: string): CoreErrorCode =
  if not tryParseErrorCode(name, result):
    raise newException(ValueError, "unknown core error code: " & name)
proc kongueFailCode*(name: string): CoreErrorCode =
  ## §16.3 `fail CODE MESSAGE`: `E_BACKEND` if CODE is not a defined code.
  if not tryParseErrorCode(name, result): result = ecBackend
proc backendReportedCode*(name: string): CoreErrorCode =
  ## Code carried by an adapter or runner `response` with status `error`
  ## (§17.3). §18 says every failure has exactly one code drawn from the
  ## table; a code outside it is a protocol violation, hence `E_PROTOCOL`.
  if not tryParseErrorCode(name, result): result = ecProtocol
proc newCoreError*(code: CoreErrorCode, message: string, core = ""): ref CoreError =
  result = newException(CoreError, message)
  result.code = code; result.core = core; result.message = message
proc success*[T](value: T): CoreResult[T] = CoreResult[T](ok: true, value: value)
proc failure*[T](code: CoreErrorCode; message: string; cores: seq[string] = @[]): CoreResult[T] =
  CoreResult[T](ok: false, error: CoreError(code: code, message: message, msg: message, cores: cores))
proc diagnostic*(code: CoreErrorCode, message: string, core = ""): string =
  let clean = message.replace("\r", " ").replace("\n", " ")
  if core.len == 0: "jumpctl: " & errorName(code) & ": " & clean
  else: "jumpctl: " & core & ": " & errorName(code) & ": " & clean
proc diagnostic*(error: CoreError): string = diagnostic(error.code, error.msg, error.core)
