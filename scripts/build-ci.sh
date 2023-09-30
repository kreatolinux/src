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
  		kpkg # Initializes configs
		sed -i s/stable/master/g /etc/kpkg/kpkg.conf # Switch to master repos
		kpkg update
    		kpkg build llvm -y # Required by futhark

  		# Create (and set) locales so libarchive is happy
  		LOCALE=en_US
		mkdir -p /usr/lib/locale
		localedef -i $LOCALE -c -f UTF-8 $LOCALE
		export LANG=$LOCALE.UTF-8
      		
		export PATH=$PATH:$HOME/.nimble/bin # Add nimble path so opir can run
    		
                rm -vf /etc/kpkg/kpkg.conf
                rm -rf /tmp/kpkg

  		./build.sh -i
		nim c -d:branch=master --passL:-larchive --passC:-no-pie --threads:on -d:ssl -o=kreastrap/kreastrap kreastrap/kreastrap.nim
                
		cat /etc/group | grep tty || addgroup tty
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
