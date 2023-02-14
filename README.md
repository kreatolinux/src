<p align="left">
<img src="https://github.com/Kreato-Linux/logo/blob/master/withtext.png"> 
  <img src="https://github.com/Kreato-Linux/logo/blob/master/core.png" height="10%" width="10%">
</p>

# src
Welcome to the Kreato Linux source tree. The source tree includes everything you need to build, test, and maintain Kreato Linux. 
It includes multiple tools to accomplish this goal. You will find them below.

# Build variables

There are a couple of build variables;

* -d:branch: Repository branch that is gonna be used for the default repositories, is set to `stable` by default

# Projects

## kpkg
`kpkg` is a rewrite of the `nyaa` package manager. It is written in Nim, and is mainly for use with Kreato Linux. 
`kpkg` is heavily inspired by package managers such as `kiss`, `dnf` and `pacman`. Run `nimble kpkg` to build.

## nyaastrap
nyaa3 also includes nyaastrap v3, a rootfs building utility.
You can build it by running `nimble nyaastrap`. The binary will be located on `src/nyaastrap/nyaastrap`.

## purr
purr is nyaa3's testing utility. You can build it by running `nimble tests`. The binary will be located on the usual `out` folder.

## chkupd
chkupd is a tool to check if a package is up-to-date on a nyaa repository. It also has the ability to attempt to autoupdate the package. You can build it by running `nimble chkupd`. The binary will be located on the usual `out` folder.

# License
Licensed under GPLv3. Check LICENSE file for details

