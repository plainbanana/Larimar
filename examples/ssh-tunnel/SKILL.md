---
name: ssh-tunnel
description: "Manage SSH tunnels through the Larimar daemon. Connect, disconnect, check status, list tunnels, set hints, and request forwards from a remote host."
allowed-tools: Bash(larimar *)
argument-hint: [connect|disconnect|status|list] [tunnel-id]
---

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

### Set or clear a hint
```bash
larimar hint <tunnel-id> "PR #123 review"
larimar hint <tunnel-id> --clear
```

### Remove a dynamic forward
```bash
larimar remove <dyn:id>
```

## On a remote host (no larimar installed)

When the control socket is enabled for the host, request a forward with curl. The user must approve new forwards on the Mac.

```bash
S="$HOME/.larimar/control.sock"
curl -s --unix-socket "$S" -X POST http://larimar/v1/forwards \
  -H 'Content-Type: application/json' \
  -d '{"app":"someapp","remote_port":4980,"hint":"PR #123 review"}'
curl -s --unix-socket "$S" http://larimar/v1/forwards
curl -s --unix-socket "$S" -X POST http://larimar/v1/forwards/<id>/hint \
  -H 'Content-Type: application/json' -d '{"hint":"PR #124 review"}'
curl -s --unix-socket "$S" -X DELETE http://larimar/v1/forwards/<id>
```

## Usage Notes

- The Larimar daemon (menu bar app) must be running for these commands to work.
- Tunnel IDs are defined in `~/.config/larimar/tunnels.toml`.
- SSH connection details (user, port, key, ProxyJump, etc.) are delegated to `~/.ssh/config`.
- If using 1Password SSH Agent, TouchID will be prompted automatically on first connection.
