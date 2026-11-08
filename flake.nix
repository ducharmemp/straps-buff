{
  description = "Buff browser tools for Straps";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504";
  inputs.nixpkgs-0_11.url = "github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d";

  inputs.buff = { url = "github:ducharmemp/buff.nvim/45ad0cb763138be7eeb03436bd34f0add7036257"; flake = false; };
  inputs.straps = { url = "github:ducharmemp/straps/7396033c8f3b59d0664a030e5cbd6457e77e9ef7"; flake = false; };

  inputs.nixvim.url = "github:nix-community/nixvim/453dc9c5037e6d1bec81d2a51ddacd58a2f44e9c";
  inputs.nixvim.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nixpkgs-0_11, buff, straps, nixvim }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      pluginFiles = lib.fileset.unions ([ ./README.md ./LICENSE ./doc ]
        ++ lib.optional (builtins.pathExists ./lua) ./lua
        ++ lib.optional (builtins.pathExists ./plugin) ./plugin);
      pluginSource = lib.fileset.toSource { root = ./.; fileset = pluginFiles; };
      testSource = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [ pluginFiles ./tests ./.busted ./scripts ];
      };
      mkPlugin = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "straps-buff";
        version = "dev";
        src = pluginSource;
        meta.license = lib.licenses.mit;
      };
      dependencyFlake = source:
        let outputs = (import "${source}/flake.nix").outputs { self = source // outputs; inherit nixpkgs; };
        in outputs;
      buffFlake = dependencyFlake buff;
      strapsFlake = dependencyFlake straps;
      adapterModule = { config, lib, pkgs, ... }:
        let cfg = config.plugins.straps-buff;
        in {
          options.plugins.straps-buff = {
            enable = lib.mkEnableOption "Buff browser tools for Straps";
            package = lib.mkOption {
              type = lib.types.package;
              default = mkPlugin pkgs;
              description = "The straps-buff plugin package.";
            };
          };
          config = lib.mkIf cfg.enable {
            extraPlugins = [ cfg.package ];
            extraConfigLua = lib.mkAfter ''
              require("straps-buff").setup()
            '';
          };
        };
      fetchDeps = pkgs: pkgs.writeShellApplication {
        name = "fetch-deps";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          export STRAPS_BUFF_BUFF_SOURCE=${buff}
          export STRAPS_BUFF_STRAPS_SOURCE=${straps}
        '' + builtins.readFile ./scripts/fetch-deps.sh;
      };
      testPackages = pkgs: neovim: [ neovim pkgs.luajitPackages.busted pkgs.luajitPackages.nlua ];
      mkShell = pkgs: neovim: pkgs.mkShell {
        packages = testPackages pkgs neovim ++ [ pkgs.direnv pkgs.coreutils (fetchDeps pkgs) ]
          ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.chromium ];
        STRAPS_ROOT = toString straps;
        STRAPS_BUFF_BUFF_SOURCE = toString buff;
        STRAPS_BUFF_STRAPS_SOURCE = toString straps;
        STRAPS_BUFF_FETCH_SCRIPT = toString ./scripts/fetch-deps.sh;
        shellHook = ''
          if ! ${pkgs.bash}/bin/bash ${./scripts/ensure-deps.sh}; then
            exit 1
          fi
        '';
      };
      mkCheck = pkgs: neovim: pkgs.runCommand "straps-buff-unit-tests" {
        nativeBuildInputs = testPackages pkgs neovim;
      } ''
        cp -r ${testSource} source
        chmod -R u+w source
        cd source
        export STRAPS_BUFF_BUFF_PATH=${buff}
        export STRAPS_ROOT=${straps}
        export HOME="$TMPDIR/home"
        export XDG_CONFIG_HOME="$HOME/.config"
        export XDG_DATA_HOME="$HOME/.local/share"
        export XDG_STATE_HOME="$HOME/.local/state"
        export XDG_CACHE_HOME="$HOME/.cache"
        mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
        fail=0
        count=0
        for spec in tests/*_spec.lua; do
          [ -f "$spec" ] || continue
          case "$spec" in tests/chromium_spec.lua) continue ;; esac
          count=$((count + 1))
          busted "$spec" || fail=1
        done
        [ "$count" -gt 0 ] || { echo 'No unit specs found' >&2; exit 1; }
        [ "$fail" -eq 0 ]
        touch "$out"
      '';
    in {
      nixvimModules = { default = adapterModule; straps-buff = adapterModule; };
      apps = forAllSystems (pkgs: {
        fetch-deps = {
          type = "app";
          program = "${fetchDeps pkgs}/bin/fetch-deps";
          meta.description = "Fetch pinned Buff and Straps development sources with backups";
        };
      });
      packages = forAllSystems (pkgs: {
        default = mkPlugin pkgs;
      });
      devShells = forAllSystems (pkgs: {
        default = mkShell pkgs pkgs.neovim;
        nvim-0_11 = mkShell pkgs nixpkgs-0_11.legacyPackages.${pkgs.stdenv.hostPlatform.system}.neovim;
      });
      checks = forAllSystems (pkgs: {
        nixvim-startup =
          let editor = nixvim.legacyPackages.${pkgs.stdenv.hostPlatform.system}.makeNixvim {
            imports = [ buffFlake.nixvimModules.default strapsFlake.nixvimModules.default adapterModule ];
            plugins.buff.enable = true;
            plugins.straps.enable = true;
            nixpkgs.source = nixpkgs;
            plugins.straps-buff.enable = true;
            plugins.buff.settings.headless = true;
          };
          in pkgs.runCommand "straps-buff-nixvim-startup" { nativeBuildInputs = [ editor ]; } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            nvim --headless -c 'lua local ok = pcall(function() assert(require("straps.registry").get("tool.buff_operate")) end); if not ok then vim.cmd("cquit 1") end' -c 'qa!'
            touch "$out"
          '';
        nixvim = import ./tests/nixvim.nix { inherit pkgs; module = adapterModule; buffModule = buffFlake.nixvimModules.default; strapsModule = strapsFlake.nixvimModules.default; adapter = mkPlugin pkgs; };
        fetch-deps = fetchDeps pkgs;
        fetch-deps-tests = pkgs.runCommand "fetch-deps-tests" {
          nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gawk ];
        } ''
          cp -r ${testSource} source
          chmod -R u+w source
          cd source
          bash tests/fetch_deps.sh
          bash tests/ensure_deps.sh
          touch "$out"
        '';
        unit-tests = mkCheck pkgs pkgs.neovim;
        unit-tests-0_11 = mkCheck pkgs nixpkgs-0_11.legacyPackages.${pkgs.stdenv.hostPlatform.system}.neovim;
      });
    };
}
