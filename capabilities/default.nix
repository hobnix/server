# Loads capabilities/<name>/module.nix for every capability that is switched on (docs/PLAN-modular-core.md step 3).
# A folder without a module.nix, or a capability that is off, adds nothing. options.nix (the options capabilities share) is
# always loaded. Called from configuration.nix.
{ lib, enabled }:
let
  names = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.));
  moduleOf = name: ./. + "/${name}/module.nix";
in
[ ./options.nix ] ++ lib.concatMap (name: lib.optional (enabled name && builtins.pathExists (moduleOf name)) (moduleOf name)) names
