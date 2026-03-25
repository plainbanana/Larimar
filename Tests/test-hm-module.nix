# Standalone evaluation test for the home-manager module.
# Run: nix-instantiate --eval Tests/test-hm-module.nix --strict
# Or without NIX_PATH: nix-instantiate --eval Tests/test-hm-module.nix --strict --arg pkgs 'import <path-to-nixpkgs> {}'
#
# Tests that the module generates correct TOML for all three tunnel modes
# and that the remote_port assertion fires for non-dynamic tunnels.

{ pkgs ? import <nixpkgs> {} }:

let
  lib = pkgs.lib;

  # Stub options that home-manager normally provides
  hmStub = { lib, ... }: {
    options = {
      home.file = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            text = lib.mkOption { type = lib.types.str; default = ""; };
            source = lib.mkOption { type = lib.types.path; default = ./.; };
            recursive = lib.mkOption { type = lib.types.bool; default = false; };
          };
        });
        default = {};
      };
      home.packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
      };
      launchd.agents = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
    };
  };

  # Positive test: all three modes
  positiveEval = lib.evalModules {
    modules = [
      hmStub
      { _module.args = { inherit pkgs; }; }
      ../nix/hm-module.nix
      ({ ... }: {
        config.services.larimar = {
          enable = true;
          package = pkgs.hello;
          tunnels.test-local = {
            local_port = 8080;
            remote_port = 80;
            forward_host = "db.internal";
            ssh_host = "bastion";
          };
          tunnels.test-remote = {
            mode = "remote";
            local_port = 3000;
            remote_port = 8080;
            ssh_host = "bastion";
          };
          tunnels.test-dynamic = {
            mode = "dynamic";
            local_port = 1080;
            ssh_host = "bastion";
          };
        };
      })
    ];
  };

  toml = positiveEval.config.home.file.".config/larimar/tunnels.toml".text;

  # Check that the TOML contains expected fields
  hasLocal = builtins.match ".*mode = \"local\".*" toml != null;
  hasRemote = builtins.match ".*mode = \"remote\".*" toml != null;
  hasDynamic = builtins.match ".*mode = \"dynamic\".*" toml != null;
  hasForwardHost = builtins.match ".*forward_host = \"db.internal\".*" toml != null;
  hasManaged = builtins.match ".*managed = true.*" toml != null;

  # Check assertions pass (all assertions should have assertion = true)
  positiveAssertions = positiveEval.config.assertions;
  allAssertionsPass = builtins.all (a: a.assertion) positiveAssertions;

  # Negative test: local mode without remote_port should fail assertion
  negativeEval = lib.evalModules {
    modules = [
      hmStub
      { _module.args = { inherit pkgs; }; }
      ../nix/hm-module.nix
      ({ ... }: {
        config.services.larimar = {
          enable = true;
          package = pkgs.hello;
          tunnels.broken = {
            mode = "local";
            local_port = 8080;
            # remote_port intentionally omitted
            ssh_host = "bastion";
          };
        };
      })
    ];
  };

  negativeAssertions = negativeEval.config.assertions;
  assertionFires = builtins.any (a: !a.assertion) negativeAssertions;

  results = {
    inherit hasLocal hasRemote hasDynamic hasForwardHost hasManaged allAssertionsPass assertionFires;
    allPassed = hasLocal && hasRemote && hasDynamic && hasForwardHost && hasManaged && allAssertionsPass && assertionFires;
    generatedToml = toml;
  };

in
  if results.allPassed then
    "All HM module tests passed"
  else
    builtins.throw "HM module test failed: ${builtins.toJSON results}"
