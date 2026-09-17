{ config, lib, pkgs, ... }:

let
  cfg = config.services.larimar;

  portType = lib.types.ints.between 1 65535;

  tunnelSubmodule = lib.types.submodule {
    options = {
      mode = lib.mkOption {
        type = lib.types.enum [ "local" "remote" "dynamic" ];
        default = "local";
        description = "Forwarding mode: local (-L), remote (-R), or dynamic (-D SOCKS proxy).";
      };
      local_port = lib.mkOption {
        type = portType;
        description = "Local port to bind (for local/dynamic) or forward to (for remote).";
      };
      remote_port = lib.mkOption {
        type = lib.types.nullOr portType;
        default = null;
        description = "Remote port. Required for local and remote mode, ignored for dynamic.";
      };
      forward_host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "Destination host for forwarding (from SSH server for local mode, from local machine for remote mode).";
      };
      ssh_host = lib.mkOption {
        type = lib.types.str;
        description = "SSH host or ~/.ssh/config Host alias.";
      };
      ssh_user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override SSH user (prefer ~/.ssh/config).";
      };
      ssh_port = lib.mkOption {
        type = lib.types.nullOr portType;
        default = null;
        description = "Override SSH port (prefer ~/.ssh/config).";
      };
      bind_address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Bind address: local side for -L/-D, remote side for -R.";
      };
      auto_connect = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Connect automatically when daemon starts.";
      };
      auto_reconnect = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Reconnect on disconnection with exponential backoff.";
      };
      app = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[a-z0-9._-]{1,32}");
        default = null;
        description = "Optional app name used to group tunnels in the menu (e.g. \"someapp\").";
      };
    };
  };

  controlHostSubmodule = lib.types.submodule {
    options = {
      ssh_host = lib.mkOption {
        type = lib.types.str;
        description = "SSH host or ~/.ssh/config Host alias of the remote allowed to request forwards.";
      };
      ssh_user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override SSH user (prefer ~/.ssh/config).";
      };
      ssh_port = lib.mkOption {
        type = lib.types.nullOr portType;
        default = null;
        description = "Override SSH port (prefer ~/.ssh/config).";
      };
      auto_connect = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Connect the control connection when the daemon starts (defaults to defaults.auto_connect).";
      };
    };
  };

  # Convert a value to TOML format
  formatValue = v:
    if builtins.isBool v then (if v then "true" else "false")
    else if builtins.isInt v then toString v
    else if builtins.isString v then ''"${v}"''
    else throw "Unsupported TOML value type";

  # Convert an attrset to TOML key = value lines, skipping nulls
  formatSection = name: section:
    let
      filtered = lib.filterAttrs (_: v: v != null) section;
      lines = lib.mapAttrsToList (k: v: "${k} = ${formatValue v}") filtered;
    in
    "[${name}]\n" + lib.concatStringsSep "\n" lines;

  # Build the full TOML config
  tunnelsToml =
    let
      # Mark as managed so the app disables Launch at Login even when opened from Spotlight
      managedLine = "managed = true";

      defaultsSection =
        if cfg.defaults != {} then formatSection "defaults" cfg.defaults
        else "";

      tunnelSections = lib.mapAttrsToList
        (name: tunnel: formatSection "tunnels.${name}" (tunnelToAttrs tunnel))
        cfg.tunnels;

      controlSection =
        if cfg.control.enable || cfg.control.hosts != {} then
          formatSection "control" {
            enabled = cfg.control.enable;
            approval_timeout = cfg.control.approval_timeout;
          }
        else "";

      controlHostSections = lib.mapAttrsToList
        (name: host: formatSection "control.hosts.${name}" host)
        cfg.control.hosts;
    in
    lib.concatStringsSep "\n\n" (lib.filter (s: s != "")
      ([ managedLine defaultsSection ] ++ tunnelSections ++ [ controlSection ] ++ controlHostSections)) + "\n";

  # Convert tunnel submodule to plain attrset for TOML serialization
  tunnelToAttrs = t: {
    mode = t.mode;
    local_port = t.local_port;
    remote_port = t.remote_port;
    forward_host = t.forward_host;
    ssh_host = t.ssh_host;
    inherit (t) ssh_user ssh_port;
    bind_address = t.bind_address;
    auto_connect = t.auto_connect;
    auto_reconnect = t.auto_reconnect;
    app = t.app;
  };

  validName = pattern: name: builtins.match pattern name != null;
in
{
  options.services.larimar = {
    enable = lib.mkEnableOption "Larimar SSH tunnel manager";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The Larimar package to use.";
    };

    defaults = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]);
      default = {};
      example = {
        bind_address = "127.0.0.1";
        auto_reconnect = true;
      };
      description = "Default settings for all tunnels (TOML [defaults] section).";
    };

    tunnels = lib.mkOption {
      type = lib.types.attrsOf tunnelSubmodule;
      default = {};
      description = "SSH tunnel definitions.";
    };

    control = {
      enable = lib.mkEnableOption "the control socket that lets allowed remote hosts request forwards (each new forward requires approval)";

      approval_timeout = lib.mkOption {
        type = lib.types.ints.between 10 3600;
        default = 120;
        description = "Seconds to wait for the user to approve a forward request.";
      };

      hosts = lib.mkOption {
        type = lib.types.attrsOf controlHostSubmodule;
        default = {};
        description = "Remote hosts allowed to request forwards through the control socket.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions =
        (lib.mapAttrsToList (name: tunnel: {
          assertion = tunnel.mode == "dynamic" || tunnel.remote_port != null;
          message = "services.larimar.tunnels.${name}: remote_port is required for '${tunnel.mode}' mode";
        }) cfg.tunnels)
        ++ (lib.mapAttrsToList (name: _: {
          assertion = validName "[A-Za-z0-9_-]+" name;
          message = "services.larimar.tunnels.${name}: tunnel names may only contain A-Z a-z 0-9 _ -";
        }) cfg.tunnels)
        ++ (lib.mapAttrsToList (name: _: {
          assertion = validName "[A-Za-z0-9_-]{1,64}" name;
          message = "services.larimar.control.hosts.${name}: host names may only contain A-Z a-z 0-9 _ -";
        }) cfg.control.hosts);

      # Generate tunnels.toml
      home.file.".config/larimar/tunnels.toml" = {
        text = tunnelsToml;
      };

      # Add larimar CLI to PATH
      home.packages = [ cfg.package ];
    }

    (lib.mkIf pkgs.stdenv.isDarwin {
      # Symlink Larimar.app to ~/Applications for Spotlight
      home.file."Applications/Larimar.app" = {
        source = "${cfg.package}/Applications/Larimar.app";
        recursive = true;
      };

      # Register launchd agent for auto-start
      # Note: this replaces the in-app "Launch at Login" (SMAppService).
      # The UI toggle is hidden when managed by home-manager to avoid conflict.
      launchd.agents.larimar = {
        enable = true;
        config = {
          Label = "com.larimar.daemon";
          ProgramArguments = [
            "${cfg.package}/Applications/Larimar.app/Contents/MacOS/LarimarDaemon"
          ];
          RunAtLoad = true;
          KeepAlive = false;
        };
      };
    })
  ]);
}
