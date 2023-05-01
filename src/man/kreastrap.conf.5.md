% kreastrap.conf(5)

# NAME
kreastrap.conf - Configuration file for kreastrap v3

# DESCRIPTION
kreastrap.conf is the configuration file for kreastrap. It is put on `arch/ARCHITECTURE/configs/buildTypeName.conf`.

# SYNTAX
kreastrap.conf uses a INI format.
An example configuration file looks like this;
```
[General]
BuildDirectory=/out
BuildPackages=yes

[Core]
Libc=glibc
Compiler=gcc
Coreutils=busybox
TlsLibrary=openssl

[Extras]
ExtraPackages="gmake nim"
```

## GENERAL
* BuildDirectory: Sets the directory the rootfs is gonna be built on.
* BuildPackages: Sets if you want to build the packages or download them from a binary repository.

## CORE
* Libc: Choose the C library. Available options include musl and glibc.
* Compiler: Choose the compiler that will be included in the rootfs. Available options include gcc and clang. You can also specify "no" to not include a compiler.
* Coreutils: Choose the coreutils that will be included in the rootfs. Available options include gnu and busybox. Busybox is the most well-tested one yet.
* TlsLibrary: Choose the tls library that will be used in the rootfs. Available options include openssl and libressl. Libressl is not tested yet.

## EXTRAS
* ExtraPackages: Choose extra packages that will be installed onto the rootfs. Seperate them by space.

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
