#!/usr/bin/env bash
# notification provider: email over SMTP. One of the places that call curl (the providers are the only curl).
#   email.sh send <priority> <title> <body>   settings CH_host CH_port CH_security CH_user CH_password CH_from CH_to; exit 0 delivered, 1 not delivered, 2 not usable
#   email.sh fields                           key TAB label TAB text|secret TAB required|optional TAB pattern
#   email.sh check                            exit 0, or 2 with the reason on stderr
#   email.sh where                            outside | inside: is the SMTP server something that is not on this server?
#   email.sh caps                             alarm status digest (a mail every 15 minutes as a heartbeat would only be noise)
# security: starttls (default, port 587), ssl (smtps, port 465) or none (port 25, the password would travel in the clear: only on a trusted network).
# The password never goes into argv: curl reads user:password from a 0600 config file that is deleted at once.
set -uo pipefail
host=${CH_host:-}
security=${CH_security:-starttls}
port=${CH_port:-}
user=${CH_user:-}
pass=${CH_password:-}
from=${CH_from:-}
to=${CH_to:-}
addr_re='^[^][:space:]<>,;"]+@[^][:space:]<>,;"]+$'

usable() {
  [ -n "$host" ] || { echo "no SMTP server (host) set" >&2; return 2; }
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "the host is a name or an address, nothing else" >&2; return 2; }
  case "$security" in starttls|ssl|none) ;; *) echo "security is starttls, ssl or none" >&2; return 2 ;; esac
  [ -z "$port" ] || [[ "$port" =~ ^[0-9]{1,5}$ ]] || { echo "the port is a number" >&2; return 2; }
  [[ "$from" =~ $addr_re ]] || { echo "from is not a mail address" >&2; return 2; }
  [[ "$to" =~ $addr_re ]] || { echo "to is not a mail address" >&2; return 2; }
  if [ -n "$user" ] && [ -z "$pass" ]; then echo "a user needs a password" >&2; return 2; fi
  [[ "$user$pass" != *[$'\r\n"']* ]] || { echo "the user and the password must not contain a quote or a line break" >&2; return 2; }
  return 0
}

case "${1:-}" in
  fields)
    printf 'host\tSMTP server\ttext\trequired\t^[A-Za-z0-9.-]+$\n'
    printf 'port\tPort (default 587, with ssl 465, with none 25)\ttext\toptional\t^[0-9]{1,5}$\n'
    printf 'security\tSecurity: starttls, ssl or none\ttext\toptional\t^(starttls|ssl|none)$\n'
    printf 'user\tUser name (leave empty for a server without login)\ttext\toptional\t-\n'
    printf 'password\tPassword\tsecret\toptional\t-\n'
    printf 'from\tSender address\ttext\trequired\t-\n'
    printf 'to\tRecipient address\ttext\trequired\t-\n' ;;
  check) usable ;;
  caps) echo "alarm status digest" ;;
  where)
    usable >/dev/null 2>&1 || { echo inside; exit 0; }
    me=$(hostname 2>/dev/null || true)
    case "$host" in
      localhost|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|*.local|*.lan|*.internal|*.home.arpa) echo inside ;;
      *.*) if [ -n "$me" ] && [ "$host" = "$me" ]; then echo inside; else echo outside; fi ;;
      *) echo inside ;;
    esac ;;
  send)
    [ $# -eq 4 ] || { echo "usage: email.sh send <priority> <title> <body>" >&2; exit 2; }
    usable || exit 2
    title=${3//$'\r'/}; title=${title//$'\n'/ }
    body=${4//$'\r'/}; body=${body//\`/}; body=${body//\*\*/}
    case "$security" in ssl) scheme=smtps; dport=465 ;; none) scheme=smtp; dport=25 ;; *) scheme=smtp; dport=587 ;; esac
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/hs-mail.XXXXXX") || { echo "no temporary folder" >&2; exit 1; }
    trap 'rm -rf "$tmp"' EXIT
    chmod 700 "$tmp"
    subject=$title
    if [[ "$title" =~ [^[:print:]] || "$title" =~ [^\ -~] ]]; then subject="=?UTF-8?B?$(printf '%s' "$title" | base64 | tr -d '\r\n')?="; fi
    {
      printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\n' "$from" "$to" "$subject" "$(date -R 2>/dev/null || date)"
      printf 'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\nX-Priority: %s\r\n\r\n' "$2"
      printf '%s\r\n' "${body//$'\n'/$'\r\n'}"
    } > "$tmp/mail"
    args=(-sS -m 20 --url "$scheme://$host:${port:-$dport}" --mail-from "$from" --mail-rcpt "$to" -T "$tmp/mail")
    [ "$security" != starttls ] || args+=(--ssl-reqd)
    if [ -n "$user" ]; then
      # a backslash is an escape in a curl config file
      ( umask 077; printf 'user = "%s:%s"\n' "${user//\\/\\\\}" "${pass//\\/\\\\}" > "$tmp/cfg" )
      args+=(-K "$tmp/cfg")
    fi
    if err=$(curl "${args[@]}" 2>&1 >/dev/null); then exit 0; fi
    printf '%s\n' "${err//$'\n'/ }" >&2
    exit 1 ;;
  *) echo "usage: email.sh send|fields|check|where|caps" >&2; exit 2 ;;
esac
