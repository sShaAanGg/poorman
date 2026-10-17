#!/bin/sh
# vim: set expandtab tabstop=2 softtabstop=2 shiftwidth=2 :

# @name Poorman
# @description A very limited alternative to Postman, powered by curl and POSIX shell.
# @version 0.1
# @author CC Lan

WRITE_OUT='__POORMAN_DELIM__%{json}__POORMAN_DELIM__%{header_json}'
trapped=
req_id=0
skip=

# Prints message to stderr
#
# $@ {any}? - word separated with a whitespace.
msg() {
  IFS=" $IFS"
  set -- '%s\n' "${*:-}"
  IFS=${IFS#?}
  # shellcheck disable=SC2059
  printf "$@"
}

# Exit with message and code
#
# $1 {any}? message
# $2 {int}? exit_code - default to 1
die() {
  [ "${1:-}" ] && msg "$1"
  exit "${2:-1}"
}

# Check dependencies
# Will set "has_$dep" to 1 if satisfied, or empty if not.
#
# <<'EXAMPLE'
# _check_deps curl=required jq=optional
# # has_curl=1 and has_jq=1
# EXAMPLE
# 
# $@ {str}? dep_description - In dep=[optional|required] format
# @return 0 - if all required dependencies are satisfied.
_check_deps() {
  failed=
  for arg in "$@"; do
    dep=${arg%=*}
    req=${arg#*=}
    if type "$dep" >/dev/null 2>&1; then
      eval "has_$dep=1"
    else
      unset "has_$dep"
      case $req in
        required)
          failed=1
          msg "[ $arg ] is required."
        ;;
      esac
    fi
  done
  [ "${failed:-}" ] && die || return
}
_check_deps 'curl=required' 'jq=optional'

# Genius quoting function by Koichi Nakashima
# Under License: Creative Commons Zero v1.0 Universal
#
# <<'EXAMPLE'
# quote quoted '@#$%!@"~''\''
# echo "$quoted"
# '@#$%!@"~'\'
# EXAMPLE
#
# $1 {str} varname  - variable name to set
# $2 {str} to_quote - string to quote
# @see https://github.com/ko1nksm/getoptions/blob/master/lib/getoptions_base.sh
quote() {
  q="$2'" r=""
  while [ "$q" ]; do r="$r${q%%\'*}'\''" && q=${q#*\'}; done
  q="'${r%????}'" && q=${q#\'\'} && q=${q%\'\'}
  eval "$1=\${q:-\"''\"}"
}

# Save args as string to variable $list
#
# @set {str} list - quoted string for eval "set -- $list"
to_list() {
  list=
  for arg in "$@"; do
    quote quoted "$arg"
    # shellcheck disable=SC2154
    list="$list $quoted"
  done
}

# Safely quote complex arguments into list
#
# @set {str} list - quoted string for eval "set -- $list"
to_list_quote_complex() {
  list=
  for w in "$@"; do
    case $w in
      *[!a-zA-Z0-9_-]*)
        quote quoted "$w"
        list="$list $quoted"
        ;;
      *)
        list="$list $w"
        ;;
    esac
  done
}

# Send curl request
#
# $1 {GET|POST|PUT|PATCH|DELETE} request - request method
# $2 {str} path - path of URL. e.g., /users/1
# @need {1|any} ONLY - is current script run in ONLY mode?
# @need {1|any} only - is current request mark as "Only"
# @need {str}? BASE_URL - base URL of the request
# @need {str} WRITE_OUT - curl write out
# @need {1|any} DRY_RUN - is current script run in DRY_RUN mode? Prints curl commands if DRY_RUN=1
# @internal
_fetch() {
  if [ "${ONLY:-}" = 1 ] && [ ! "${only:-}" ]; then
    once_opts=
    return
  fi
  if [ "${skip:-}" ]; then
    once_opts=
    return
  fi
  _before_hook
  request=$1 path=$2
  shift 2
  to_list "$@"
  eval "set -- ${list:-} ${global_opts:-} ${once_opts:-}"
  [ "${BASE_URL:-}" ] && BASE_URL="${BASE_URL%/}/"
  set -- curl -X "$request" --write-out "$WRITE_OUT" "$@" "${BASE_URL:-}${path#/}"
  if [ "${DRY_RUN:-}" = 1 ]; then
    to_list_quote_complex "$@"
    printf '%s' "${list#?}"
  else
    _after_hook "$("$@")"
  fi
}

GET() { _fetch GET "$@"; }
POST() { _fetch POST "$@"; }
PUT() { _fetch PUT "$@"; }
PATCH() { _fetch PATCH "$@"; }
DELETE() { _fetch DELETE "$@"; }

# Skip the request
#
# $@ {any} request_command - the request command starts with GET|POST|PUT|PATCH|DELETE
Skip() { 
  case $1 in
    GET|POST|PUT|PATCH|DELETE) ;;
    *) die "[ Skip $1 ... ] is invalid, expecting GET|POST|PUT|PATCH|DELETE";;
  esac
  skip=1 "$@"
}
# Only run the request
#
# $@ {any} request_command - the request command starts with GET|POST|PUT|PATCH|DELETE
# @need {1|any} ONLY - Only works when $ONLY = 1
Only() {
  case $1 in
    GET|POST|PUT|PATCH|DELETE) ;;
    *) die "[ Only $1 ... ] is invalid, expecting GET|POST|PUT|PATCH|DELETE";;
  esac
  if [ "${ONLY:-}" = 1 ]; then
    only=1 "$@"
  else
    # shellcheck disable=SC1007
    only= "$@"
  fi
}

