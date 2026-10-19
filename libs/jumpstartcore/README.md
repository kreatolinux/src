# jumpstartcore

The reusable part of Jumpstart's core machinery, as a source-only Nim
library. The Jumpstart daemon (`jumpstart/`), `jumpctl`, the Kongue runner and
external core implementations such as `jumpstart-systemd-core` all import
these same modules, so there is exactly one copy of the exec protocol, the
operation registry, the error codes and the process-spawning layer.

It specifies nothing by itself: the behavior is defined by
RFC 0001, `jumpstart-cores` (section 26.1 describes this library).

## Module map

`import jumpstartcore` re-exports everything below; individual modules are
imported as `jumpstartcore/<module>`.

| Module | Purpose | Spec |
| --- | --- | --- |
| `protocol` | Exec protocol codec: `parseLine`/`encodeLine`, message constructors, handshake and result validation, deadlines | §17, §12, §16.3 |
| `registry`, `registry_types` | Operation registry for `manifest_version` 1 (data, not code) | §12 |
| `errors` | Typed error model and the `E_*` codes | §18 |
| `names` | Core, unit and subsystem name validation and reserved names | §6, §14.1, §12.13 |
| `adapterloop` | Adapter end of §17: hello reply, request dispatch to handlers, events, cancel, deadlines | §17 |
| `jsonlines` | Blocking/buffered JSON-lines reader and writer for descriptors 3 and 4 | §17.1 |
| `spawn` | Process attributes and descriptors (standard and passed), `fork`/`execve` without `osproc`, cgroup placement | §15.4 |
| `sandbox` | Read-only operation sandbox | §13.8 |
| `reaper` | Central child reaper | §15.3 |
| `cgroups` | Per-core cgroup subtrees, unit cgroups (nested too), attribution by pid | §15.1 |
| `environment` | Closed environments for core processes | §7.5, §16.2 |
| `coremode` | `CoreMode` (`cmSystem`, `cmUser`) | §7 |
| `peercred` | Peer credentials, pidfds, `/proc` process identity | §7.4, §15.3 |
| `verified_file` | `O_NOFOLLOW` + `fstat` verified reads of files owned by root or a trusted uid | §8.3, §24 |

What is not here stays in the daemon (`jumpstart/cores/`): discovery, the
manifest loader, lifecycle, sessions, routing, the control socket, the
daemon-side adapter/supervisor drivers, logging and the CLI. Nothing in this
package imports anything under `jumpstart/`.

## Stability

- **Stable contract**: the exec protocol codec (`protocol`), the registry
  (`registry`, `registry_types`) and the error codes (`errors`) follow the
  cores specification (§17, §12, §18). Names and meaning there change only
  with a new protocol identifier or `manifest_version`.
- **Unstable until the 2.x line settles**: everything else, including
  `adapterloop`, `jsonlines`, `spawn`, `cgroups`, `reaper`, `sandbox`,
  `environment`, `names`, `peercred`, `verified_file` and `coremode`. Pin an
  exact version (`== 2.2.0`) or a commit.

The package version tracks the cores specification revision and protocol, not
the Jumpstart release number.

## Using it from another repository

Requirement from this monorepo (nimble git requirement with a subdirectory):

```nim
# yourcore.nimble
requires "nim >= 2.2.0"
requires "https://github.com/kreatolinux/src?subdir=libs/jumpstartcore#<commit>"
```

Local development against a checkout, without nimble:

```sh
# nim.cfg of the consumer
--path:"/path/to/src/libs/jumpstartcore/src"
# or per command
nim c --path:/path/to/src/libs/jumpstartcore/src yourcore.nim
```

or with nimble: `nimble develop -a:/path/to/src/libs/jumpstartcore` in the
consumer's directory.

```nim
import jumpstartcore

let session = newAdapterSession()          # descriptors 3 and 4
session.handle("service.status", proc(ctx: RequestContext): JsonNode =
  %*{"state": "active", "detail": "", "enablement": "enabled"})
quit session.serve()
```

## Tests

From the repository root: `sh build.sh -T jumpstartcore`. The cgroup, spawn and
live-cgroup tests need a writable cgroup v2 hierarchy and skip themselves unless run as
root on Linux (use a privileged Linux container with a cgroup v2 hierarchy).

## License

`jumpstartcore` is licensed under the **GNU Lesser General Public License,
version 3 or later** (`COPYING.LESSER`, which supplements the GPL text in
`COPYING`). A core implementation may link it, in source or binary form, without
becoming GPL itself; changes to the library's own files must be shared under the
LGPL. The rest of the Jumpstart repository (daemon, `jumpctl`, tools) remains
GPL-3.0 (`../../LICENSE`).
