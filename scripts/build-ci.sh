#!/bin/sh
# CI build script
#

e() {
    sqlite3 /var/cache/kpkg/kpkg.sqlite .dump
    kpkg info bison
    exit 1
}

case $1 in
        "init")
                if [ "$IS_ACTIONS" = "y" ]; then
                        ln -s "$GITHUB_WORKSPACE" /work
                        git config --global --add safe.directory $GITHUB_WORKSPACE
                fi
               
		            mkdir /out
                ln -s /out /work/out
                cd /work || exit 1
               
                # TEMP
                wget https://github.com/kreatolinux/src/releases/download/v7.1.0/src-v7.1.0-dist.tar.gz
                tar -xvf src-v7.1.0-dist.tar.gz
                cd src-7.1.0 || exit 1
                nimble install cligen fuzzy nimcrypto norm -y
                nim c --deepcopy:on -d:release -d:useDist --passL:-larchive --threads:on -d:ver="$VERSION" -d:ssl -o="out/kpkg" "kpkg/kpkg.nim"
                cp  out/kpkg /bin/kpkg
                # temp end

  	            kpkg # Initializes configs
		        kpkg update
                #kpkg build kpkg -y

                kpkg build bzip2 -y || exit 1
    
                kpkg build python -y || exit 1

		        kpkg build ninja -y
                kpkg build llvm -y # Required by futhark

                #rm -r /var/cache/kpkg/archives/x86_64-linux-gnu-systemd-openssl
                #cp -r /var/cache/kpkg/archives/system/x86_64-linux-gnu-jumpstart-openssl /var/cache/kpkg/archives/system/x86_64-linux-gnu-systemd-openssl # temp, see #100

                
                export PATH=$PATH:$HOME/.nimble/bin # Add nimble path so opir can run
                
  	            kpkg clean -e
                ./build.sh -i
                nim c --deepcopy:on scripts/sqlite.nim
                scripts/sqlite || true

		            nim c -d:branch=master --deepcopy:on --passL:-larchive --passC:-no-pie --threads:on -d:ssl -o=kreastrap/kreastrap kreastrap/kreastrap.nim
                    
                if [ -f "/var/cache/kpkg/kpkg.sqlite" ]; then
                    mkdir -p /var/lib/kpkg
                    cp /var/cache/kpkg/kpkg.sqlite /var/lib/kpkg/kpkg.sqlite
                fi

		            cat /etc/group | grep tty || addgroup tty
        ;;

        "build")
                git config --global --add safe.directory /etc/kpkg/repos/main
                rm -rf /out/*
                cd /work || exit 1				

  		if [ -z "$3" ]; then
			arch="amd64"
		else
			arch="$3"
		fi
  
                ./kreastrap/kreastrap --buildType="$2" --arch="$arch" || e
                cd /out || exit 1
                tar -czvf /work/kreato-linux-"$2"-glibc-"$(date +%d-%m-%Y)"-amd64.tar.gz *
        ;;
esac
