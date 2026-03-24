# ssh-tunnel

Manage SSH tunnels through the Larimar daemon.

## Tools

### Check tunnel status
```bash
larimar status
```

### Connect a specific tunnel
```bash
larimar connect <tunnel-id>
```

### Disconnect a specific tunnel
```bash
larimar disconnect <tunnel-id>
```

### Connect all tunnels
```bash
larimar connect --all
```

### Disconnect all tunnels
```bash
larimar disconnect --all
```

### List configured tunnels
```bash
larimar list
```

## Usage Notes

- The Larimar daemon (menu bar app) must be running for these commands to work.
- Tunnel IDs are defined in `~/.config/larimar/tunnels.toml`.
- SSH connection details (user, port, key, ProxyJump, etc.) are delegated to `~/.ssh/config`.
- If using 1Password SSH Agent, TouchID will be prompted automatically on first connection.
