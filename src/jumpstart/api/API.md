# JumpStart internal documentation

## Enabling services

Send to `/run/jumpstart.lock`

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

