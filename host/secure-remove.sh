#!/usr/bin/env bash

secure_remove_dir() {
  local directory="$1"
  if [ -n "${directory}" ] && [ -d "${directory}" ]; then
    find "${directory}" -type f -exec chmod u+w {} + 2>/dev/null || return 1
    find "${directory}" \( -type f -o -type l \) -delete 2>/dev/null || return 1
    find "${directory}" -depth -type d -empty -delete 2>/dev/null || return 1
    [ ! -e "${directory}" ] || return 1
  fi
}
