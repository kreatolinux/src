% kreastrap(8)

# NAME
kreastrap - rootfs builder

# SYNOPSIS
**kreastrap** [--buildType] [BUILDTYPE] [--arch] [ARCHITECTURE] [--useCacheIfPossible] [true/false]

# DESCRIPTION
Nyaastrap is a rootfs builder written in Nim. It is currently used for generating rootfs' for Kreato Linux.

Nyaastrap has a simple config structure, and uses `kpkg` internal functions to work.

For the config structure you can see kreastrap.conf(5)

# AUTHOR
Written by Kreato.

# COPYRIGHT
kreastrap is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

kreastrap is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with kreastrap.  If not, see <https://www.gnu.org/licenses/>.
