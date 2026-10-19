% jumpstart_dec(5)

# NAME
jumpstart_dec - Main declaration format of Jumpstart

# DESCRIPTION
Jumpstart decfiles are the main declaration format of Jumpstart. They are basic scripts with specific variables and functions that enable the user to create Jumpstart units such as services, mounts, and timers.

# DECFILE STRUCTURE
Decfiles are simply named `[UNITNAME].kg` and must be placed inside the `/etc/jumpstart` directory. It is using Kongue under the hood, see kongue(5).

## Example Decfile

```bash
name: "example"
description: "Example multi unit with services, mounts, and timers"
type: "multi"
depends:
    - "network"
depends main:
    - "example::data"
after:
    - "sound"
after_main:
    - "example::cache"

mount data {
    from "/dev/nvme0n1p2"
    to "/mnt/data"
    fstype "ext4"
    timeout "10s"
    chmod 755
}

mount cache {
    from "tmpfs"
    to "/var/cache/example"
    fstype "tmpfs"
    extra_args "-o size=512M"
}

service main {
    exec "/usr/bin/example-daemon --config /etc/example.conf"
}

service helper {
    exec "/usr/bin/example-helper"
}

timer cleanup {
    interval 3600
    service "example-cleanup"
    on_missed "skip"
}

timer sync {
    interval 86400
    service "example-sync"
    on_missed "run"
}
```

# SYNTAX AND LANGUAGE FEATURES

## REQUIRED VARIABLES
* **description**: Description of the unit.
* **type**: Type of the unit. Valid values are:
  - `simple`: A basic service that runs a single process.
  - `oneshot`: A service that runs once and exits.
  - `multi`: A unit containing multiple sub-units (services, mounts, or timers).
  - `timer`: A timer that triggers a service at specified intervals.
  - `mount`: A filesystem mount unit.
  - `target`: A group of native units. A target has no function block.

## DEPENDENCY VARIABLES
* **depends**: Hard dependencies of your unit. When a target starts (including the boot target), every unit in the `depends` closure of its members is started too, whether or not it is enabled, and before the units that depend on it. A unit whose dependency is unknown or failed to start is not started and is reported as failed. Starting a single non-target unit with `jumpctl start` starts only that unit.
  - Can also depend on a specific sub-unit using `depends: "unitname::subunitname"`
* **depends subunitname**: Specify dependencies for a specific sub-unit. Can be modified using:
  - `depends subunitname+: "unitname"` to add a dependency
  - `depends subunitname-: "unitname"` to remove a dependency
  - `depends subunitname: "unitname"` to replace dependencies completely

## ORDERING VARIABLES
* **after**: Start this unit after the specified units when both are started together. Unlike `depends`, `after` never pulls a unit in and ignores units that are not present.
* **after subunitname**: Specify ordering for a specific sub-unit. Can be modified using:
  - `after subunitname+: "unitname"` to add an ordering
  - `after subunitname-: "unitname"` to remove an ordering
  - `after subunitname: "unitname"` to replace orderings completely

## OPTIONAL VARIABLES
* **name**: Name of the unit. If not specified, defaults to the filename without the `.kg` extension.

## REQUIRED FUNCTIONS
The required function depends on the unit `type`:

* **service**: Required for `simple` and `oneshot` types. Contains commands to execute when the service starts.
* **timer**: Required for `timer` type. See **TIMERS** below.
* **mount**: Required for `mount` type. See **MOUNTS** below.

For `multi` type units, at least one named function block is required (e.g., `service_name`, `timer_name`, or `mount_name`).

## COMMAND ARGUMENTS
Arguments of the commands inside function blocks are literal values. A quoted argument such as `from "tmpfs"` is the string between the quotes, with Kongue escapes (`\"`, `\\`, `\n`, `\t`, `\r`) decoded. Bare words and numbers (`interval 3600`, `terminal true`) are taken as written.

