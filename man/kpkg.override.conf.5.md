% kpkg.override.conf(5)

# NAME
override.conf - Configuration file for kpkg packages

# DESCRIPTION
Override configs allow you to override package information on a specific package. Override configs reside in `/etc/kpkg/override` with the package name as the filename. (such as `/etc/kpkg/override/bash.conf`).

# SYNTAX
override.conf uses an INI format like kpkg.conf(5).
A full override.conf file might look something like this;

```ini
[Flags]
extraArguments="--disable-static --prefix=/usr/test"
cflags="-march=native"
cxxflags="-march=native"

[runFile]
sources="https://mirror.kreato.dev/bash.tar.gz"
sha256sum="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

[Mirror]
sourceMirror="mirror.kreato.dev/beta/sources"
binaryMirrors="mirror.kreato.dev/beta"

[Other]
ccache=false
```

## FLAGS
* extraArguments: Extra arguments for the configuration utility (configure, meson, cmake). Defaults to nothing.
* cxxflags: Sets the CXXFLAGS environment variable on build. Defaults to whatever set in kpkg.conf(5).
* cflags: Sets the CFLAGS environment variable on build. Defaults to whatever set in kpkg.conf(5).

## RUNFILE
All runFile variables apply, see kpkg_run(8). Keep in mind that while you can override existing variables, you can't create new variables that don't exist on the runFile.

## MIRROR
* sourceMirror: Source code mirror for build command. Will only be used if the main URL fails. Set to `false` to disable. Defaults to whatever set in kpkg.conf(5).
* binaryMirrors: List of binary repositories. Defaults to whatever set in kpkg.conf(5). 

## OTHER
* ccache: Disable or enable ccache. Defaults to whatever set in kpkg.conf(5).

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
