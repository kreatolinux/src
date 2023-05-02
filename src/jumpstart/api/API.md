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

### Folder structure
```
/run/serviceHandler/serviceName.service/enable
/run/serviceHandler/serviceName.service/disable
/run/serviceHandler/serviceName.service/stop
/run/serviceHandler/serviceName.service/start
/run/serviceHandler/serviceName.service/status
```
Should explain themselves well enough.
Status uses JSON format.

```json
{
    "status": "healthy" 
}
```

status can have values such as healthy, stopped, killed, exited.