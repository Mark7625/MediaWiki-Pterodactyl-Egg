#!/usr/bin/env bash
set -euo pipefail

# import_osrs_wiki.sh
# Pull selected pages (templates, specific pages) from https://oldschool.runescape.wiki
# and import them into your local MediaWiki via the API.
#
# Usage:
# 1) Put this file in /home/container/www (or run it from your host against container files).
# 2) Ensure you have `curl` and `jq` available in the environment where you run it.
# 3) Run interactively and provide your local wiki credentials, or set the env vars:
#    LOCAL_API (default: http://127.0.0.1/w/api.php)
#    LOCAL_USER
#    LOCAL_PASS
#
# Example:
#   LOCAL_API="http://127.0.0.1/w/api.php" LOCAL_USER="bot" ./import_osrs_wiki.sh --force
#
# Notes:
# - By default the script will CREATE pages that are missing on your local wiki.
# - Use --force to overwrite existing pages.
# - This script does NOT require admin access to the source wiki; it reads public pages.
# - Running it will perform edits on your local wiki as the user you supply.

SOURCE_API="https://oldschool.runescape.wiki/w/api.php"
LOCAL_API="${LOCAL_API:-http://127.0.0.1/w/api.php}"
LOCAL_USER="${LOCAL_USER:-}"
LOCAL_PASS="${LOCAL_PASS:-}"
FORCE=0
PAGE_LIMIT=50
COOKIEJAR="/tmp/import_mw_cookies_$$.txt"

RETRY=2
DELAY="${DELAY:-1}"
BACKOFF_MULT="2"

# Default pages to import in addition to templates
declare -a EXTRA_PAGES=(
  "MediaWiki:Common.css"
  "MediaWiki:Common.js"
)

usage() {
  cat <<EOF
Usage: $0 [--force] [--only-templates] [--only-pages] [--pages "Title1;Title2"]

Options:
  --force           Overwrite existing pages on the local wiki
  --only-templates   Import only pages in the Template namespace
  --only-pages      Import only the pages listed with --pages or EXTRA_PAGES
  --pages "A;B;C"    Semicolon-separated list of page titles to import
  --namespaces "A;B;C"  Semicolon-separated namespace names (e.g. Template;MediaWiki;Main)
  --delay N          Seconds to sleep between remote requests (default: 1)
  --help             Show this help

Env:
  LOCAL_API, LOCAL_USER, LOCAL_PASS

EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Required command not found: $1" >&2; exit 1; }
}

require_cmd curl
require_cmd jq

# Prompt for credentials if not provided
if [[ -z "$LOCAL_USER" ]]; then
  read -r -p "Local wiki username: " LOCAL_USER
fi
if [[ -z "$LOCAL_PASS" ]]; then
  read -r -s -p "Local wiki password: " LOCAL_PASS
  echo
fi

parse_args() {
  local pages_arg=""
  local only_templates=0
  local only_pages=0
  local import_all=0
  local ns_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE=1; shift;;
      --only-templates) only_templates=1; shift;;
      --only-pages) only_pages=1; shift;;
      --all) import_all=1; shift;;
      --namespaces|--ns) ns_arg="$2"; shift 2;;
      --delay) DELAY="$2"; shift 2;;
      --pages) pages_arg="$2"; shift 2;;
      --help) usage; exit 0;;
      *) echo "Unknown arg: $1"; usage; exit 1;;
    esac
  done

  if [[ $only_templates -eq 1 && $only_pages -eq 1 ]]; then
    echo "Cannot use --only-templates and --only-pages together" >&2; exit 1
  fi

  IFS=';' read -ra USER_PAGES <<<"$pages_arg"
  IFS=';' read -ra NAMESPACES <<<"$ns_arg"

  # Build list of target pages
  TARGET_PAGES=()
  if [[ $only_templates -eq 0 ]]; then
    for p in "${EXTRA_PAGES[@]}"; do TARGET_PAGES+=("$p"); done
    for p in "${USER_PAGES[@]}"; do [[ -n "$p" ]] && TARGET_PAGES+=("$p"); done
  fi

  ONLY_TEMPLATES=$only_templates
  IMPORT_ALL=$import_all
}

