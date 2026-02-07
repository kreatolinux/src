% kpkg_run(5)

# NAME
kpkg runfile - Main package format of kpkg

# DESCRIPTION
kpkg runfiles are the main package format of kpkg. They are basic scripts with specific variables and functions that enable kpkg to build packages.

# RUNFILE STRUCTURE
Runfiles are simply named `run3` and must be placed inside the package directory. It is using Kongue under the hood, see kongue(5).

## Example Runfile

```bash
name: "test-v3"
version: "0.0.1"
release: "1"
sources: 
    - "https://test.file/source/testfile.tar.gz"
    - "git::https://github.com/kreatolinux/src::543ee30eda806029fa9ea16a1f9767eda7cab4d1"
    - "https://test.file/sources/v${version.split('.')[0:2].join('.')}/testfile.tar.gz"
depends: 
    - "testpackage1" 
    - "testpackage3" 
    - "testpackage4"
depends test2: 
    - "testpackage5" 
    - "testpackage6"
no_chkupd: false
replaces: 
    - "test-v2"
backup: 
    - "etc/test-v3/main.conf"
    - "etc/test/settings.conf"
opt_depends:
    - "optional-dependency: This is a test optional dependency"
    - "optional-dependency-2: This is a second optional dependency."
build_depends: 
    - "testpackage5" 
    - "testpackage6" 
    - "testpackage10"
sha256sum: 
    - "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    - "SKIP"
    - "ab37404db60460d548e22546a83fda1eb6061cd8b95e37455149f3baf6c5fd38"
sha512sum:
    - "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e" 
    - "SKIP"  
    - "fce866720603d30cbefe5c0df9c6bacf70cbdb27caef5bcf15f125901cb23a9681ec9f87410a7d2f763af5a89c2b4e43685196ce3b0674868bf81cb3688e47c8"
b2sum: 
    - "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
    - "SKIP" 
    - "64fed8bce19ef14ed2d8434229dc2ec5307e06205610b1859b81b8090ae5ba7001988de896ff4878a15a7b7334e4a06e5889270b2e755fe130f7c80960e66ba2"
license:
    - "GPL-3.0-or-later"
description: "Test package"

func custom_func {
    print "This is a test custom function"
}

prepare {
    custom_func # We can run custom functions just like commands
    env TEST=1
    exec tar -xvf testfile.tar.gz
    # Or you can use:
    # macro extract --autocd=true
    # to extract all the archives in sources.
}

build {
    cd testfile
    echo "Insert build instructions here"
}

check {
    macro test --ninja
    # exec ninja -C build test
}

preupgrade {
    echo "run before upgrade"
}

preinstall {
    echo "run before first install"
}

package {
    cd testfile
    macro package --meson
}

package test2 {
    cd testfile
    exec make install_test2 # External commands require exec
}

postinstall {
    echo "Insert postinstall instructions here"
}

postupgrade {
    echo "run after upgrade"
}

postremove {
    echo "Insert postremove instructions here"
}
```

# SYNTAX AND LANGUAGE FEATURES

## BUILTIN COMMANDS
These are the built-in commands available in the runfile environment in addition to the default Kongue built-in commands (see kongue(5) for those):

* **macro**: Use macros specifically made for extracting, building, packaging, and testing packages. Supported build systems include cmake, ninja, meson, and GNU Automake. Usage: `macro [NAME] [FLAGS]`

## MACROS
Macros are helper commands that simplify common build operations. They are invoked using `macro [NAME] [FLAGS]`.

### EXTRACT MACRO
Extracts all archive files in the current directory.

Usage: `macro extract [--autocd=true|false]`

Flags:
* **--autocd**: When `true`, automatically changes into the extracted directory if there is exactly one directory after extraction. Default is `false`.

Supported archive formats: `.tar`, `.gz`, `.tgz`, `.xz`, `.txz`, `.bz2`, `.tbz2`, `.zip`

Example:
```bash
prepare {
    macro extract --autocd=true
}
```

This is useful when you need to manually control the extraction process in the `prepare` function instead of relying on automatic extraction.

### BUILD MACRO
Runs build commands based on the specified build system.

Usage: `macro build [--meson|--cmake|--ninja|--make|--autotools|--configure][=DIR] [FLAGS]`

