#!/bin/sh
# CI build script
case $1 in
        "init")
                if [ "$IS_ACTIONS" = "y" ]; then
                        ln -s "$GITHUB_WORKSPACE" /work
                        git config --global --add safe.directory $GITHUB_WORKSPACE
                fi
                mkdir /out
                ln -s /out /work/out
                cd /work || exit 1
                #echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d'.' -f1,2 /etc/alpine-release)/main/" > /etc/apk/repositories
                #echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d'.' -f1,2 /etc/alpine-release)/community/" >> /etc/apk/repositories
                #echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories
                #apk update
                #apk add build-base llvm-libunwind-dev compiler-rt libc++-dev alpine-sdk nimble shadow libarchive-tools perl zlib-dev llvm clang linux-headers openssl-dev binutils-dev gettext-dev xz libgcc gcc
                #make kpkg 
                #rm -f /var/cache/kpkg/archives/*kpkg*
	
  		# Temporary
    		wget https://github.com/kreatolinux/src/archive/refs/tags/v6.0.1.tar.gz
      		tar -xvf v6.0.1.tar.gz
		cd src-6.0.1 || exit 1
  		sed -i 's#raise#raise getCurrentException()#g' kpkg/commands/buildcmd.nim || exit 1
  		sed -i s/release/debug/g Makefile
    		cat << EOF > test.patch
      diff --git a/kpkg/commands/installcmd.nim b/kpkg/commands/installcmd.nim
index e117119..eb6e6cb 100644
--- a/kpkg/commands/installcmd.nim.orig
+++ b/kpkg/commands/installcmd.nim
@@ -77,13 +77,6 @@ proc installPkg*(repo: string, package: string, root: string, runf = runFile(
 
     setCurrentDir("/var/cache/kpkg/archives")
 
-    discard existsOrCreateDir(root&"/var/cache")
-    discard existsOrCreateDir(root&"/var/cache/kpkg")
-    discard existsOrCreateDir(root&"/var/cache/kpkg/installed")
-    removeDir(root&"/var/cache/kpkg/installed/"&package)
-    copyDir(repo&"/"&package, root&"/var/cache/kpkg/installed/"&package)
-
-
     for i in pkg.replaces:
         if symlinkExists(root&"/var/cache/kpkg/installed/"&i):
             removeFile(root&"/var/cache/kpkg/installed/"&i)
@@ -91,6 +84,11 @@ proc installPkg*(repo: string, package: string, root: string, runf = runFile(
             removeInternal(i, root)
         createSymlink(package, root&"/var/cache/kpkg/installed/"&i)
 
+    discard existsOrCreateDir(root&"/var/cache")
+    discard existsOrCreateDir(root&"/var/cache/kpkg")
+    discard existsOrCreateDir(root&"/var/cache/kpkg/installed")
+    removeDir(root&"/var/cache/kpkg/installed/"&package)
+    copyDir(repo&"/"&package, root&"/var/cache/kpkg/installed/"&package)
 
     if not isGroup:
         debug "Executing 'tar -hxvf "&tarball&" -C "&root&"'"
EOF
		git apply test.patch || exit 1
    		make deps kpkg
		./out/kpkg update
  		./out/kpkg install xz-utils -y || exit 1
  		./out/kpkg build llvm -y
  		cd ..

      		export PATH=$PATH:$HOME/.nimble/bin
    		make deps
                rm -vf /etc/kpkg/kpkg.conf
                rm -rf /tmp/kpkg
                nim c -d:branch=master --passC:-no-pie --threads:on -d:ssl -o=kreastrap/kreastrap kreastrap/kreastrap.nim
                cat /etc/group | grep tty || addgroup tty
		#make kreastrap
        ;;

        "build")
                git config --global --add safe.directory /etc/kpkg/repos/main
                rm -rf /out/*
                cd /work || exit 1
                ./kreastrap/kreastrap --buildType="$2" --arch=amd64 || exit 1
                cd /out || exit 1
                tar -czvf /work/kreato-linux-"$2"-glibc-"$(date +%d-%m-%Y)"-amd64.tar.gz *
        ;;
esac
