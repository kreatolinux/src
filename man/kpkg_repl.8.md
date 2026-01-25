% kpkg_repl(8)

# NAME
kpkg repl - interactive shell for kpkg

# DESCRIPTION
**kpkg repl** starts an interactive read-eval-print loop (REPL) for kpkg. It provides a powerful environment to inspect package information, modify configurations, and script kpkg operations using the **run3** scripting language.

The REPL supports session history (persisted to `~/.cache/kpkg/history`), multi-line input for function definitions and blocks, and convenient shorthands for common `get` and `set` operations.

# SYNOPSIS
**kpkg repl** [COMMAND] [ARGS]...

If no arguments are provided, it enters the interactive mode.
If arguments are provided, it executes the single command and exits (similar to `bash -c`).

# COMMANDS

## INTERACTIVE COMMANDS
The following commands are available within the REPL prompt (`kpkg>`).

### get [INVOCATION]
Retrieves values from the database, configuration, overrides, or dependency graph.

**TYPES**:
* `db`: Get values from the database.
* `config`: Get values from the config.
* `overrides`: Get value from a package override.
* `depends`: Get dependency list for a package.

**EXAMPLES**:
```sh
# Get version of package 'kpkg'
kpkg> get db.package.kpkg.version

# List all config sections
kpkg> get config

# Get specific config value
kpkg> get config.Repositories.repoLinks
```

### set [INVOCATION] [VALUE]
Sets values in the configuration or overrides.

**TYPES**:
* `config`: Set config values.
* `overrides`: Set package overrides.

**EXAMPLES**:
```sh
# Set a config value
kpkg> set config.General.Color true

# Set an override flag
kpkg> set overrides.bash.cflags "-O3"
```

### history
Displays the command history for the current user.

### exit / quit
Exits the REPL session.

### clear
Clears the terminal screen.

## RUN3 SCRIPTING
The REPL supports full **run3** syntax, allowing for complex logic, loops, and custom function definitions directly in the shell.

**printing**:
```run3
print "Hello World"
```

**Variables**:
```run3
local x = 10
print $x
```

**Conditionals**:
```run3
if true {
    print "It's true!"
}
```

**Functions**:
```run3
func my_helper {
    print "Inside helper"
}
my_helper
```

# FILES
* `~/.cache/kpkg/history`: Stores the history of typed commands.

# EXAMPLES

**One-off command execution:**
```sh
kpkg repl get config.Repositories
```

**Interactive session:**
```sh
$ kpkg repl
kpkg> local pkg = "bash"
kpkg> get db.package.$pkg.version
5.2.15
kpkg> exit
```

# SEE ALSO
kpkg(8), kpkg.conf(5), kpkg_run(5)

# AUTHOR
Written by Kreato.

# COPYRIGHT
kpkg is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

kpkg is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with kpkg.  If not, see <https://www.gnu.org/licenses/>.
