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
- **Remote forward requests** — allowed remote hosts can ask for new forwards with `curl`, each new forward requires your approval
- **Hints and grouping** — group tunnels by app (e.g. someapp, otherapp) and show what each port is currently used for
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
| `app` | string | — | Group name shown in the menu (`a-z 0-9 . _ -`, max 32), e.g. `"someapp"` |

**SSH commands per mode:**
- **Local** (`-L`): `ssh -L bind_address:local_port:forward_host:remote_port` — listen locally, forward to remote
- **Remote** (`-R`): `ssh -R bind_address:remote_port:forward_host:local_port` — listen on remote, forward to local
- **Dynamic** (`-D`): `ssh -D bind_address:local_port` — local SOCKS proxy

Every ssh process Larimar starts is run with `-o ControlMaster=no -o ControlPath=none -o ForkAfterAuthentication=no`, so connection sharing from `~/.ssh/config` is not used. This guarantees that disconnecting a tunnel actually tears down its forward.

Tunnel ssh processes also get `-o PermitLocalCommand=yes -o LocalCommand="echo larimar-ready"`. ssh runs `LocalCommand` only after authentication succeeds, so a tunnel stays `connecting` (and the menu bar shows an hourglass) while ssh waits for the SSH agent, e.g. a 1Password approval prompt. A `LocalCommand` set in `~/.ssh/config` is overridden for these processes.

## Remote Forward Requests (control socket)

Tools that are often used together with LLM agents, such as review or diff viewers, start web UIs on changing ports on a remote machine. With the control socket enabled, a remote host can ask Larimar to forward such a port and attach a short hint describing what it is used for. The remote side needs only `curl`; Larimar does not need to be installed there.

```toml
[control]
enabled = true             # default: false
approval_timeout = 120     # seconds to wait for approval (10-3600)

[control.hosts.devbox]     # name: A-Z a-z 0-9 _ -
ssh_host = "devbox"        # ssh_config alias or hostname
auto_connect = true        # ssh_user / ssh_port / auto_connect inherit [defaults]
```

### How it works

```
remote (curl only)                                Mac
curl ──▶ ~/.larimar/control.sock ══ ssh -R ══▶ $TMPDIR/larimar-control/<id>.sock ──▶ Larimar
         (directory 0700)                          (directory 0700, socket 0600, one per host)

larimar CLI (Mac) ──────────────────────────▶ ~/Library/Application Support/Larimar/larimar.sock
```

For each allowed host Larimar keeps a *control connection*:

1. Before every connection attempt it runs a small POSIX `sh` script on the remote host over ssh. The script creates `~/.larimar` with mode 0700 (refusing symlinks and directories owned by someone else) and removes a stale `control.sock` (refusing to remove anything that is not a socket).
2. It then runs `ssh -N -R ~/.larimar/control.sock:<Mac socket>`. Remote Unix socket forwarding must be allowed by sshd (`AllowStreamLocalForwarding`, enabled by default).

The Mac socket a request arrives on tells Larimar which host sent it. If the same remote user is connected from two Macs, the one that connected last receives the requests.

### Security model

- There is no authentication token. Access is limited by file permissions instead: on the remote host only the same user (and root) can reach `~/.larimar/control.sock`, and on the Mac only your user can reach the Mac-side socket. The mode of the remote socket itself is decided by sshd's `StreamLocalBindMask` (default `0177`); the 0700 directory is the main boundary.
- Any process running as your user on an allowed remote host, including LLM agents, can list its forwards, set hints, and request new forwards. **Creating a new forward always requires your approval** in a Larimar dialog (or from the menu). The same request is rejected for 60 seconds after you deny it (`403 recently_denied`); clear it from *Recently Denied* in the menu to be asked again. At most 3 approvals can be pending per host.
- A request that matches an existing `local` tunnel from `tunnels.toml` through the same SSH host/user/port is treated as already approved: its hint is updated and it is connected if stopped.
- A host only sees its own dynamic forwards and the configured `local` tunnels that use its SSH identity. Removing a host from the configuration, or changing its `ssh_host`/`ssh_user`/`ssh_port`, removes its dynamic forwards and pending requests.
- Dynamic forwards bind to `127.0.0.1` on the Mac and live in memory only; they disappear when Larimar quits.

### API (v1)