## VALIDATION
`jumpctl units validate UNIT` and `jumpctl units load` report a missing `description` or `type`, an unknown `type`, a function block in a target, a `simple`, `oneshot`, `mount`, or `timer` unit without exactly one block of its kind, a service without `exec`, a mount without `from`, `to`, or `fstype`, a timer without a positive `interval` or a `service`, duplicate sub-unit names, unknown target members, and target cycles. Parsing stays tolerant for compatibility: a unit with such problems is still loaded, but an unknown `type` is not a valid declaration.

## OPTIONAL FUNCTIONS
* **service name**: Defines a named sub-service for `multi` type units. Replace `name` with the sub-service identifier.
* **timer name**: Defines a named timer for `multi` type units. Replace `name` with the timer identifier.
* **mount name**: Defines a named mount for `multi` type units. Replace `name` with the mount identifier.

# SERVICES
Services are units that run processes. To create a service, set `type` to `simple` or `oneshot` and define a `service` function block.

## SERVICE COMMANDS
The following commands are available inside `service` blocks, in addition to the default Kongue built-in commands (see kongue(5) for those):

* **exec**: Execute a command as the service process. Required. The command is split into words without a shell (quotes group words) and the program is looked up in the unit environment's `PATH`.
* **exec_pre**: A command run to completion before `exec`. A non-zero exit is logged and the service still starts. A command still running after 90 seconds is killed and the start fails.
* **exec_post**: A command run after the service exits with status 0. The status becomes `stopped` once it has finished.
* **terminal**: Set to `true` for interactive services such as getty. The service inherits init's terminal and remains in its foreground process group. Defaults to `false`. Other services run in their own session with standard input from `/dev/null`; their output is discarded.

## SERVICE PROCESSES
Service processes start with the environment Jumpstart builds for its mode (in system mode `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` and `LANG=C.UTF-8`), not with init's own environment, in the working directory `/`. When cgroup v2 is available, every process of a native unit runs in the cgroup `cores/serviceHandler/units/UNIT.unit/` below Jumpstart's hierarchy. Without cgroup v2 services run without cgroups.

Stopping a service sends `SIGTERM` to its main process, waits up to 10 seconds, sends `SIGKILL`, and then kills the unit's cgroup, which reaches every remaining process of the service. `jumpctl kill UNIT [--signal S]` signals every process in the unit's cgroup, or only the main process without cgroup v2; it never signals a process group. `jumpctl restart UNIT` is a stop followed by a start. Native services have no reload command.

## STATUS
`jumpctl status UNIT` prints the native status text. Services write it to their runtime state; Jumpstart maps it to a unit state:

* `running` (service or timer) and `mounted` (mount): `active`.
* `stopped`, or no status at all: `inactive`.
* `stopped with an exit code N`: `inactive` when the exit followed a stop that Jumpstart requested (usually `N` is 143, from `SIGTERM`), otherwise `failed`. The status text stays after a stop; it never prevents the next start.
* Anything else: `unknown`.

## Example Service

```bash
description: "Example daemon"
type: "simple"

service {
    exec "/usr/bin/example-daemon"
}
```

Interactive getty example:

```bash
description: "Login on tty1"
type: "simple"

service {
    terminal true
    exec "/sbin/agetty --noclear tty1 linux"
}
```

# TIMERS
Timers are units that trigger services at specified intervals. To create a timer, set `type` to `timer` and define a `timer` function block.

## TIMER COMMANDS
The following commands are available inside `timer` blocks:

* **interval**: Time between service triggers in seconds. Required.
* **service**: The service to trigger when the timer fires. Required.
* **on_missed**: Behavior when a scheduled timer run was missed (e.g., system was off). Valid values are:
  - `skip`: Skip the missed run and wait for the next interval. This is the default.
  - `run`: Run the service immediately when the timer starts.

## Example Timer

```bash
description: "Cleanup temporary files every hour"
type: "timer"

timer {
    interval 3600
    service "cleanup"
    on_missed "skip"
}
```

# MOUNTS
Mounts are units that mount filesystems. To create a mount, set `type` to `mount` and define a `mount` function block.

## MOUNT COMMANDS
The following commands are available inside `mount` blocks:

