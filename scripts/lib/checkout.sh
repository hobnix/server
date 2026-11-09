# shellcheck shell=bash
# Turns a copied tree (the installer copies the repository without .git) into a git checkout, so that `hs update`, the update channels and
# the version shown work on a server made by the ISO (issue #396). Used by install-wizard.sh. Needs ui.sh.
#
#   repo_checkout <dir> <origin url> <commit or -> <describe or ->
#
# The files stay exactly as they are: only the history is fetched and HEAD is set to the commit the ISO was built from, so `git status`
# is clean. machine.toml and hardware-configuration.nix are in .gitignore and are never read or written here.
# It must never fail the install: the files are already in place and the server boots without git.
# Returns: 0 a clean checkout; 3 a checkout, but some files differ from the commit (says how many); 1 nothing fetched (no network);
# 2 fetched, but the commit of the ISO is not in the repository (a stick built from unpublished work). With 1 and 2 no .git is left behind:
# a repository without a commit would only make `hs update` fail in a confusing way. In every case the version the ISO carries is kept in
# <dir>/.hobnix-version (ignored by git), so the version is still known without a checkout.
# Test knobs: HS_INSTALL_FETCH_TIMEOUT (seconds, default 180).

repo_checkout() {
  local dir=$1 url=$2 commit=${3:--} desc=${4:--} tag dirty
  local -a g=(git -C "$dir" -c core.hooksPath=/dev/null)
  [ "$desc" = - ] || printf '%s\n' "$desc" > "$dir/.hobnix-version"
  "${g[@]}" init -q 2>/dev/null || return 1
  "${g[@]}" remote add origin "$url" 2>/dev/null || { rm -rf "$dir/.git"; return 1; }
  if ! GIT_TERMINAL_PROMPT=0 timeout "${HS_INSTALL_FETCH_TIMEOUT:-180}" "${g[@]}" fetch -q --tags origin >/dev/null 2>&1; then
    rm -rf "$dir/.git"; return 1
  fi
  if [ "$commit" = - ] || ! "${g[@]}" cat-file -e "$commit^{commit}" 2>/dev/null; then
    rm -rf "$dir/.git"; return 2
  fi
  "${g[@]}" update-ref --no-deref HEAD "$commit"        # a detached HEAD, like `hs update` on the stable channel
  "${g[@]}" reset -q                                    # the index follows HEAD; the files are not touched
  "${g[@]}" checkout -q -- . 2>/dev/null || true        # the tracked files the copy leaves out (tests, .claude) come back
  tag=$("${g[@]}" describe --tags --exact-match "$commit" 2>/dev/null || true)
  if [ -z "$tag" ] && "${g[@]}" merge-base --is-ancestor "$commit" refs/remotes/origin/develop 2>/dev/null; then
    # a stick built from develop: on the branch develop, so the channel edge follows it
    "${g[@]}" branch -q -f develop "$commit" && "${g[@]}" checkout -q develop 2>/dev/null \
      && "${g[@]}" branch -q --set-upstream-to=origin/develop develop 2>/dev/null || true
  fi
  dirty=$("${g[@]}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  REPO_CHECKOUT_DIRTY=$dirty
  [ "$dirty" -eq 0 ] || return 3
  return 0
}
