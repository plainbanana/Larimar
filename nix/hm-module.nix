{ config, lib, pkgs, ... }:

let
  cfg = config.services.larimar;

  # Convert Nix attrset to TOML string
  toTOML = attrs:
    let
      formatValue = v:
        if builtins.isBool v then (if v then "true" else "false")
        else if builtins.isInt v then toString v
        else if builtins.isString v then ''"${v}"''
        else throw "Unsupported TOML value type";

      formatSection = name: section:
        let
          lines = lib.mapAttrsToList (k: v: "${k} = ${formatValue v}") section;
        in
        "[${name}]\n" + lib.concatStringsSep "\n" lines;

      defaultsSection =
        if cfg.defaults != {} then formatSection "defaults" cfg.defaults
        else "";

      tunnelSections = lib.mapAttrsToList
        (name: tunnel: formatSection "tunnels.${name}" tunnel)
        cfg.tunnels;
    in
    lib.concatStringsSep "\n\n" (lib.filter (s: s != "") ([ defaultsSection ] ++ tunnelSections)) + "\n";

  tunnelsToml = toTOML {};

  larimarPackage = cfg.package;
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
      description = "Default settings for all tunnels.";
    };

    tunnels = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]));
      default = {};
      example = {
        my-service = {
          local_port = 9022;
          remote_port = 9022;
          remote_host = "localhost";
          ssh_host = "bastion";
          auto_connect = true;
        };
      };
      description = "SSH tunnel definitions.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Generate tunnels.toml
    home.file.".config/larimar/tunnels.toml" = {
      text = toTOML {};
    };

    # Symlink Larimar.app to ~/Applications for Spotlight
    home.file."Applications/Larimar.app" = {
      source = "${larimarPackage}/Applications/Larimar.app";
      recursive = true;
    };

    # Add larimar CLI to PATH
    home.packages = [ larimarPackage ];

    # Register launchd agent for auto-start
    launchd.agents.larimar = {
      enable = true;
      config = {
        Label = "com.larimar.daemon";
        ProgramArguments = [
          "${larimarPackage}/Applications/Larimar.app/Contents/MacOS/LarimarDaemon"
        ];
        RunAtLoad = true;
        KeepAlive = false;
        StandardOutPath = "/tmp/larimar.log";
        StandardErrorPath = "/tmp/larimar.err";
      };
    };
  };
}
