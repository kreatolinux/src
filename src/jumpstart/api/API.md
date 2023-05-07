# JumpStart internal documentation

## Communication
Communication happens through UNIX sockets. `/run/jumpstart.lock` is the default socket path.

## Interacting with services

The client sends these information onto the socket.

```json
{
    "client": {
        "name": "Jumpstart CLI",
        "version": "0.0.1-alpha"
    },
    
    "service": {
        "name": "test.service",
        "action": "enable",
        "now": "false"
    }    
}
```


Change the action to whatever you want.

If it is supported within Jumpstart, you should see an reply. Unsupported operations are ignored.

## serviceHandler
serviceHandler is the service handler of JumpStart. It manages services.

## Services
Services are parsed using std/parsecfg, which is like ini.

Services are stored in `/etc/jumpstart/services` by default and have the `.service` extension.

```ini
[Service]
execPre="echo 'This will be ran before Exec'"
exec="echo 'this is a test'"
execPost="echo 'This will be ran after the initial command'"

[Settings]
workDir="/tmp/test"
```
