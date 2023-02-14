#!/bin/sh
OUTDIR="./out/"
SRCDIR="./src/"

case $1 in
        "kpkg")
                nim c -d:release -d:branch=master --threads:on -d:ssl -o="$OUTDIR" "$SRCDIR/kpkg/kpkg.nim"
        ;;
        "prettify")
                nimpretty src/*/*/*              
        ;;
        "tests")
                nim c -d:release --threads:on -d:ssl -o="$OUTDIR" "$SRCDIR/purr/purr.nim"
        ;;
        "chkupd")                    
                nim c -d:release -d:ssl -o="$OUTDIR" "$SRCDIR/chkupd/chkupd.nim"              
        ;;
        "kreastrap")
                nim c --threads:on -d:ssl -o="$SRCDIR/kreastrap/kreastrap" "$SRCDIR/kreastrap/kreastrap.nim"
        ;;
        "deps")
                nimble install cligen libsha -y
                ;;
        *)
                echo """./build.sh kpkg: builds kpkg
./build.sh prettify: uses nimpretty to prettify code
./build.sh chkupd: builds chkupd
./build.sh kreastrap: builds kreastrap
./build.sh deps: Install dependencies through Nimble"""
        ;;
esac
