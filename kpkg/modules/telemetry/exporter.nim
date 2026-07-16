import std/[httpclient, net, strutils, tables, uri]
import ./config

const telemetryHttpClientMaxRedirects* = 0
const telemetryContinueLogTimeoutMs* = 250

type
  TelemetryHttpRequest* = object
    url*: string
    headers*: Table[string, string]
    body*: string
    timeoutMs*: int
    tls*: bool
    verifyTls*: bool
    verifyHostname*: bool

  TelemetryTransport* = proc(request: TelemetryHttpRequest): int {.nimcall, gcsafe.}

proc normalizeEndpoint(endpoint: string, tls: bool, signal: string): string =
  let trimmed = endpoint.strip()
  if trimmed.len == 0:
    raise newException(TelemetryRuntimeError, "Telemetry endpoint cannot be empty")

  let requestedScheme = if tls: "https" else: "http"
  let source = if "://" in trimmed: trimmed else: requestedScheme & "://" & trimmed
  var parsed: Uri
  try:
    parsed = parseUri(source)
  except ValueError:
    raise newException(TelemetryRuntimeError, "Invalid telemetry endpoint")
  if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0 or
      parsed.username.len > 0 or parsed.password.len > 0 or parsed.anchor.len > 0 or
      parsed.query.len > 0:
    raise newException(TelemetryRuntimeError, "Invalid telemetry endpoint")

  parsed.scheme = requestedScheme
  var path = parsed.path.strip(chars = {'/'})
  if path in ["v1/traces", "v1/logs"]:
    path = signal
  elif path != signal:
    if path.len > 0:
      path.add("/")
    path.add(signal)
  parsed.path = "/" & path
  result = $parsed

proc normalizeTraceEndpoint*(endpoint: string, tls: bool): string =
  normalizeEndpoint(endpoint, tls, "v1/traces")

proc normalizeLogEndpoint*(endpoint: string, tls: bool): string =
  normalizeEndpoint(endpoint, tls, "v1/logs")

proc buildTraceRequest*(settings: TelemetrySettings,
    payload: string): TelemetryHttpRequest =
  result.url = normalizeTraceEndpoint(settings.endpoint, settings.tls)
  result.headers = {"Content-Type": "application/x-protobuf"}.toTable
  let authorization = settings.authorizationHeader()
  if authorization.len > 0:
    result.headers["Authorization"] = authorization
  result.body = payload
  result.timeoutMs = settings.timeoutMs
  result.tls = settings.tls
  result.verifyTls = settings.tls
  result.verifyHostname = settings.tls

proc buildLogRequest*(settings: TelemetrySettings,
    payload: string): TelemetryHttpRequest =
  result = buildTraceRequest(settings, payload)
  result.url = normalizeLogEndpoint(settings.endpoint, settings.tls)

proc newTelemetryHttpClient*(request: TelemetryHttpRequest): HttpClient =
  when defined(ssl):
    let sslContext = if request.tls: newContext(verifyMode = CVerifyPeer) else: nil
    result = newHttpClient(timeout = request.timeoutMs,
        maxRedirects = telemetryHttpClientMaxRedirects,
        sslContext = sslContext)
  else:
    if request.tls:
      raise newException(TelemetryRuntimeError,
          "TLS telemetry requires a build with SSL support")
    result = newHttpClient(timeout = request.timeoutMs,
        maxRedirects = telemetryHttpClientMaxRedirects)

proc sendWithHttpClient(request: TelemetryHttpRequest): int {.gcsafe.} =
  var client = newTelemetryHttpClient(request)
  defer: client.close()
  for key, value in request.headers:
    client.headers[key] = value
  let response = client.request(request.url, httpMethod = HttpPost, body = request.body)
  result = int(response.code)

proc exportTracePayload*(settings: TelemetrySettings, payload: string,
    transport: TelemetryTransport = nil) {.gcsafe.} =
  let request = buildTraceRequest(settings, payload)
  let status = if transport.isNil: sendWithHttpClient(request) else: transport(request)
  if status < 200 or status >= 300:
    raise newException(TelemetryRuntimeError,
        "Telemetry collector returned HTTP status " & $status)

proc exportLogPayload*(settings: TelemetrySettings, payload: string,
    transport: TelemetryTransport = nil, timeoutMs = 0) {.gcsafe.} =
  var request = buildLogRequest(settings, payload)
  if timeoutMs > 0:
    request.timeoutMs = timeoutMs
  let status = if transport.isNil: sendWithHttpClient(request) else: transport(request)
  if status < 200 or status >= 300:
    raise newException(TelemetryRuntimeError,
        "Telemetry collector returned HTTP status " & $status)