* **from**: Source device or path to mount (e.g., `/dev/nvme0n1p1`). Required.
* **to**: Target mount point directory. Required.
* **fstype**: Filesystem type (e.g., `ext4`, `btrfs`, `tmpfs`). Required.
* **timeout**: Maximum time to wait for the mount operation (e.g., `5s`, `1m`).
* **lazy_unmount**: When `true`, perform a lazy unmount on stop, detaching the filesystem immediately and cleaning up references later. Default is `false`. A stop request with `lazy` set does the same for one stop.
* **chmod**: Set permissions on the mount point after mounting (e.g., `755`).
* **extra_args**: The filesystem-specific data string passed to mount(2) (e.g., `"size=512M"`).

## Example Mount

```bash
description: "Mount data partition"
type: "mount"

mount {
    from "/dev/nvme0n1p1"
    to "/mnt/data"
    fstype "ext4"
    timeout "5s"
    chmod 755
}
```

# TARGETS
A decfile with `type: "target"` groups native Jumpstart units. It has no function block. Its optional `wants` variable lists decfile names and may name sub-units with `::`; target names are also valid members.

```bash
description: "Multi-user system"
type: "target"
wants:
    - "sshd"
    - "network"
    - "getty::tty1"
```

The members of target `T` are its `wants` plus units enabled into it. `jumpctl enable UNIT --target T` creates `/etc/jumpstart/targets/T/UNIT.kg`; the corresponding `disable` command removes that link. Enabling without `--target` continues to create `/etc/jumpstart/enabled/UNIT.kg` and makes the unit a member of the built-in `default` target. `--now` also starts (for `enable`) or stops (for `disable`) the unit. A sub-unit cannot be enabled or disabled separately (the request fails with `E_UNSUPPORTED`, naming its decfile); list it in `wants` instead. User-mode daemons use the same layout below `~/.config/jumpstart`.

Cycles through target `wants` or target enablement links are validation and load errors, and a target in a cycle cannot be started. Starting a target starts its transitive members and their `depends` closure, ordered by `depends` and `after`; if any of them fails to start, the others still start and the request reports the failures (`E_PARTIAL`). Stopping a target stops its active transitive members in reverse start order. An unqualified `multi` decfile acts as a target whose members are its sub-units: `jumpctl start foo` starts its mounts, then its services, then its timers (subject to `depends` and `after`), and `jumpctl stop foo` stops them in reverse order. Each sub-unit (`foo::bar`) is a service, mount, or timer of its own.

A native unit is `enabled` when linked in `enabled/` or any `targets/*/` directory, `static` when only named by a target's `wants`, and `disabled` otherwise. Native units do not report `indirect`, `masked`, or `generated`.

Native activation starts the boot target. Deactivation stops every active native unit, including units started individually with `jumpctl start`, in reverse start order. `jumpctl isolate T` starts `T` and then stops every active native unit that `T` does not require, that is, every unit that is neither a transitive member of `T` nor in its members' `depends` closure.

Target status reports the transitive members. A member is satisfied when it is active, or when it is a `oneshot` service whose last run, started since the target last started, exited with status 0. The target is `failed` if any member is failed (or failed to start), otherwise `active` if every member is satisfied (a started target without members is active), otherwise `inactive` if the target has not been started since boot or was stopped, or no member is satisfied, and otherwise `activating`. `jumpctl status` prints these as `failed`, `running`, `stopped`, and `starting`. Targets and multi-unit decfiles have no status file.

## DEFAULT AND BOOT TARGETS
The native `default` target always exists and consists of units linked in `enabled/`. The boot target is read from `/etc/jumpstart/default-target`, which contains one native target name followed by a newline. If that file does not exist, `default` is used. `target.set-default` updates the file atomically and `target.get-default` reads it.

The name `default.kg` is reserved and such a decfile is rejected. **Migration:** an installation with an existing `/etc/jumpstart/default.kg` continues booting other units, but `default.kg` is reported as an error at daemon startup and by unit loading, is not loaded, and never starts. Rename that decfile and its link in `/etc/jumpstart/enabled/` (and any target links) to restore the unit.

# AUTHOR
Written by Kreato.

# COPYRIGHT
jumpstart is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

jumpstart is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with jumpstart.  If not, see <https://www.gnu.org/licenses/>.
