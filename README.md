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

## kreastrap
Kreastrap v3 is a rootfs building utility.\
It uses kpkg internally to build Kreato Linux systems.\
You can build it by running `make kreastrap`. The binary will be located on `kreastrap/kreastrap`.

## purr
purr is kpkg's testing utility. You can build it by running `make tests`. The binary will be located on the usual `out` folder.

## genpkglist
genpkglist is a runfile -> markdown generator. It is used to generate the [the package list](https://linux.kreato.dev/packages) on the Kreato Linux website.

Build it by running `make genpkglist`. The binary will be located on the usual `out` folder.

## chkupd
chkupd is a tool to check if a package is up-to-date on a kpkg repository. It also has the ability to attempt to autoupdate the package. You can build it by running `make chkupd`. The binary will be located on the usual `out` folder.

## jumpstart
Jumpstart is Kreato Linux's new service manager/init system. It is similar in style to systemd. You can build it by running `make jumpstart`. The binary will be located on the usual `out` folder.

## klinstaller
klinstaller is Kreato Linux's official installer. Unlike other utilities, it is written in sh. It will be available on every Kreato Linux rootfs. you can install it by running `make install_klinstaller`.

## kreaiso
kreaiso is Kreato Linux's ISO image builder. It currently only supports rootfs' that use systemd. More support is coming soon. Build it by running `make kreaiso`. The binary will be located on `kreaiso/kreaiso`.

# Contributing
Please look at [the styling guide](https://linux.kreato.dev/docs/handbook/contributing/styling/) before contributing.

# License
Licensed under GPLv3. Check LICENSE file for details

