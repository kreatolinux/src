#!/bin/sh
prefix="./out"
# https://stackoverflow.com/questions/29832037/how-to-get-script-directory-in-posix-sh
srcdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
projects=""
buildType="release"
branch="master"
installDeps="0"

err() {
	echo "$@"
	exit 1
}

buildNimMain() {
  cd "$srcdir"
	if [ "$1" = "chkupd" ]; then
		nim c -d:$buildType $args $target -d:branch=$branch --threads:on -d:ssl -o="$prefix/$1" "$srcdir/$1/$1.nim" || err "building $1 failed"
	else
 		nim c -d:$buildType $args $target --deepcopy:on --passL:-larchive -d:branch=$branch --threads:on -d:ssl -o="$prefix/$1" "$srcdir/$1/$1.nim" || err "building $1 failed"
  fi
  cd - > /dev/null
}

buildNimOther() {
  cd "$srcdir"
	nim c -d:$buildType $args $target --threads:$2 -o="$3" $5 "$srcdir/$1/$4" || err "building $1 failed"
  cd - > /dev/null
}

printHelp() {
	printf """Usage: './build.sh [ARGUMENTS]'
Options:
	-d, --debug: Enable debug on built projects
	-t, --target [ARCHITECTURE]: Set architecture for built binary
	-p, --projects [PROJECTS]: Enable projects, seperate by comma
	-i, --installDeps: Install dependencies before continuing
	-c, --clean: Clean binaries
	-b, --branch [BRANCH]: Set default branch for repositories. 'master' by default.
	-a, --args [ARGUMENTS]: Set arguments for nimc.
"""
}
echo "Kreato Linux - Source tree build script"

if [ "$#" = "0" ]; then
	printHelp
fi

while [ "$#" -gt 0 ]; do
	case $1 in
		-t|--target)
			shift
			target="--cpu:$1"
		;;
		-d|--debug)
			buildType="debug"
		;;
		-p|--projects)
			shift
			projects="$1"
		;;
		-i|--installDeps)
			installDeps="1"
		;;
		-c|--clean)
			echo "Cleaning binaries"
			rm -rf "$prefix"
			rm -f $srcdir/kreastrap/kreastrap
			rm -f $srcdir/kreaiso/kreaiso
		;;
		-b|--branch)
			shift
			branch="$1"
		;;
		-a|--args)
			shift
			args="$1"
		;;
		*)
			printHelp
		;;
	esac
	shift
done

if [ "$installDeps" = "1" ]; then
    nimble install fuzzy futhark@0.12.5 cligen nimcrypto norm fusion -y || err "Installing depndencies failed"
fi

IFS=","
for v in $projects
do
   echo "building $v"
   case $v in
	kpkg | chkupd | purr)
		buildNimMain "$v"
	;;
	jumpstart)
		buildNimOther "jumpstart" "on" "$prefix/jumpstart" "jumpstart.nim"
		buildNimOther "jumpstart" "off" "$prefix/jumpctl" "jumpctl.nim"
	;;
	genpkglist)	
		buildNimOther "genpkglist" "off" "$prefix/genpkglist" "main.nim"
   	;;
	kreastrap)
		buildNimOther "kreastrap" "on" "$srcdir/kreastrap/kreastrap" "kreastrap.nim" "--passL:-larchive -d:branch=$branch -d:ssl"
	;;
	kreaiso)
		buildNimOther "kreaiso" "on" "$srcdir/kreaiso/kreaiso" "kreaiso.nim" "--passL: -larchive -d:branch=$branch -d:ssl"
	;;
	install_klinstaller)
		cp "$srcdir/installer/klinstaller" "$DESTDIR/bin/klinstaller"
		chmod +x "$DESTDIR/bin/klinstaller"
	;;
   esac
done
