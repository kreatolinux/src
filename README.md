<p align="left">
<img src="https://github.com/Kreato-Linux/logo/blob/master/withtext.png"> 
  <img src="https://github.com/Kreato-Linux/logo/blob/master/pkg.png" height="10%" width="10%">
</p>

# nyaa3
`nyaa3` is a rewrite of the `nyaa` package manager. It is written in Nim, and is mainly for use with Kreato Linux.
`nyaa3` is heavily inspired by package managers such as `kiss`, `dnf` and `pacman`.

# Why?
Speed, code readability and efficiency get harder and harder on shell and i consider nyaa2 to be a complete project.

# Building and installation
Installation is done by choosing to install the `nyaa` package manager on `nyaastrap`.

You can also build through `nimble`.
Please note that using `nyaa3` in a environment other than Kreato Linux is not supported, and support will not be given.
We recommend using the ssl task to build since repositories that nyaa3 is configured with need SSL.
Run `nimble ssl` to build, and `nimble install` to install.

nyaa3 also includes optional utilities in its source tree. These are use nyaa3's library functions which is why they are on nyaa3's source tree.

There are a couple of build variables;

* -d:branch: Repository branch that is gonna be used for the default repositories, is set to `stable` by default

You can find how to build/use them below.

## nyaastrap
nyaa3 also includes nyaastrap v3, a rootfs building utility.
You can build it by running `nimble nyaastrap`. The binary will be located on `src/nyaastrap/nyaastrap`.

## purr
purr is nyaa3's testing utility. You can build it by running `nimble tests`. The binary will be located on the usual `out` folder.

## chkupd
chkupd is a tool to check if a package is up-to-date on a nyaa repository. It also has the ability to attempt to autoupdate the package. You can build it by running `nimble chkupd`. The binary will be located on the usual `out` folder.

# License
Licensed under GPLv3. Check LICENSE file for details

