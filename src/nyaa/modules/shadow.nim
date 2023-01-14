proc addUser(name: string, path="/"): bool =
    ## Adds an user.
    var cmd: string

    if path == "/":
        cmd = "useradd -M -r -s /bin/nologin "&name 
    else:
        cmd = "chroot "&path&" /usr/sbin/useradd -M -r -s /bin/nologin "&name"

    if execShellCmd(cmd) == 0:
        return true
    else:
        return false


proc existsUser(name: string): bool =
    ## Checks if an user exists.
    if execShellCmd("id "&name) == 0:
        return true
    else:
        return false
