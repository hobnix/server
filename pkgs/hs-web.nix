# Web interface frontend (Svelte + Vite, web/): the built files, which scripts/web-serve.py hands out.
#
# After changing web/package.json refresh the lockfile and the hash:
#   cd web && npm install --package-lock-only
#   nix-shell -p prefetch-npm-deps --run "prefetch-npm-deps package-lock.json"   # prints the new npmDepsHash
{ buildNpmPackage }:

buildNpmPackage {
  pname = "hs-web";
  version = "0.1.0";

  src = ../web;
  npmDepsHash = "sha256-wdHHuMl6LgxM/tYd1gxMYjT4CGlcwXMtEu8WevArYwY=";

  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';
}
