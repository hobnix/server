# The `hs` command: `hs <command>` runs scripts/<command>.sh from this repo (copied into the Nix store).
# One definition for configuration.nix and install.nix, so a freshly installed server has `hs` from its first boot.
{ pkgs }:
    pkgs.writeShellScriptBin "hs" ''
      set -euo pipefail
      dir=${./scripts}
      # Everything else is scripts/lib/hs.sh (registry.tsv: names, groups, help,
      # completion). Help, the registry and completion only read files and run
      # as the caller; every other command needs root (Incus, ZFS, NixOS).
      # sudo drops the environment, so pass var_* (overrides of a recipe or installer), the
      # language and the caller marker through.
      case "''${1:-help}" in
        help|-h|--help) exec bash "$dir/lib/hs.sh" "$@" ;;
        motd) shift; exec bash "$dir/motd.sh" "$@" ;;   # reads state files only: no root
        sys) case "''${2:-}" in registry|complete|motd) exec bash "$dir/lib/hs.sh" "$@" ;; esac ;;   # read-only forms: no root
      esac
      if [ "$(id -u)" -ne 0 ]; then
        mapfile -t vars < <(env | grep -E '^(var_[A-Za-z0-9_]+|HS_LANG|HS_CALLER)=' || true)
        exec sudo env "''${vars[@]}" "$0" "$@"
      fi
      exec bash "$dir/lib/hs.sh" "$@"
    ''
