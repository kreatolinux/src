<p align="left">
<img src="https://github.com/Kreato-Linux/logo/blob/master/withtext.png">
</p>

# src
Welcome to the Kreato Linux source tree. The source tree includes everything you need to build, test, and maintain Kreato Linux. 
It includes multiple tools to accomplish this goal. You will find them below.

# Build variables

There are a couple of build variables;

* -d:branch: Repository branch that is gonna be used for the default repositories, is set to `stable` by default

# Projects

## kpkg
`kpkg` is a rewrite of the nyaa2 package manager. It is written in Nim, and is mainly for use with Kreato Linux. 
`kpkg` is heavily inspired by package managers such as `kiss`, `dnf` and `pacman`. Run `make kpkg` to build.

## kreastrap
There is also kreastrap v3, a rootfs building utility.
You can build it by running `make kreastrap`. The binary will be located on `kreastrap/kreastrap`.

## mari
Mari is a very simple http server that uses httpbeast. It is mainly used to run Kreato Linux binary repository. You can build it by running `make mari`. The binary will be located on the usual `out` folder.

## purr
purr is kpkg's testing utility. You can build it by running `make tests`. The binary will be located on the usual `out` folder.

## chkupd
chkupd is a tool to check if a package is up-to-date on a kpkg repository. It also has the ability to attempt to autoupdate the package. You can build it by running `make chkupd`. The binary will be located on the usual `out` folder.

## jumpstart
Jumpstart is Kreato Linux's new service manager/init system. It is similar in style to systemd. You can build it by running `make jumpstart`. The binary will be located on the usual `out` folder.

## klinstaller
klinstaller is Kreato Linux's official installer. Unlike other utilities, it is written in sh. It will be available on every Kreato Linux rootfs. you can install it by running `make install_klinstaller`.

## kreaiso
kreaiso is kreato Linux's ISO image builder. It currently only supports rootfs' that use systemd. More support is coming soon. Build it by running `make kreaiso`. The binary will be located on `kreaiso/kreaiso`

# License
Licensed under GPLv3. Check LICENSE file for details

