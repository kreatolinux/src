% chkupd.cfg(5)

# NAME
chkupd.cfg - Per package configuration file for chkupd.

# DESCRIPTION
PACKAGEPATH/chkupd.cfg is a per package configuration file for chkupd. It is used to configure the behavior of chkupd for a specific package. If a configuration file is not found, chkupd will use the arguments passed to it.

# SYNTAX
chkupd.cfg uses a INI format.
There is no default configuration file, but you can create one in the package directory.
An example configuration file is below.

```ini
[autoUpdater]
mechanism="githubReleases"
trimString="v"

[githubReleases]
repo="kreatolinux/kpkg"
```

## AUTOUPDATER
* mechanism: The mechanism to use for checking for updates. Defaults to whatever is used while running `chkupd`.
* trimString: String to trim from the version string. Defaults to nothing.

## GITHUBRELEASES
* repo: The repository to check for updates. Must be in the format of `username/repo`.

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