resolve_namespace_names_to_ids() {
  # Accepts array of namespace names in NAMESPACES and prints numeric ids (one per line)
  local res
  res=$(curl -sS "${SOURCE_API}?action=query&meta=siteinfo&siprop=namespaces&format=json") || return 1
  local name id lower
  for name in "${NAMESPACES[@]:-}"; do
    [[ -z "$name" ]] && continue
    # numeric already
    if [[ "$name" =~ ^-?[0-9]+$ ]]; then
      echo "$name"
      continue
    fi
    lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == "main" ]]; then
      echo 0
      continue
    fi
    id=$(echo "$res" | jq -r --arg name "$name" '(.query.namespaces | to_entries[] | select((.value.canonical // .value["*"]) | ascii_downcase == ($name|ascii_downcase)) | .key) // empty')
    if [[ -z "$id" ]]; then
      # try contains match
      id=$(echo "$res" | jq -r --arg name "$name" '(.query.namespaces | to_entries[] | select(((.value.canonical // .value["*"]) | ascii_downcase) | contains($name|ascii_downcase)) | .key) // empty')
    fi
    if [[ -n "$id" ]]; then
      echo "$id"
    else
      echo "Warning: namespace '$name' not found on source; skipping" >&2
    fi
  done
}

# Fetch all page titles in a namespace from SOURCE_API
fetch_allpages_from_source() {
  # If namespace argument is empty, fetch across all namespaces
  local namespace_arg="${1:-}"
  local apcontinue=""
  local -a pages=()

  while :; do
    local url="${SOURCE_API}?action=query&format=json&list=allpages&aplimit=max"
    if [[ -n "$namespace_arg" ]]; then
      url+="&apnamespace=${namespace_arg}"
    fi
    if [[ -n "$apcontinue" ]]; then
      url+="&apcontinue=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$apcontinue")"
    fi
    local res
    res=$(curl -sS "$url")
    # be polite to the source
    if [[ -n "$DELAY" && "$DELAY" -gt 0 ]]; then
      sleep "$DELAY"
    fi
    mapfile -t titles < <(echo "$res" | jq -r '.query.allpages[].title')
    pages+=("${titles[@]}")
    apcontinue=$(echo "$res" | jq -r '.continue.apcontinue // empty')
    if [[ -z "$apcontinue" ]]; then break; fi
  done

  printf "%s\n" "${pages[@]}"
}

# Get wikitext content from source for a given title
fetch_source_content() {
  local title="$1"
  local encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$title")
  local url="${SOURCE_API}?action=query&prop=revisions&rvprop=content&rvslots=main&format=json&titles=${encoded}"
  local attempt=0
  local res
  while :; do
    attempt=$((attempt+1))
    res=$(curl -sS "$url") || res=""
    # extract content
    local content
    content=$(echo "$res" | jq -r '.query.pages[] | .revisions[0].slots.main."*" // empty')
    if [[ -n "$content" ]]; then
      # polite sleep after successful fetch
      if [[ -n "$DELAY" && "$DELAY" -gt 0 ]]; then sleep "$DELAY"; fi
      echo "$content"
      return 0
    fi
    if [[ $attempt -ge $((RETRY+1)) ]]; then
      echo "";
      return 1
    fi
    # backoff then retry
    local backoff=$((DELAY * BACKOFF_MULT ** (attempt-1)))
    sleep "$backoff"
  done
}

# Local API helpers
local_query_page() {
  local title="$1"
  curl -sS -b "$COOKIEJAR" -c "$COOKIEJAR" --data-urlencode "action=query" --data-urlencode "format=json" --data-urlencode "titles=$title" "$LOCAL_API"
}

local_get_csrf_token() {
  curl -sS -b "$COOKIEJAR" -c "$COOKIEJAR" --data "action=query&meta=tokens&format=json" "$LOCAL_API" | jq -r '.query.tokens.csrftoken'
}

local_login() {
  # Get login token
  local token
  token=$(curl -sS -c "$COOKIEJAR" "$LOCAL_API?action=query&meta=tokens&type=login&format=json" | jq -r '.query.tokens.logintoken')
  if [[ -z "$token" || "$token" == "null" ]]; then echo "Failed to get login token" >&2; return 1; fi

  # Post login
  local res
  res=$(curl -sS -b "$COOKIEJAR" -c "$COOKIEJAR" -X POST --data-urlencode "action=login" --data-urlencode "format=json" --data-urlencode "lgname=$LOCAL_USER" --data-urlencode "lgpassword=$LOCAL_PASS" --data-urlencode "lgtoken=$token" "$LOCAL_API")
  if echo "$res" | jq -e '.login.status == "PASS"' >/dev/null 2>&1; then
    echo "Logged in as $LOCAL_USER"
    return 0
  else
    echo "Login failed: $(echo "$res" | jq -r '.login.description // .error.info // empty')" >&2
    return 1
  fi
}

