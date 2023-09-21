% kpkg_run(8)

# NAME
kpkg runfile - main package format of kpkg

# DESCRIPTION
kpkg runfiles are the main package format of kpkg. It is a basic shell script with some variables so kpkg can build the package.

# RUNFILE STRUCTURE

Runfiles are just named "run" inside the package directory. It is written in POSIX sh and doesn't support any other languages.

An example runfile structure;

```sh
NAME="test-v3"
VERSION="0.0.1"
RELEASE="1"
SOURCES="https://test.file/source/testfile.tar.gz;git::https://github.com/kreatolinux/src::543ee30eda806029fa9ea16a1f9767eda7cab4d1"
DEPENDS="testpackage1 testpackage3 testpackage4"
DEPENDS_TEST2+="testpackage5 testpackage6"
NO_CHKUPD="n"
REPLACES="test-v2"
OPTDEPENDS="optional-dependency: This is a test optional dependency ;; optional-dependency-2: This is a second optional dependency."
BUILD_DEPENDS="testpackage5 testpackage6 testpackage10"
SHA256SUM="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
DESCRIPTION="Test package"

prepare() {
    tar -xvf testfile.tar.gz
}

build() {
    cd testfile
    echo "Insert build instructions here"
}

check() {
    ninja -C build test
}

package() {
    cd testfile
    make install
}

package_test2() {
    cd testfile
    make install_test2
}

postinstall() {
    echo "Insert postinstall instructions here"
}

postremove() {
    echo "Insert postremove instructions here"
}
```
Now lets break it down.

## VARIABLES
* NAME: Name of your package. Will show this name on the info command.
* VERSION: Version of your package. It will be on the info command and updating it will result in kpkg upgrading the package.
* RELEASE: Release of your package. It will also be on the info command and updating it will result in kpkg upgrading the package.
* SOURCES: Source URL's of your package. Can be seperated by ' ' like `https://test.url https://test.url2`. Also supports git URL's as shown by the second source.
* DEPENDS: Dependencies of your package. Seperated by space. You can also specify versions for your dependencies such as `test<=1.8.1`, `test=1.8.1`, `test>=1.8.1`, `test<1.8.1`, `test>1.8.1`.
* BUILD_DEPENDS: Build dependencies of your package. Seperated by space. 
* SHA256SUM: sha256sum output of the sources. Should align with sources. Can also be seperated by ' '. Doesnt support git URL's yet.
* DESCRIPTION: Description of the package. It will be on the info command.

## FUNCTIONS
* package(): The install function.

## OPTIONAL FUNCTIONS AND VARIABLES
* build(): The main build function. Only time this doesn't need to be used is for things such as binary packages (eg. linux-firmware) that doesn't need to be built.
* EPOCH: Only use this when the versioning logic fail for the package.
* prepare(): Files downloaded from SOURCES are extracted by default. Use prepare() to prevent this and have custom prepare procedure.
* check(): Test the package.
* postinstall(): Post-install function. Will run after the package is installed.
* postremove(): Post-remove function. Will run after the package is removed.
* package_PACKAGENAME(): Install function of PACKAGENAME. With this function you can package multiple things in the same runfile. This may be used for packaging sub-projects easier.
* NO_CHKUPD: Disables autoupdating thru chkupd. False by default. This will not prevent chkupd from building the package. Will be enabled if it is one of these values; "y, yes, true, 1, on"
* REPLACES: Replaces packages put in the variable. Seperated by space.
* OPTDEPENDS: Optional dependencies for the package. Seperated by ';;' like on the example. 
* CONFLICTS: Specify conflicts to the package. Seperated by a space like DEPENDS. 
* IS_GROUP: Specify if the package is a group package or not. False by default. Will be enabled if it is one of these values; "y, yes, true, 1, on"
* DEPENDS_PACKAGENAME: Change PACKAGENAME with the package name. You can add/remove dependencies, depending on the usecase like `DEPENDS_PACKAGENAME+="packagename"`, `DEPENDS_PACKAGENAME-="packagename"`, and you can set the dependencies completely with `DEPENDS_PACKAGENAME="packagename"` 

## VARIABLE NAMING
Runfile variables are case insensitive. They also support popular variable styles such as camelCase, PascalCase, kebab-case and snake_case.

Please keep in mind that functions themselves are NOT case insensitive, and do not support this flexibility.

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
