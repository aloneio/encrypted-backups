#!/usr/bin/env sh
case "$1" in
  *Username*) printf '%s\n' "${GIT_ASKPASS_USERNAME:-x-access-token}" ;;
  *Password*) printf '%s\n' "${GIT_ASKPASS_TOKEN:?GIT_ASKPASS_TOKEN is required}" ;;
  *) printf '\n' ;;
esac