local_edit_page() {
  local title="$1"
  local content="$2"
  local summary="$3"

  local token
  token=$(local_get_csrf_token)
  if [[ -z "$token" || "$token" == "null" ]]; then echo "Failed to get csrf token" >&2; return 1; fi

  # Use action=edit with text param; use createonly=1 when not forcing
  if [[ "$FORCE" -eq 1 ]]; then
    curl -sS -b "$COOKIEJAR" -c "$COOKIEJAR" -X POST --data-urlencode "action=edit" --data-urlencode "format=json" --data-urlencode "title=$title" --data-urlencode "text=$content" --data-urlencode "summary=$summary" --data-urlencode "token=$token" "$LOCAL_API"
  else
    curl -sS -b "$COOKIEJAR" -c "$COOKIEJAR" -X POST --data-urlencode "action=edit" --data-urlencode "format=json" --data-urlencode "title=$title" --data-urlencode "text=$content" --data-urlencode "summary=$summary" --data-urlencode "token=$token" --data-urlencode "createonly=1" "$LOCAL_API"
  fi
}

# Main import logic for a single title
import_title() {
  local title="$1"
  echo "--- Importing: $title"
  local content
  content=$(fetch_source_content "$title") || { echo "Failed to fetch $title" >&2; return 1; }
  if [[ -z "$content" ]]; then echo "No content found for $title; skipping"; return 0; fi

  # Check local existence
  local q
  q=$(local_query_page "$title")
  local missing
  missing=$(echo "$q" | jq -r '.query.pages[] | has("missing")')
  if [[ "$missing" == "true" ]]; then
    echo "Local page missing; creating $title"
    local_edit_page "$title" "$content" "Imported from oldschool.runescape.wiki"
  else
    if [[ "$FORCE" -eq 1 ]]; then
      echo "Local page exists; overwriting $title"
      local_edit_page "$title" "$content" "Imported (overwrite) from oldschool.runescape.wiki"
    else
      echo "Local page exists; skipping $title (use --force to overwrite)"
    fi
  fi
  # polite sleep between edits
  if [[ -n "$DELAY" && "$DELAY" -gt 0 ]]; then sleep "$DELAY"; fi
}

# Run
parse_args "$@"

# If ONLY_TEMPLATES then collect template list from source and import only those
if [[ "$IMPORT_ALL" -eq 1 ]]; then
  echo "Fetching all pages from source (this may be large)..."
  mapfile -t ALLP < <(fetch_allpages_from_source)
  TARGET_PAGES=("${ALLP[@]}")
elif [[ ${#NAMESPACES[@]} -gt 0 ]]; then
  echo "Resolving namespaces: ${NAMESPACES[*]}"
  mapfile -t NS_IDS < <(resolve_namespace_names_to_ids)
  echo "Fetching pages for namespace ids: ${NS_IDS[*]}"
  for nsid in "${NS_IDS[@]}"; do
    mapfile -t PAGES < <(fetch_allpages_from_source "$nsid")
    for p in "${PAGES[@]}"; do TARGET_PAGES+=("$p"); done
  done
else
  if [[ "$ONLY_TEMPLATES" -eq 1 ]]; then
    echo "Fetching templates from source..."
    mapfile -t TPLS < <(fetch_allpages_from_source 10)
    echo "Found ${#TPLS[@]} templates"
    TARGET_PAGES=("${TPLS[@]}")
  else
    # also append templates to target if not restricted
    echo "Fetching templates list to include in targets (namespace Template)..."
    mapfile -t TPLS < <(fetch_allpages_from_source 10)
    # Merge unique
    for t in "${TPLS[@]}"; do TARGET_PAGES+=("$t"); done
  fi
fi

if [[ ${#TARGET_PAGES[@]} -eq 0 ]]; then
  echo "No target pages to import"; exit 0
fi

# Login to local wiki
trap 'rm -f "$COOKIEJAR"' EXIT
if ! local_login; then echo "Login to local wiki failed" >&2; exit 1; fi

# Import each page
count=0
for title in "${TARGET_PAGES[@]}"; do
  import_title "$title"
  count=$((count+1))
done

echo "Imported $count pages."

# Cleanup
rm -f "$COOKIEJAR"

exit 0
