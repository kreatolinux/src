% kpkg.conf(5)

# NAME
kpkg.conf - Configuration file for kpkg

# DESCRIPTION
/etc/kpkg/kpkg.conf is the main configuration file on kpkg. A default one is included when you launch kpkg for the first time.

# SYNTAX
kpkg.conf uses a INI format.
The default configuration file currently looks like this;
```
[Options]
cc=gcc

[Repositories]
RepoDirs=/etc/kpkg/repos/main /etc/kpkg/repos/main-bin
RepoLinks="https://github.com/kreatolinux/kpkg-repo.git https://github.com/kreatolinux/kpkg-repo-bin.git"

[Upgrade]
buildByDefault=yes
```

## OPTIONS
* cc: Set the CC environment variable when the package is building. Defaults to gcc.

## REPOSITORIES
* RepoDirs: Repository directories. Must line up with RepoLinks. Seperate by space.
* RepoLinks: Repository links. Must line up with RepoDirs. Seperate by space. Has kpkg-repo and kpkg-repo-bin repositories by default.

Repositories also support branches/commits like this;

`RepoLinks="https://github.com/kreatolinux/kpkg-repo.git::BRANCHNAME"`

## UPGRADE
* buildByDefault: Enable building by default on upgrades or not. Is enabled by default.

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
