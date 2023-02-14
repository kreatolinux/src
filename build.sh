#!/bin/sh
OUTDIR="$(dirname $0)/out/"
SRCDIR="$(dirname $0)/src/"

run() {
        echo "Running $@"
        "$@"
}

case $1 in
        "kpkg")
                shift
                run nim c -d:release -d:branch=master --threads:on -d:ssl "$@" -o="$OUTDIR" "$SRCDIR/kpkg/kpkg.nim"
        ;;
        "prettify")
                run nimpretty src/*/*/*              
        ;;
        "tests")
                shift
                run nim c -d:release --threads:on -d:ssl "$@" -o="$OUTDIR" "$SRCDIR/purr/purr.nim"
        ;;
        "chkupd")                    
                shift
                run nim c -d:release -d:ssl "$@" -o="$OUTDIR" "$SRCDIR/chkupd/chkupd.nim"              
        ;;
        "kreastrap")
                shift
                run nim c --threads:on -d:ssl "$@" -o="$SRCDIR/kreastrap/kreastrap" "$SRCDIR/kreastrap/kreastrap.nim"
        ;;
        "deps")
                shift
                run nimble install cligen libsha "$@" -y
                ;;
        *)
                echo """./build.sh kpkg: builds kpkg
./build.sh prettify: uses nimpretty to prettify code
./build.sh tests: builds tests
./build.sh chkupd: builds chkupd
./build.sh kreastrap: builds kreastrap
./build.sh deps: Install dependencies through Nimble"""
        ;;
esac
