#!/bin/sh
# CI build script
#

e() {
    busybox ls -l /var/cache/kpkg/installed
    busybox ls -l /
    busybox ls -l /bin/sh
    busybox ls -l /bin/
    kpkg provides /bin/sh
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

  		kpkg # Initializes configs
		sed -i s/stable/master/g /etc/kpkg/kpkg.conf # Switch to master repos
		kpkg update
  		rm -f /var/cache/kpkg/archives/arch/amd64/*wget*
      		kpkg build bzip2 -y || exit 1
      		
		kpkg build python -y || exit 1
    		python -m ensurepip -U
		ln -s $(which pip3) /usr/bin/pip
		pip --version || exit 1
    		kpkg build python-pip -y
		pip --version || exit 1

		kpkg build ninja -y
    		kpkg build llvm -y # Required by futhark
    		kpkg build sqlite -y # Required by kpkg audit
            kpkg build bubblewrap -y # Required by kpkg isolation

        
        # Hack to install kreato-fs-essentials until we get a working build
        git clone https://github.com/kreatolinux/src src-old
        cd src-old
        git checkout a8c8e28b73daac823fa029845c7c66891b80d093
		export PATH=$PATH:$HOME/.nimble/bin # Add nimble path so opir can run
        ./build.sh -i
        ./build.sh -d -p kpkg
        ./out/kpkg build p11-kit ca-certificates -y || exit 1
        update-ca-trust || exit 1
        ./out/kpkg build kreato-fs-essentials -y
        ./out/kpkg build pcre bash binutils bison flex gcc gettext glibc gmake gmp grep gtar libffi libtasn m4 mpc mpfr readline texinfo -y || exit 1 # https://github.com/kreatolinux/kpkg-repo/commit/a5891e1b1b1f0645fb48058bc1d015ea54bcbb93
        cd ..
        rm -rf src-old
        
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
  
                ./kreastrap/kreastrap --buildType="$2" --arch="$arch" || e
                cd /out || exit 1
                tar -czvf /work/kreato-linux-"$2"-glibc-"$(date +%d-%m-%Y)"-amd64.tar.gz *
        ;;
esac
