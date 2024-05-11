% kpkg_get(8)

# NAME
kpkg get - kpkg get command

# DESCRIPTION
kpkg get is an advanced command that gets values from multiple kpkg parts including the database, the config, and more.

# SYNOPSIS
kpkg get [OPTION]... [KEY]...

# TYPES
* `db`: Get values from the database.
* `config`: Get values from the config.
* `overrides`: Get value from a package override.

## EXAMPLES
```sh
# List information about file bin/kpkg from the database
kpkg get db.file.bin/kpkg

# List information about package from the database
kpkg get db.package.kpkg

# Get version of package from the database
kpkg get db.package.kpkg.version

# Get Repositories section from the config
kpkg get config.Repositories

# Get override of kpkg
kpkg get overrides.kpkg
```

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
