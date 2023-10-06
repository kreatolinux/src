% kpkg.conf(5)

# NAME
kpkg.conf - Configuration file for kpkg

# DESCRIPTION
/etc/kpkg/kpkg.conf is the main configuration file on kpkg. A default one is included when you launch kpkg for the first time.

# SYNTAX
kpkg.conf uses a INI format.
The default configuration file currently looks like this;

```ini
[Options]
cc=gcc
cxx=g++
ccache=false

[Repositories]
repoDirs=/etc/kpkg/repos/main /etc/kpkg/repos/lockin
repoLinks="https://github.com/kreatolinux/kpkg-repo.git::stable https://github.com/kreatolinux/kpkg-repo-lockin.git::stable"
binRepos="mirror.kreato.dev"

[Parallelization]
threadsUsed="1"

[Upgrade]
buildByDefault=yes
```

## OPTIONS
* cc: Set the CC environment variable when the package is building. Defaults to gcc.
* cxx: Set the CXX environment variable when the package is building. Defaults to g++.
* ccache: Boolean to enable ccache. Defaults to `false`. Will only have an effect if ccache is installed.
* cxxflags: Sets the CXXFLAGS environment variable on build. Defaults to nothing.
* cflags: Sets the CFLAGS environment variable on build. Defaults to nothing.

## REPOSITORIES
* repoDirs: Repository directories. Must line up with repoLinks. Seperate by space.
* repoLinks: Repository links. Must line up with repoDirs. Seperate by space. Has kpkg-repo and kpkg-repo-lockin repositories by default.
* binRepos: Binary repository links. Is independent from repoDirs/repoLinks. Seperate by space. Will only accept repositories using HTTPS.

Repositories also support branches/commits like this;

`repoLinks="https://github.com/kreatolinux/kpkg-repo.git::BRANCHNAME"`

## PARALLELIZATION
kpkg now supports parallelization, allowing for much faster binary package installations. This feature is only on the `install` command for now.

Please keep in mind that parallelization is in an alpha state and is not stable. It may hang at times.

* threadsUsed: You can set threads used to download packages. Set to 1 to disable parallelization. Number must be higher than 1. Defaults to 1.

## UPGRADE
* buildByDefault: Boolean to build on upgrades or not. Is enabled by default.
* dontUpgrade: Optional. You can set packages that shouldn't be upgraded. Seperate by space.

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