All requests go to `http://larimar/v1/...` over the Unix socket. Request bodies must be JSON with `Content-Type: application/json`.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/health` | Version and the host name as seen by Larimar |
| `GET` | `/v1/forwards` | Forwards visible to this host |
| `POST` | `/v1/forwards` | Request a forward: `{"app", "remote_port", "forward_host"?, "local_port"?, "hint"?}` |
| `GET` | `/v1/forwards/{id}` | One forward |
| `DELETE` | `/v1/forwards/{id}` | Remove a dynamic forward (for a configured tunnel, only its hint is cleared) |
| `POST` | `/v1/forwards/{id}/hint` | Set the hint: `{"hint": "..."}` (max 200 characters) |
| `DELETE` | `/v1/forwards/{id}/hint` | Clear the hint |

`POST /v1/forwards` responds with:

- `200` when an existing forward already covers the request (the hint is updated)
- `201` when a new forward was approved and created; the status is `connecting` at that point, so poll `GET /v1/forwards/{id}` for `status` and `error`. `connected` means ssh has authenticated, not that the remote port is reachable
- `403` denied (`denied`, or `recently_denied` within 60 seconds of a denial), `408` not approved in time, `409` the requested `local_port` is in use or differs from an existing forward, `429` too many pending requests

If `local_port` is omitted, Larimar uses the same number as `remote_port` when it is free on the Mac, otherwise any free port. The response contains `local_url`.

```sh
S="$HOME/.larimar/control.sock"

# Request a forward for a someapp instance listening on remote port 4980
curl -s --unix-socket "$S" -X POST http://larimar/v1/forwards \
  -H 'Content-Type: application/json' \
  -d '{"app":"someapp","remote_port":4980,"hint":"PR #123 review"}'

# Update the hint, then remove the forward
curl -s --unix-socket "$S" -X POST http://larimar/v1/forwards/dyn:1a2b3c4d/hint \
  -H 'Content-Type: application/json' -d '{"hint":"PR #124 review"}'
curl -s --unix-socket "$S" -X DELETE http://larimar/v1/forwards/dyn:1a2b3c4d
```

### Menu

The menu shows *Pending Approvals*, *Recently Denied* requests, *Configured* tunnels, *Dynamic* forwards, and *Control* connections. Tunnels with the same `app` are grouped into a submenu. Each tunnel has *Connect/Disconnect* and, when a hint is set, *Clear Hint*; local forwards also have *Open in Browser* and *Copy URL*, and dynamic forwards have *Remove*.

## CLI Usage

```bash
larimar status              # Show all tunnel statuses
larimar list                # List configured tunnels
larimar connect my-service  # Connect a tunnel and wait until it is established
larimar disconnect my-service
larimar connect --all       # Connect all tunnels
larimar disconnect --all    # Disconnect all tunnels
larimar hint someapp-4970 "PR #123 review"   # Set a hint (use --clear to remove)
larimar remove dyn:1a2b3c4d                 # Remove a dynamic forward
larimar control connect devbox              # Connect/disconnect a control connection
```

The CLI communicates with the daemon via a Unix domain socket at `~/Library/Application Support/Larimar/larimar.sock`. The daemon must be running. Every command prints a single JSON object on stdout, so the output can be piped straight into `jq` or a coding agent. A command reports only the tunnels it touched; `larimar status` shows everything.

`connect` blocks until the tunnel is connected — which includes waiting for an SSH agent prompt such as TouchID — and fails if it does not come up within `--timeout` seconds (default 60). Pass `--no-wait` to return as soon as the connection is requested.

## Architecture

```
LarimarDaemon (menu bar app)
├── TunnelManager — spawns/monitors/kills ssh -N -L/-R/-D processes
├── IPCServer — Unix domain socket, one JSON request/response per connection
├── ControlServer — per-host control sockets serving the v1 HTTP API
├── ControlConnectionManager — remote pre-step + ssh -R for each allowed host
├── ApprovalCoordinator — approval panel and pending request bookkeeping
├── ConfigWatcher — DispatchSource file monitoring
└── NetworkMonitor — NWPathMonitor for connectivity changes

LarimarCLI (larimar)
└── IPCClient — connects to daemon socket, sends commands

~/.config/larimar/tunnels.toml → tunnel definitions
~/.ssh/config → SSH connection details (delegated)
```

### Tunnel state machine

```
Stopped → Connecting → (authenticated) → Connected
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

  control = {
    enable = true;
    hosts.devbox = {
      ssh_host = "devbox";
      auto_connect = true;
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
