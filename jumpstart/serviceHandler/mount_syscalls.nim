## mount(2)/umount2(2) for native mount units.
##
## The bindings now live in jumpstartcore/mounts, shared with the initramfs init
## and anything else that needs to mount a filesystem. This module is kept as the
## daemon-side import point so serviceHandler code does not need to know where
## the implementation sits; it also keeps the non-Linux stubs (ENOSYS) that let
## the native backend and its tests build on development hosts.

import jumpstartcore/mounts
export mounts
