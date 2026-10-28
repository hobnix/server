#!/usr/bin/env bash
# scripts/user-access.sh (hs sys users access|group-access): which shares a user or a group reaches, and through which ACL entry.
# Fake manage-users and manage-shares: no domain controller, no Samba, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
cat > "$WORK/mu" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --list) printf 'anna\tAnna A\tenabled\tStaff,Domain Users\nbob\tBob B\tdisabled\tDomain Users\ncarl\t\tenabled\t\n' ;;
esac
FAKE
cat > "$WORK/ms" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = --list ]; then
  printf 'media\tshares\t/bulk/shares/media\toff\t1\t\nphotos\tsensitive\t/bulk/sensitive/photos\toff\t1\t\nusb\tother\t/mnt/usb\t-\t-\t\nprivate\tshares\t/bulk/shares/private\toff\t1\t\nopen\tshares\t/bulk/shares/open\toff\t1\t\n'
  exit 0
fi
case "$1" in
  media)   printf 'S-1\tHOME\\Staff\tgroup\twrite\nS-2\tHOME\\anna\tuser\tread\nS-3\tHOME\\Domain Admins\tgroup\tfull\n' ;;
  photos)  printf 'S-1\tHOME\\Domain Users\tgroup\tread\n' ;;
  private) printf 'S-1\tHOME\\Staff\tgroup\tread\nS-2\tHOME\\anna\tuser\tdenied\n' ;;
  open)    printf 'S-0\tEveryone\tgroup\tread\n' ;;
esac
FAKE
chmod +x "$WORK/mu" "$WORK/ms"; export HS_MANAGE_USERS=$WORK/mu HS_MANAGE_SHARES=$WORK/ms
A="bash $SCRIPTS/user-access.sh"

echo "-- a user: through himself, his groups and Everyone; the best level wins; a deny wins over everything"
check_eq "anna" $'media\twrite\tStaff,anna\nphotos\tread\tDomain Users\nprivate\tdenied\tStaff,anna\nopen\tread\tEveryone' "$($A user anna)"
check_eq "bob: one group and Everyone, a folder that is not a share is skipped" $'photos\tread\tDomain Users\nopen\tread\tEveryone' "$($A user bob)"
check_eq "carl has no groups: only Everyone" $'open\tread\tEveryone' "$($A user carl)"
rc=0; out=$($A user nobody 2>&1) || rc=$?
check_eq "an unknown user" "1 No user called 'nobody'." "$rc $out"

echo "-- a group: the entries made for the group itself"
check_eq "Staff" $'media\twrite\tStaff\nprivate\tread\tStaff' "$($A group Staff)"
check_eq "a group with no entry" "" "$($A group Nobody)"
check_eq "the name is not case sensitive" $'media\tfull\tDomain Admins' "$($A group 'domain admins')"

echo "-- usage and the registry rows"
check_out "no name" "usage: user-access.sh" bash "$SCRIPTS/user-access.sh" user
check_out "hs sys users access runs it" "media	write" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys users access anna
check_out "hs sys users group-access runs it" "media	write" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys users group-access Staff
finish
