#!/usr/bin/env bash
# Decrypts the payload, runs it and stores the updated state.
# The payload cannot be read without the key held in this repository's secrets.
set -uo pipefail

if [ -z "${APP_KEY:-}" ]; then
  echo "::notice::not configured"
  exit 0
fi

root="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

dec() { gpg --batch --quiet --yes --pinentry-mode loopback --passphrase-fd 3 -o "$2" -d "$1" 3<<<"$APP_KEY"; }
enc() { gpg --batch --quiet --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --compress-algo none -o "$2" "$1" 3<<<"$APP_KEY"; }

mkdir -p "$work/app"
dec "$root/payload/app.enc" "$work/app.tgz" 2>/dev/null && tar xzf "$work/app.tgz" -C "$work/app" || { echo "::error::payload"; exit 1; }
if [ -f "$root/payload/state.enc" ]; then
  dec "$root/payload/state.enc" "$work/state.tgz" 2>/dev/null && tar xzf "$work/state.tgz" -C "$work/app" || { echo "::error::state"; exit 1; }
fi

mapfile -t files < <(grep -v '^\s*#' "$work/app/tools/runner/state_files.txt" | sed '/^\s*$/d')
digest() { (cd "$work/app" && for f in "${files[@]}"; do [ -f "$f" ] && sha256sum "$f"; done | sha256sum | cut -d' ' -f1); }

before="$(digest)"
(cd "$work/app" && bash tools/runner/entrypoint.sh "${MODE:-run}") >"$work/run.log" 2>&1
code=$?
after="$(digest)"

changed=0
if [ "$before" != "$after" ]; then
  keep=()
  for f in "${files[@]}"; do [ -f "$work/app/$f" ] && keep+=("$f"); done
  tar czf "$work/state.tgz" -C "$work/app" "${keep[@]}" && enc "$work/state.tgz" "$root/payload/state.enc" && changed=1
fi
if [ "$changed" = 1 ] || [ "$code" != 0 ]; then
  tail -c 200000 "$work/run.log" >"$work/log.txt"
  enc "$work/log.txt" "$root/payload/log.enc"
fi

echo "exit=$code changed=$changed"
exit "$code"
