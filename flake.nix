{
  description = "jab - single-binary linter, fixer, and formatter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";

    # Tree-sitter grammars (pre-generated parser.c + scanner.c)
    tree-sitter-bash = {
      url = "github:tree-sitter/tree-sitter-bash";
      flake = false;
    };
    tree-sitter-python = {
      url = "github:tree-sitter/tree-sitter-python";
      flake = false;
    };
    tree-sitter-hcl = {
      url = "github:tree-sitter-grammars/tree-sitter-hcl";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
      tree-sitter-bash,
      tree-sitter-python,
      tree-sitter-hcl,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        zig = pkgs.zigpkgs."0.15.2";

        # Single source of truth for the version. CI's drift-check asserts that
        # this file does NOT hard-code a version — it must be read from
        # build.zig.zon, as below.
        pkgVersion = builtins.elemAt (builtins.match
          "(.|\n)*\\.version = \"([^\"]+)\"(.|\n)*"
          (builtins.readFile ./build.zig.zon)) 1;

        externalTools = with pkgs; [
          shellcheck
          yamllint
          opentofu
          ruff
          ty
          hadolint
          actionlint
          taplo
          nixfmt-rfc-style
        ];

        mkJab =
          {
            withTools ? false,
          }:
          pkgs.stdenvNoCC.mkDerivation {
            pname = "jab";
            version = pkgVersion;

            src = pkgs.lib.cleanSource ./.;

            nativeBuildInputs = [ zig ] ++ pkgs.lib.optionals withTools [ pkgs.makeWrapper ];

            dontConfigure = true;
            dontFixup = !withTools;

            postUnpack = ''
              # Nix source is read-only; copy grammar files that are
              # gitignored locally but present in upstream repos.
              chmod -R u+w $sourceRoot/grammars

              cp ${tree-sitter-bash}/src/parser.c $sourceRoot/grammars/bash/src/parser.c
              cp ${tree-sitter-python}/src/parser.c $sourceRoot/grammars/python/src/parser.c
              cp ${tree-sitter-hcl}/src/parser.c $sourceRoot/grammars/hcl/src/parser.c

              # tree_sitter/*.h headers needed by grammar C sources
              # (parser.h, array.h etc. live in lib/src/, api.h in lib/include/)
              for lang in bash python hcl; do
                mkdir -p "$sourceRoot/grammars/$lang/src/tree_sitter"
                cp $sourceRoot/vendor/tree-sitter/lib/src/parser.h \
                   $sourceRoot/vendor/tree-sitter/lib/src/array.h \
                   $sourceRoot/vendor/tree-sitter/lib/include/tree_sitter/api.h \
                   "$sourceRoot/grammars/$lang/src/tree_sitter/"
              done
            '';

            buildPhase = ''
              export XDG_CACHE_HOME="$TMPDIR/zig-cache"
              zig build -Doptimize=ReleaseSafe --prefix $out
            '';

            installPhase = "true"; # zig build --prefix handles installation

            postFixup = pkgs.lib.optionalString withTools ''
              wrapProgram $out/bin/jab \
                --prefix PATH : ${pkgs.lib.makeBinPath externalTools}
            '';

            meta = with pkgs.lib; {
              description = "Single-binary linter, fixer, and formatter for bash, JSON, YAML, Python, and HCL";
              license = licenses.isc;
              mainProgram = "jab";
            };
          };
      in
      {
        packages.default = mkJab { };
        packages.jab = mkJab { };
        packages.jab-full = mkJab { withTools = true; };

        # Generated tree-sitter parser.c files, pinned to the flake inputs.
        # `make grammars` materializes these into grammars/*/src/ so a raw
        # `zig build` works outside the nix sandbox (CI cross-compile, release).
        packages.grammars = pkgs.runCommand "jab-grammars" { } ''
          install -Dm644 ${tree-sitter-bash}/src/parser.c $out/bash/parser.c
          install -Dm644 ${tree-sitter-python}/src/parser.c $out/python/parser.c
          install -Dm644 ${tree-sitter-hcl}/src/parser.c $out/hcl/parser.c
        '';

        devShells.default = pkgs.mkShell {
          packages = [ zig ] ++ externalTools;

          shellHook = ''
            echo "jab dev shell — zig $(zig version)"
          '';
        };
      }
    );
}
