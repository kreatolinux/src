# Run3 integration

This directory connects kpkg recipes to the Kongue parser and execution engine
in `kongue/`. It contains kpkg-specific execution hooks and build macros, not a
separate language implementation or executable.

## Files and APIs

- `run3.nim` defines `Run3File` and `Run3Context`. `parseRun3` reads a package
  directory's `run3` file. Metadata accessors such as `getVariable`,
  `getListVariable`, and `getSourcesWithVersion` apply variable substitution;
  selected accessors also accept configuration overrides.
- `initRun3ContextFromParsed` loads variables and functions into a context.
  `executeRun3Stage` runs a stage in an existing context; `executeFunction`
  provides a higher-level wrapper for a parsed recipe.
- The context's execution hook calls `processes.execEnv`. Its `sandboxPath`,
  `passthrough`, `remount`, and `asRoot` fields control how commands run.
  `builder/context.nim` configures this context for package builds.
- `macros.nim` implements the `extract`, `build`, `test`, and `package` helpers
  via `executeMacro`. Helpers cover Meson, CMake, Ninja, Make, and Autotools,
  with behavior selected by the macro arguments and available build files.
  They invoke external tools through the context; those tools must be installed.

`run3.nim` re-exports Kongue modules for existing callers, wires Kongue logging
into kpkg logging, and integrates recipe execution with telemetry. The sibling
`runparser.nim` uses this integration to expose kpkg package metadata.
Archive extraction uses `libarchive`; compiling with `-d:run3NoLibArchive`
disables the extract macro's archive support rather than replacing it.
