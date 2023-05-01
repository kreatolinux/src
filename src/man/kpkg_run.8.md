% kpkg_run(8)

# NAME
kpkg runfile - main package format of kpkg

# DESCRIPTION
kpkg runfiles are the main package format of kpkg. It is a basic shell script with some variables so kpkg can build the package.

# RUNFILE STRUCTURE

Runfiles are just named "run" inside the package directory. It is written in POSIX sh and doesn't support any other languages.
In addition to a runfile you also need a deps file which you can add by just making a file named "deps" in the package repository and putting deps on each line.

An example runfile structure;

```
NAME="test"
VERSION="0.0.1"
RELEASE="1"
SOURCES="https://test.file/source/testfile.tar.gz;git::https://github.com/kreatolinux/kpkg3::543ee30eda806029fa9ea16a1f9767eda7cab4d1"
SHA256SUM="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  testfile.tar.gz"
DESCRIPTION="Test package"

build() {
    tar -xvf testfile.tar.gz
    echo "Insert additional installation instructions here"
}

install() {
    make install
}
```
Now lets break it down.

## VARIABLES
* NAME: Name of your package. Will show this name on the info command.
* VERSION: Version of your package. It will be on the info command and updating it will result in kpkg upgrading the package.
* RELEASE: Release of your package. It will also be on the info command and updating it will result in kpkg upgrading the package.
* SOURCES: Source URL's of your package. Can be seperated by ';' like `test.url;testurl2`. Also supports git URL's as shown by the second source.
* SHA256SUM: sha256sum output of the sources. Should align with sources. Can also be seperated by ';'. Doesnt support git URL's yet.
* DESCRIPTION: Description of the package. It will be on the info command.

## FUNCTIONS
* build: The main function.
* install: The install function.

## OPTIONAL FUNCTIONS AND VARIABLES
* EPOCH: Only use this when the versioning logic fail for the package.
* prepare(): Files downloaded from SOURCES are extracted by default. Use prepare() to prevent this and have custom prepare procedure.

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
