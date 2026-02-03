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

## DEPENDENCY VARIABLES
* **depends**: Runtime dependencies of your unit. The unit will start after the specified units have started and will fail if any dependency is not running.
  - Can also depend on a specific sub-unit using `depends: "unitname::subunitname"`
* **depends subunitname**: Specify dependencies for a specific sub-unit. Can be modified using:
  - `depends subunitname+: "unitname"` to add a dependency
  - `depends subunitname-: "unitname"` to remove a dependency
  - `depends subunitname: "unitname"` to replace dependencies completely

## ORDERING VARIABLES
* **after**: Start this unit after the specified units have started. Unlike `depends`, the unit will not fail if the specified units are not present or not running.
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

## OPTIONAL FUNCTIONS
* **service name**: Defines a named sub-service for `multi` type units. Replace `name` with the sub-service identifier.
* **timer name**: Defines a named timer for `multi` type units. Replace `name` with the timer identifier.
* **mount name**: Defines a named mount for `multi` type units. Replace `name` with the mount identifier.

# SERVICES
Services are units that run processes. To create a service, set `type` to `simple` or `oneshot` and define a `service` function block.

## SERVICE COMMANDS
The following commands are available inside `service` blocks, in addition to the default Kongue built-in commands (see kongue(5) for those):

* **exec**: Execute a command as the service process. Required.

## Example Service

```bash
description: "Example daemon"
type: "simple"

service {
    exec "/usr/bin/example-daemon"
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
* **lazy_unmount**: When `true`, perform a lazy unmount on stop, detaching the filesystem immediately and cleaning up references later. Default is `false`.
* **chmod**: Set permissions on the mount point after mounting (e.g., `755`).
* **extra_args**: Additional arguments to pass to the mount command (e.g., `"-o size=512M"`).

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
