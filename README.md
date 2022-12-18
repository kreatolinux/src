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

# License
Licensed under GPLv3. Check LICENSE file for details