Flags:
* **--meson**, **--cmake**, **--ninja**, **--make**, **--autotools**, **--configure**: Specifies the build system. Can optionally take a directory path (e.g., `--meson=..` or `--meson ..`) where the build files or configure script are located. Defaults to the current directory (`.`).
* **--prefix**: Installation prefix (default: `/usr`).
* **--autocd**: If `true`, automatically changes into the directory.

Any other flags are passed directly to the underlying build system.

Example:
```bash
build {
    macro build --meson=.. -Dfeature=enabled
}
```

### PACKAGE MACRO
Runs installation commands based on the specified build system.

Usage: `macro package [--meson|--cmake|--ninja|--make|--autotools|--configure] [FLAGS]`

Flags:
* **--prefix**: Installation prefix (default: `/usr`).

### TEST MACRO
Runs the test suite based on the specified build system.

Usage: `macro test [--meson|--cmake|--ninja|--make|--autotools|--configure] [FLAGS]`


## REQUIRED VARIABLES
* **name**: Name of your package. Displayed in info command output.
* **version**: Version of your package. Displayed in info command output. Updating this will trigger package upgrade.
* **release**: Release number of your package. Displayed in info command output. Updating this will trigger package upgrade.
* **description**: Description of the package. Displayed in info command output.

## REQUIRED FUNCTIONS
* **package**: The installation function that defines how the package should be installed.

## SOURCE AND DEPENDENCY VARIABLES
* **sources**: Source URLs of your package. Can be specified as a list. Supports git URLs as shown in the example.
* **depends**: Runtime dependencies of your package. Supports version specifications like:
  - `test<=1.8.1`: Less than or equal to version 1.8.1
  - `test=1.8.1`: Exactly version 1.8.1
  - `test>=1.8.1`: Greater than or equal to version 1.8.1
  - `test<1.8.1`: Less than version 1.8.1
  - `test>1.8.1`: Greater than version 1.8.1
* **build_depends**: Build-time dependencies of your package.
* **depends packagename**: Specify dependencies for a specific sub-package. The space-separated syntax is preferred, but the legacy underscore syntax (`depends_packagename:`) is also supported for backward compatibility. Can be modified using:
  - `depends packagename+: "packagename"` to add a dependency
  - `depends packagename-: "packagename"` to remove a dependency
  - `depends packagename: "packagename"` to replace dependencies completely

## CHECKSUM VARIABLES
* **sha256sum**: SHA-256 checksums of the sources. Should align with the sources in order.
* **sha512sum**: SHA-512 checksums of the sources. Should align with the sources in order.
* **b2sum**: BLAKE2 checksums of the sources. Should align with the sources in order.

Do mind that Git repositories don't have the checksum ability. You can use `SKIP` for git sources as this value is ignored.

## OPTIONAL VARIABLES
* **epoch**: Only use when versioning logic fails for the package.
* **no_chkupd**: Disables auto-updating through chkupd. Default is `false`. 
* **extract**: Controls whether source archives are automatically extracted before building. Default is `true`. Set to `false` for packages that handle extraction manually or don't need it.
* **autocd**: Controls whether kpkg automatically changes into the extracted directory after extraction. Default is `true` when `extract` is `true`, and `false` when `extract` is `false`. When enabled and there is exactly one directory after extraction, kpkg will automatically `cd` into it.
* **replaces**: Specifies packages that this package replaces.
* **opt_depends**: Optional dependencies for the package, with description after colon.
* **conflicts**: Specifies packages that conflict with this package.
* **is_group**: Indicates if the package is a group package. Default is `false`.
* **backup**: Preserves files (such as configuration files) during upgrades. Don't include leading slash (use `etc/bluetooth/main.conf` instead of `/etc/bluetooth/main.conf`).
* **license**: List of SPDX license identifiers for the package (e.g., "MIT", "GPL-3.0-or-later", "Apache-2.0").

## OPTIONAL FUNCTIONS
* **build**: Main build function. Only optional for packages that don't need to be built (e.g., binary-only packages).
* **prepare**: Custom preparation procedure. Files from sources are extracted by default unless this function is defined.
* **check**: Function to test the package.
* **preinstall**: Runs when the package is installed for the first time (not during upgrades).
* **postinstall**: Runs after the package is installed.
* **preupgrade**: Runs before an upgrade occurs.
* **postupgrade**: Runs after an upgrade completes.
* **postremove**: Runs after the package is removed.
* **package packagename**: Installation function for a sub-package. Allows packaging multiple components in the same runfile. The space-separated syntax is preferred, but the legacy underscore syntax (`package_packagename {}`) is also supported for backward compatibility.

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
