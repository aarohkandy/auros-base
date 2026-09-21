#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# make-enrolment.sh — make one school's enrolment file: first passwords, as hashes only.
#
#   tools/make-enrolment.sh --out FILE NAME [NAME...]
#
# For Auros staff, at order time (owner decision A2, control repo docs/ACCOUNTS.md). For each account
# NAME it generates a random password, prints it ONCE to this terminal for the handover sheet, and
# writes only `NAME:<crypt(3) hash>` to FILE (root-readable only, 0600). FILE then goes to
# `make-install-media.sh --enrolment FILE`.
#
# Each account gets its OWN password. One shared password would hand every pupil the IT password.
#
# The password: 20 characters from a 31-letter alphabet with no look-alikes (no 0/o, 1/l/i), grouped
# in fives for reading aloud — about 99 bits from /dev/urandom. The hash: SHA-512 crypt (`$6$`), from
# `openssl passwd -6 -stdin` (OpenSSL 1.1.1+; the password goes in on stdin, never argv). Fedora 44's
# libxcrypt verifies `$6$` (crypt(5): sha512crypt) and `chpasswd -e` stores it as given (man chpasswd:
# "-e, --encrypted Supplied passwords are in encrypted form"). yescrypt (`$y$`, Fedora's default for
# new passwords) is also accepted there; SHA-512 is used because stock OpenSSL can make it, and at
# 99 bits of randomness the hash's work factor is not what protects the password.
#
# NEVER: writes the password to a file, passes it on a command line, or prints it anywhere but a
# terminal — stdout that is not a terminal (a pipe, a `> file`) is refused before anything is made.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
umask 077

refuse() { printf 'make-enrolment: REFUSED — %s\n' "$*" >&2; exit 1; }

OUT=''; NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || refuse "--out needs a file"; OUT="$2"; shift 2 ;;
    -*)    refuse "unknown argument '$1'" ;;
    *)     NAMES+=("$1"); shift ;;
  esac
done
[ -n "$OUT" ] && [ ${#NAMES[@]} -gt 0 ] || refuse "usage: make-enrolment.sh --out FILE NAME [NAME...]"
[ ! -e "$OUT" ] || refuse "$OUT already exists. An enrolment file is never overwritten; move the old one away on purpose."
[ -t 1 ] || refuse "stdout is not a terminal. The passwords are printed once, to a screen; a pipe or a file would keep them."
for n in "${NAMES[@]}"; do
  [[ "$n" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] && [ ${#n} -ge 2 ] && [ ${#n} -le 32 ] \
    || refuse "'$n' is not an account name a recipe can declare"
done
[ "$(printf '%s\n' "${NAMES[@]}" | sort | uniq -d)" = '' ] || refuse "an account is named twice"
case "$(printf 'probe' | openssl passwd -6 -stdin 2>/dev/null)" in
  '$6$'*) ;;
  *) refuse "this openssl cannot make SHA-512 crypt hashes (needs OpenSSL 1.1.1+, not LibreSSL). Run this on the Linux build machine." ;;
esac

# 4 KiB read in full first, then filtered: no reader closes a pipe early (SIGPIPE under pipefail).
newpass() {
  local s; s="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyz23456789')"
  s="${s:0:20}"; [ ${#s} -eq 20 ] || return 1
  printf '%s-%s-%s-%s' "${s:0:5}" "${s:5:5}" "${s:10:5}" "${s:15:5}"
}

lines="# Auros enrolment file — crypt(3) hashes only, never a password. Root-only. $(date -u +%Y-%m-%d)"$'\n'
shown=''
for n in "${NAMES[@]}"; do
  p="$(newpass)" || refuse "could not read enough randomness"
  h="$(printf '%s' "$p" | openssl passwd -6 -stdin)"
  case "$h" in '$6$'*) ;; *) refuse "openssl did not return a SHA-512 crypt hash" ;; esac
  lines+="$n:$h"$'\n'
  shown+="$(printf '  %-32s %s' "$n" "$p")"$'\n'
  p=''
done
printf '%s' "$lines" > "$OUT"
chmod 0600 "$OUT"

printf 'Enrolment file (hashes only): %s\n\n' "$OUT"
printf 'FIRST PASSWORDS — shown once, now. Write them on the handover sheet; they are not stored anywhere.\n\n'
printf '%s' "$shown"
printf '\nThe sheet travels separately from the USB sticks, and is handled like a key.\n'
