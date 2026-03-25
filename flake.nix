{
  description = "Larimar — SSH tunnel manager for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      # Pre-fetch SwiftPM dependency as a git repo
      swift-argument-parser-src = pkgs.fetchgit {
        url = "https://github.com/apple/swift-argument-parser.git";
        rev = "626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b";
        hash = "sha256-90ECc3iEmxvOUk9iLKbQdQEz88dOisPqWsJLOFcKUV8=";
      };
    in
    {
      packages.${system}.default = pkgs.swiftPackages.stdenv.mkDerivation {
        pname = "larimar";
        version = builtins.replaceStrings ["\n" "\r"] ["" ""] (builtins.readFile ./VERSION);
        src = ./.;

        nativeBuildInputs = with pkgs; [ swift swiftpm ];

        configurePhase = ''
          export HOME=$TMPDIR

          # Generate Version.swift from VERSION (overrides checked-in file)
          version_str=$(tr -d '\n\r' < ${./VERSION})
          cat > Sources/LarimarShared/Version.swift << SWIFT
          public enum LarimarVersion {
              public static let current = "$version_str"
          }
          SWIFT

          # Rewrite CFBundleShortVersionString in Info.plist by key
          sed -i "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>$version_str</string>|;}" \
            Resources/Info.plist
          # Assert the replacement succeeded
          grep -q "<string>$version_str</string>" Resources/Info.plist \
            || (echo "Failed to set version in Info.plist" >&2 && exit 1)

          # Pre-populate SwiftPM checkouts to avoid network access
          mkdir -p .build/checkouts
          cp -r ${swift-argument-parser-src} .build/checkouts/swift-argument-parser
          chmod -R u+w .build/checkouts

          # workspace-state.json for SwiftPM 5.10 (kind: "remote")
          cat > .build/workspace-state.json << 'EOF'
          {
            "version": 1,
            "object": {
              "dependencies": [
                {
                  "basedOn": null,
                  "packageRef": {
                    "identity": "swift-argument-parser",
                    "kind": "remote",
                    "location": "https://github.com/apple/swift-argument-parser.git",
                    "name": "swift-argument-parser"
                  },
                  "state": {
                    "checkoutState": {
                      "revision": "626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b",
                      "version": "1.7.1"
                    },
                    "name": "checkout"
                  },
                  "subpath": "swift-argument-parser"
                }
              ],
              "artifacts": [],
              "repositoryMap": {}
            }
          }
          EOF
        '';

        buildPhase = ''
          swift build -c release --skip-update
        '';

        installPhase = ''
          mkdir -p $out/bin
          cp .build/release/larimar $out/bin/

          mkdir -p $out/Applications/Larimar.app/Contents/MacOS
          mkdir -p $out/Applications/Larimar.app/Contents/Resources
          cp .build/release/LarimarDaemon $out/Applications/Larimar.app/Contents/MacOS/
          cp Resources/Info.plist $out/Applications/Larimar.app/Contents/Info.plist
          cp Resources/AppIcon.icns $out/Applications/Larimar.app/Contents/Resources/
        '';

        meta = with pkgs.lib; {
          description = "macOS menu bar SSH tunnel manager";
          license = licenses.mit;
          platforms = [ "aarch64-darwin" ];
          mainProgram = "larimar";
        };
      };

      homeManagerModules.default = import ./nix/hm-module.nix;

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          swift-format
        ];
        shellHook = ''
          unset DEVELOPER_DIR SDKROOT
        '';
      };
    };
}
