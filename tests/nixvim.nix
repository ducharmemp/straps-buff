{ pkgs, module, adapter, buffModule, strapsModule, invert ? 0 }:
let
  inherit (pkgs) lib;
  evaluate = extra: evaluateWith [ buffModule strapsModule ] extra;
  evaluateWith = dependencies: extra: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = dependencies ++ [
      ({ lib, ... }: {
        options = {
          extraPlugins = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
          extraPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
          extraConfigLua = lib.mkOption { type = lib.types.lines; default = ""; };
          assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
        };
      })
      module
      extra
    ];
  };
  enabled = (evaluate { plugins.buff.enable = true; plugins.straps.enable = true; plugins.straps-buff.enable = true; }).config;
  disabled = (evaluate { }).config;
  custom = pkgs.vimUtils.buildVimPlugin { pname = "straps-buff-override"; version = "test"; src = adapter.src; };
  overridden = (evaluate {
    plugins.buff.enable = true;
    plugins.straps.enable = true;
    plugins.straps-buff = { enable = true; package = custom; };
    plugins.buff.settings.headless = true;
    plugins.straps.settings.tools_expanded = true;
  }).config;
  independent = (evaluateWith [ ] { plugins.straps-buff.enable = true; }).config;
  checks = [
    (builtins.length independent.extraPlugins == 1 && !(independent.plugins ? straps) && !(independent.plugins ? buff))
    (builtins.length enabled.extraPlugins == 3)
    (enabled.plugins.buff.enable && disabled.plugins.straps.enable == false)
    (builtins.all (item: item.assertion) enabled.assertions)
    (disabled.extraPlugins == [ ] && disabled.extraPackages == [ ] && disabled.extraConfigLua == "")
    (lib.hasInfix "headless" overridden.extraConfigLua && overridden.plugins.buff.settings.headless)
    (lib.hasInfix "tools_expanded" overridden.extraConfigLua && overridden.plugins.straps.settings.tools_expanded)
    (lib.hasSuffix "require(\"straps-buff\").setup()\n" enabled.extraConfigLua)
    (independent.assertions == [ ] && independent.extraPackages == [ ])
    (builtins.elem custom overridden.extraPlugins && !(builtins.elem adapter overridden.extraPlugins))
  ];
in
assert lib.assertMsg (builtins.all (value: value) (lib.imap1 (index: value: if index == invert then !value else value) checks)) ("nixvim checks: " + builtins.toJSON checks + "; inversion=" + toString invert);
pkgs.runCommand "straps-buff-nixvim" { nativeBuildInputs = [ pkgs.neovim ]; } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  nvim --headless -u NONE ${lib.concatMapStringsSep " " (plugin: "--cmd " + lib.escapeShellArg "set rtp+=${plugin}") enabled.extraPlugins} \
    -c ${lib.escapeShellArg ("lua local ok, err = pcall(function() " + enabled.extraConfigLua + " assert(require('straps.registry').get('tool.buff_operate')) end); if not ok then print(err); vim.cmd('cquit 1') end")} -c 'qa!'
  touch "$out"
''
