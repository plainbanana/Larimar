# Larimar

A macOS menu bar app for managing SSH tunnels. Supports local (`-L`), remote (`-R`), and dynamic/SOCKS (`-D`) forwarding.

Larimar runs as a menu bar daemon, manages SSH tunnel processes, and exposes a CLI for scripting and integration with tools like Claude Code.

## Features

- **Menu bar app** — lives in the macOS menu bar (no Dock icon), toggle tunnels with a click
- **CLI** — `larimar status`, `larimar connect`, `larimar disconnect` for scripting and automation
- **Auto-reconnect** — exponential backoff with jitter, instant retry on network recovery via `NWPathMonitor`
- **Config file watching** — edit `tunnels.toml` and changes are picked up automatically
- **SSH config delegation** — user, port, key, ProxyJump, etc. are all managed in `~/.ssh/config`
- **1Password SSH Agent** — works out of the box; TouchID is prompted automatically via the agent
- **Launch at Login** — toggle from the menu bar via `SMAppService`
- **Claude Code skill** — included example skill for AI-driven tunnel management

## Requirements

- macOS 13.0+
- Swift 5.9+ (included with Xcode Command Line Tools)
- SSH client (`/usr/bin/ssh`)

## Install

```bash
git clone https://github.com/plainbanana/Larimar.git
cd larimar
make install
```

This installs:
- `~/Applications/Larimar.app` — the menu bar daemon
- `~/.local/bin/larimar` — the CLI tool (ensure `~/.local/bin` is in your `PATH`)

## Uninstall

```bash
make uninstall
```

## Configuration

Create `~/.config/larimar/tunnels.toml` (or click "Edit Configuration..." from the menu bar):

```toml
[defaults]
bind_address = "127.0.0.1"
auto_connect = false
auto_reconnect = true

# Optionally set 1Password SSH Agent socket explicitly
# ssh_auth_sock = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

[tunnels.my-service]
local_port = 9022
remote_port = 9022
forward_host = "localhost"
ssh_host = "bastion"        # Host alias from ~/.ssh/config
auto_connect = true

[tunnels.dev-db]
local_port = 5432
remote_port = 5432
forward_host = "db.internal"
ssh_host = "bastion"

# Remote forwarding: expose local port 3000 on the remote server as port 8080
[tunnels.expose-dev]
mode = "remote"
local_port = 3000
remote_port = 8080
ssh_host = "bastion"

# Dynamic forwarding: SOCKS proxy on local port 1080
[tunnels.socks-proxy]
mode = "dynamic"
local_port = 1080
ssh_host = "bastion"
```

SSH connection details (user, port, identity file, ProxyJump, etc.) should be configured in `~/.ssh/config`, not in `tunnels.toml`. Larimar invokes `ssh` directly and inherits your SSH config.

### Tunnel options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `mode` | string | `"local"` | Forwarding mode: `"local"` (`-L`), `"remote"` (`-R`), or `"dynamic"` (`-D` SOCKS proxy) |
| `local_port` | int | (required) | Local port |
| `remote_port` | int | (required\*) | Remote port (\*not required for dynamic mode) |
| `forward_host` | string | `"localhost"` | Destination host for forwarding |
| `ssh_host` | string | (required) | SSH host or `~/.ssh/config` Host alias |
| `bind_address` | string | `"127.0.0.1"` | Bind address (local side for `-L`/`-D`, remote side for `-R`) |
| `auto_connect` | bool | `false` | Connect automatically when daemon starts |
| `auto_reconnect` | bool | `true` | Reconnect on disconnection with exponential backoff |
| `ssh_user` | string | — | Override SSH user (prefer `~/.ssh/config`) |
| `ssh_port` | int | — | Override SSH port (prefer `~/.ssh/config`) |

**SSH commands per mode:**
- **Local** (`-L`): `ssh -L bind_address:local_port:forward_host:remote_port` — listen locally, forward to remote
- **Remote** (`-R`): `ssh -R bind_address:remote_port:forward_host:local_port` — listen on remote, forward to local
- **Dynamic** (`-D`): `ssh -D bind_address:local_port` — local SOCKS proxy

## CLI Usage

```bash
larimar status              # Show all tunnel statuses
larimar list                # List configured tunnels
larimar connect my-service  # Connect a specific tunnel
larimar disconnect my-service
larimar connect --all       # Connect all tunnels
larimar disconnect --all    # Disconnect all tunnels
```

The CLI communicates with the daemon via a Unix domain socket at `~/Library/Application Support/Larimar/larimar.sock`. The daemon must be running.

## Architecture

```
LarimarDaemon (menu bar app)
├── TunnelManager — spawns/monitors/kills ssh -N -L/-R/-D processes
├── IPCServer — Unix domain socket, one JSON request/response per connection
├── ConfigWatcher — DispatchSource file monitoring
└── NetworkMonitor — NWPathMonitor for connectivity changes

LarimarCLI (larimar)
└── IPCClient — connects to daemon socket, sends commands

~/.config/larimar/tunnels.toml → tunnel definitions
~/.ssh/config → SSH connection details (delegated)
```

### Tunnel state machine

```
Stopped → Connecting → Connected
Connected → (process died) → Reconnecting → Connecting
Connected → (disconnect) → Stopped
Reconnecting → (max backoff 300s) → Reconnecting
Any → (disconnect) → Stopped
```

## Nix

### Build with Nix

```bash
nix build                    # builds CLI + app bundle
ls result/bin/larimar
ls result/Applications/Larimar.app
```

### Development shell

```bash
nix develop                  # shell with swift-format
```

### home-manager module

Add Larimar to your flake inputs and import the module for declarative tunnel management with launchd auto-start and Spotlight integration:

```nix
# flake.nix
inputs.larimar.url = "github:plainbanana/Larimar";

# home.nix
imports = [ inputs.larimar.homeManagerModules.default ];

services.larimar = {
  enable = true;
  package = inputs.larimar.packages.aarch64-darwin.default;

  defaults = {
    bind_address = "127.0.0.1";
    auto_reconnect = true;
  };

  tunnels = {
    my-service = {
      local_port = 9022;
      remote_port = 9022;
      forward_host = "localhost";
      ssh_host = "bastion";
      auto_connect = true;
    };
    socks-proxy = {
      mode = "dynamic";
      local_port = 1080;
      ssh_host = "bastion";
    };
  };
};
```

This generates `~/.config/larimar/tunnels.toml`, registers a launchd agent, symlinks `Larimar.app` to `~/Applications` for Spotlight, and adds `larimar` to `PATH`.

> **Note:** When managed by home-manager, the in-app "Launch at Login" toggle is disabled and shows "Managed by launchd (home-manager)". Auto-start is handled by the launchd agent instead of SMAppService to avoid double-start on login.

## Claude Code Integration

An example Claude Code skill is included in `examples/ssh-tunnel/SKILL.md`. Copy it to your skills directory to let Claude manage tunnels via the CLI.

## License

MIT
