<p align="left">
<img src="https://github.com/Kreato-Linux/logo/blob/master/beta.png">
</p>

# src
Welcome to the Kreato Linux source tree. The source tree includes everything you need to build, test, and maintain Kreato Linux. 
It includes multiple tools to accomplish this goal. You will find them below.

# Build variables

There are a couple of build variables;

* -d:branch: Repository branch that is gonna be used for the default repositories, is set to `stable` by default
* -d:ver: Specify version manually. Is set to the major version by default.

# Projects

## kpkg
`kpkg` is a feature-complete package manager, that is a rewrite of nyaa2. It is written in Nim, and is mainly for use with Kreato Linux.\
It is meant to be a much simpler to use package manager compared to the alternatives.\
`kpkg` is heavily inspired by package managers such as `kiss`, `dnf` and `pacman`. Run `make kpkg` to build.

## krep
`krep` is the task-based command for repository maintenance and image builds.
Its implementation lives in `krep/`, including repository commands, image
builders, shared modules, and image data. It replaces kreastrap, chkupd, run3tools, and kreaiso.
Build it with `make krep` or `sh build.sh -p krep`; the binary is `out/krep`.
Image resources are staged under `out/share/krep`.

Tasks are `check`, `update`, `clean`, `lint`, `fmt`, `convert`, `rootfs`, and `iso`.
Generators are `generate matrix`, `generate markdown`, and `generate manpage`.
`check` only checks upstream versions; use the explicit `update` task to modify
package versions and checksums. `fmt` writes files unless `--check` is set.

Install with `make install_krep` (default `PREFIX=/usr/local`). For packaging,
use `make install_krep PREFIX=/usr DESTDIR=/path/to/staging`.
This installs `bin/krep` and `share/krep` below the selected prefix.
Use `--dataDir` on an image task to select that task's assets, or set
`KREP_DATA_DIR` to a unified data root containing `rootfs/` and `iso/`.
Existing configuration formats remain supported. The old standalone tools
and build targets have been removed.
See [krep's guide](krep/README.md) and [krep(8)](man/krep.8.md).

## jumpstart
Jumpstart is Kreato Linux's new service manager/init system. It is similar in style to systemd. You can build it by running `make jumpstart`. The binary will be located on the usual `out` folder.

## klinstaller
klinstaller is Kreato Linux's official installer. Unlike other utilities, it is written in sh. It will be available on every Kreato Linux rootfs. you can install it by running `make install_klinstaller`.

# Contributing
Please look at [the styling guide](https://linux.krea.to/docs/handbook/contributing/styling/) before contributing.

# License
Licensed under GPLv3. Check LICENSE file for details

