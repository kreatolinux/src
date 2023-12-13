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
  		#rm -f /var/cache/kpkg/archives/arch/amd64/*meson*
    		kpkg build python -y || exit 1
    		python -m ensurepip
    		kpkg build ninja -y
    		kpkg build llvm -y # Required by futhark

  		kpkg install wget -y
      		wget https://mirror.kreato.dev/aarch64/kpkg-tarball-glibc-2.38-3.tar.gz || exit 1
		wget https://mirror.kreato.dev/aarch64/kpkg-tarball-glibc-2.38-3.tar.gz.sum || exit 1
		mkdir /var/cache/kpkg/archives/aarch64 || exit 1
  		mv kpkg-tarball-glibc-* /var/cache/kpkg/archives/aarch64 || exit 1
  
    		kpkg build sqlite -y # Required by kpkg audit
  
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
				
				if [ -z "$3" ]; then
					arch="amd64"
				else
					arch="$3"
				fi

                ./kreastrap/kreastrap --buildType="$2" --arch="$arch" || exit 1
                cd /out || exit 1
                tar -czvf /work/kreato-linux-"$2"-glibc-"$(date +%d-%m-%Y)"-amd64.tar.gz *
        ;;
esac
