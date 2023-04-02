#!/bin/sh
# CI build script
case $1 in
        "init")
                if [ "$IS_ACTIONS" = "y" ]; then
                        ln -s "$GITHUB_WORKSPACE" /work
                fi
                mkdir /out
                ln -s /out /work/out
                cd /work || exit 1
                echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d'.' -f1,2 /etc/alpine-release)/main/" > /etc/apk/repositories
                echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d'.' -f1,2 /etc/alpine-release)/community/" >> /etc/apk/repositories
                echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories
                apk update
                apk add alpine-sdk nimble shadow libarchive-tools perl zlib-dev llvm clang linux-headers openssl-dev xz
                make deps
                make kpkg
                #./out/kpkg update || true
                #sed s/gcc/musl-gcc/g -i /etc/kpkg/kpkg.conf
                make kreastrap
        ;;

        "build")
                rm -rf /out/*
                cd /work || exit 1
                ./src/kreastrap/kreastrap rootfs --buildType="$2" --arch=amd64
                cd /out || exit 1
                tar -czvf /work/kreato-linux-"$2"-musl-"$(date +%d-%m-%Y)"-amd64.tar.gz *
        ;;
esac
