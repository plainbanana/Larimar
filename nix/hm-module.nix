{ config, lib, pkgs, ... }:

let
  cfg = config.services.larimar;

  portType = lib.types.ints.between 1 65535;

  tunnelSubmodule = lib.types.submodule {
    options = {
      local_port = lib.mkOption {
        type = portType;
        description = "Local port to bind.";
      };
      remote_port = lib.mkOption {
        type = portType;
        description = "Remote port to forward to.";
      };
      remote_host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "Remote host (from the SSH server's perspective).";
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
        description = "Local bind address.";
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
    in
    lib.concatStringsSep "\n\n" (lib.filter (s: s != "") ([ managedLine defaultsSection ] ++ tunnelSections)) + "\n";

  # Convert tunnel submodule to plain attrset for TOML serialization
  tunnelToAttrs = t: {
    local_port = t.local_port;
    remote_port = t.remote_port;
    remote_host = t.remote_host;
    ssh_host = t.ssh_host;
    inherit (t) ssh_user ssh_port;
    bind_address = t.bind_address;
    auto_connect = t.auto_connect;
    auto_reconnect = t.auto_reconnect;
  };
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
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
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
          StandardOutPath = "/tmp/larimar.log";
          StandardErrorPath = "/tmp/larimar.err";
        };
      };
    })
  ]);
}
