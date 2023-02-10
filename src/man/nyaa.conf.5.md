% nyaa.conf(5)

# NAME
nyaa.conf - Configuration file for nyaa3

# DESCRIPTION
/etc/nyaa.conf is the main configuration file on nyaa3. A default one is included when you launch nyaa3 for the first time.

# SYNTAX
nyaa.conf uses a INI format.
The default configuration file currently looks like this;
```
[Options]
cc=gcc

[Repositories]
RepoDirs=/etc/nyaa /etc/nyaa-bin
RepoLinks="https://github.com/kreatolinux/nyaa-repo.git https://github.com/kreatolinux/nyaa-repo-bin.git"

[Upgrade]
buildByDefault=yes
```

## OPTIONS
* cc: Set the CC environment variable when the package is building. Defaults to gcc.

## REPOSITORIES
* RepoDirs: Repository directories. Must line up with RepoLinks. Seperate by space.
* RepoLinks: Repository links. Must line up with RepoDirs. Seperate by space. Has nyaa-repo and nyaa-repo-bin repositories by default.

Repositories also support branches/commits like this;

`RepoLinks="https://github.com/kreatolinux/nyaa-repo.git::BRANCHNAME"`

## UPGRADE
* buildByDefault: Enable building by default on upgrades or not. Is enabled by default.

# AUTHOR
Written by Kreato.

# COPYRIGHT
nyaa is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

nyaa is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with nyaa.  If not, see <https://www.gnu.org/licenses/>.
