# The binary cache that CI fills (docs/adr/0003-binary-cache.md, issue #253). Edited by hand.
# While `name` is empty the hosts use only cache.nixos.org and build everything else locally.
# Fill in both values after the Cachix cache exists (cachix.org -> create cache -> its public signing key is shown on the cache page).
{
  name = "hobnix";        # the Cachix cache name; the host then adds https://<name>.cachix.org
  publicKey = "hobnix.cachix.org-1:VLKZcghLSu/LRKleaK89t8YUpv7M9F6d1Db2/cuiAq4=";   # the line "<name>.cachix.org-1:..." from the cache page
}
