% kpkg-target(5)

# NAME
kpkg-target - kpkg target format

# DESCRIPTION
kpkg-target is a target format based on the popular target format. It adds additional info that are a part of the base system.
kpkg-target is used at various parts of kpkg.

# SYNTAX
kpkg-target is very similar to the target format.
It is a line that has 5 parts, seperated by `-`.
An example kpkg target look like this;

`x86_64-linux-gnu-systemd-openssl`

First part is for the architecture, second part is for the OS, third part is for the toolchain, fourth part is for the init system, last part is for the TLS library.

# WHY
kpkg-target is created to easily identify and store system information, and rebuild packages with additional support when necessary.

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