# Add curl options for subsequent requests
#
# $@ {any} curl_options - options passed to curl as is
CurlOptionGlobal() {
  for opt in "$@"; do
    quote quoted "$opt"
    global_opts="${global_opts:-} ${quoted:-}"
  done
}
# Add curl options for the next request
#
# $@ {any} curl_options - options passed to curl as is
CurlOptionOnce() {
  for opt in "$@"; do
    quote quoted "$opt"
    once_opts="${once_opts:-} ${quoted:-}"
  done
}

# Enable trap _self_replace on exit
#
# @set {int} req_id - req_id + 1
Snapshot() {
  if [ ! "${trapped:-}" ]; then
    trap _self_replace EXIT
    trapped=1
  fi
  eval "snapshot_$req_id=\$SNAPSHOT"
  req_id=$((req_id + 1)) # increase count every single call and ignoring Skip/Only in order to sync with _self_replace
}

# Hook before each request
BeforeHook() { :; }
# Hook after each request
AfterHook() { :; }

# Standard after hook for rich snapshot
#
# @set {str} SNAPSHOT - set snapshot to header + curl meta + body
_std_jq_after_hook() {
  SNAPSHOT="$(jq --null-input --raw-output \
    --argjson selected '[ "content-type", "date", "http_code", "method", "time_total", "size_download", "url_effective" ]' \
    --argjson meta "$META_JSON" \
    --argjson header "$HEADER_JSON" '
$meta + $header
| to_entries
| map(select(.key | IN($selected[])))
| (map(.key | length) | max) as $max_len
| .[]
| .key + (" " * ($max_len - (.key | length) + 4)) + ([.value] | flatten | join(" "))')
-------------------------
$(jq --null-input --argjson body "$BODY" '$body' 2>/dev/null || printf '%s' "$BODY")"
}

# Interal before hook that calls BeforeHook
_before_hook() {
  BeforeHook
}

# Interal after hook that calls AfterHook
#
# $1 {str} response - response from previous request
_after_hook() {
  result=${1:-}
  if [ "$result" = '' ]; then
    EMPTY_RESULT=1
  else
    # shellcheck disable=SC2034
    EMPTY_RESULT=0
  fi
  case $result in
    *__POORMAN_DELIM__*)
      BODY=${result%%__POORMAN_DELIM__*}
      result=${result#*__POORMAN_DELIM__}
      META_JSON=${result%%__POORMAN_DELIM__*}
      result=${result#*__POORMAN_DELIM__}
      HEADER_JSON=$result # last one, no need to cut
      SNAPSHOT=$BODY
      ;;
    *)
      # shellcheck disable=SC2034
      SNAPSHOT=$result
      ;;
  esac
  if [ "${has_jq:-}" ] && [ "${META_JSON:-}" ] && [ "${HEADER_JSON:-}" ]; then
    _std_jq_after_hook
  fi
  AfterHook
}

# Trap function that injects all "Snapshot" to the script file
_self_replace() {
  new_content=
  req_id=0
  while IFS= read -r line; do
    case $line in
    Snapshot)
      eval "snapshot=\$snapshot_$req_id"
      if [ "${snapshot:-}" ]; then
        new_content="$new_content
: <<'SNAPSHOT'
${snapshot:-}
SNAPSHOT"
      else
        new_content="$new_content
$line"
      fi
      req_id=$((req_id + 1))
      ;;
    *)
      new_content="$new_content
$line"
      ;;
    esac
  done <"$0"
  printf '%s' "$new_content" >"$0"
}

