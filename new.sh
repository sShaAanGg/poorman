#!/bin/sh

# Scaffold collections and requests under ./collections.
#
# Usage:
#   ./new.sh --collection <collection> [--base-url <BASE_URL>]
#   ./new.sh <collection>/[<folder>/...]<request> [METHOD] [PATH]
#
#   BASE_URL  prefix of every request URL; can also be set later in _env.sh.
#             "--base-url" may be left out: --collection <collection> <BASE_URL>
#   METHOD    GET (default), POST, PUT, PATCH or DELETE
#   PATH      request path, defaults to /
#
# Examples:
#   ./new.sh --collection jsonplaceholder --base-url https://jsonplaceholder.typicode.com
#   ./new.sh jsonplaceholder/users/get-user GET /users/1

set -eu

root=$(cd "$(dirname "$0")" && pwd)
collections=$root/collections

usage() {
  # The comment block at the top of this file, up to the first non-comment line.
  sed -n '3,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0" >&2
  exit 1
}

[ $# -ge 1 ] || usage

if [ "$1" = --collection ]; then
  [ $# -ge 2 ] || usage
  name=$2
  shift 2
  case $# in
  0) base_url= ;;
  1) base_url=$1 ;;
  2)
    [ "$1" = --base-url ] || usage
    base_url=$2
    ;;
  *) usage ;;
  esac
  case $base_url in
  -*) usage ;;
  esac
  case $name in
  */* | '' | _*)
    echo "Invalid collection name: $name" >&2
    exit 1
    ;;
  esac
  env_file=$collections/$name/_env.sh
  if [ -e "$env_file" ]; then
    echo "Collection already exists: $name" >&2
    exit 1
  fi
  mkdir -p "$collections/$name"
  {
    cat <<EOF
# Shared by every request in the "$name" collection.
# Edit this file to set the base URL, headers, authentication and hooks.

EOF
    if [ "$base_url" ]; then
      # Single-quoted, so characters like & ? ; $ in the URL are kept as-is.
      printf "BASE_URL='%s'\n\n" "$(printf '%s' "$base_url" | sed "s/'/'\\\\''/g")"
    else
      printf '%s\n' "# Fill in your API's base URL, for example: BASE_URL='https://api.example.com'" 'BASE_URL=' ''
    fi
    cat <<'EOF'
# /// curl options ///
#
# Anything you write after "CurlOptionGlobal" is passed to curl, for every request
# in this collection. Uncomment a line and fill in your own values.
# Use CurlOptionOnce (above a single request) for an option that applies to that request only.
# Single quotes 'like this' for fixed text; double quotes "$LIKE_THIS" when it has a variable.
# All options: `man curl` or `curl --help all`.

# Follow redirects (needed if you get "301/302/307/308 ... Redirect").
# CurlOptionGlobal --location

# Basic auth (username:password)
# CurlOptionGlobal --user 'username:password'

# Bearer token (sends "Authorization: Bearer <token>")
# CurlOptionGlobal --oauth2-bearer 'your-token'

# API key (check the API docs for the header name)
# CurlOptionGlobal --header 'X-API-Key: your-key'

# Any other header
# CurlOptionGlobal --header 'Accept: application/json'

# TLS: "SSL certificate problem" / "certificate subject name ... does not match"
# (self-signed or internal servers). Quickest, for a trusted test server only:
# CurlOptionGlobal --insecure
# Proper fix: connect with the name on the certificate, map it to the IP, and trust the cert.
# Save the cert next to this file (curl resolves relative paths from where you run run.sh,
# so use $COLLECTION_DIR, not ../server.crt). Then set BASE_URL=https://the-cert-name/...
# CurlOptionGlobal --resolve the-cert-name:443:192.168.0.10
# CurlOptionGlobal --cacert "$COLLECTION_DIR/server.crt"
# Get the cert: openssl s_client -connect 192.168.0.10:443 </dev/null | openssl x509 > server.crt

# Give up after 10 seconds
# CurlOptionGlobal --max-time 10

# Hide curl's progress meter but still show errors
# CurlOptionGlobal --silent --show-error

# Show full request/response headers, for debugging (remove when done)
# CurlOptionGlobal --verbose

# Don't commit real secrets. Keep them in a git-ignored file next to this one
# and load it here, before the option that uses it:
#   . "$COLLECTION_DIR/_secrets.sh"     # _secrets.sh contains: TOKEN='your-token'
#   CurlOptionGlobal --oauth2-bearer "$TOKEN"
# Also avoid tokens in the URL (?api_key=...): snapshots record the full URL.

# /// hooks ///

AfterHook() {
  # Prints response body for every request
  printf '%s' "$BODY"
}
EOF
  } >"$env_file"
  echo "Created collections/$name/_env.sh"
  exit 0
fi

target=${1%.sh}
method=$(printf '%s' "${2:-GET}" | tr '[:lower:]' '[:upper:]')
path=${3:-/}

case $method in
GET | DELETE) args= ;;
POST | PUT | PATCH) args=" --json '{}'" ;;
*)
  echo "Unsupported method: $method (use GET, POST, PUT, PATCH or DELETE)" >&2
  exit 1
  ;;
esac

case $target in
*/*) ;;
*)
  echo "Expected <collection>/<request>, got: $target" >&2
  usage
  ;;
esac

collection=${target%%/*}
case $collection in
'' | _*)
  echo "Invalid collection name: $collection" >&2
  exit 1
  ;;
esac
if [ ! -f "$collections/$collection/_env.sh" ]; then
  echo "Unknown collection: $collection" >&2
  echo "Create it first: ./new.sh --collection $collection --base-url <BASE_URL>" >&2
  exit 1
fi

out=$collections/$target.sh
if [ -e "$out" ]; then
  echo "Refusing to overwrite existing file: collections/$target.sh" >&2
  exit 1
fi

# Number of directories between collections/ and the request file.
dir_path=${target%/*}
depth=1
rest=${dir_path#*/}
[ "$rest" = "$dir_path" ] || {
  old_ifs=$IFS
  IFS=/
  # shellcheck disable=SC2086
  set -- $rest
  IFS=$old_ifs
  depth=$((depth + $#))
}

ups() {
  n=$1 s=
  while [ "$n" -gt 0 ]; do
    s="$s/.."
    n=$((n - 1))
  done
  printf '%s' "${s#/}"
}
env_rel=$(ups $((depth - 1)))
poorman_rel=$(ups $((depth + 1)))
env_rel=${env_rel:-.}

mkdir -p "$(dirname "$out")"
cat >"$out" <<EOF
#!/bin/sh

_dir=\$(dirname "\$0")
. "\$_dir/$poorman_rel/poorman.sh"
COLLECTION_DIR=\$_dir/$env_rel
. "\$COLLECTION_DIR/_env.sh"

$method $path$args
Snapshot
EOF

chmod +x "$out"
echo "Created collections/$target.sh"
echo "Run it with: ./run.sh $target"
