#!/usr/bin/env bash
set -euo pipefail

# import_osrs_wiki.sh
# Pull selected pages (templates, specific pages) from https://oldschool.runescape.wiki
# and import them into your local MediaWiki via the API.
#
# Usage:
# 1) Put this file in /home/container/www (or run it from your host against container files).
# 2) Ensure you have `curl` and `python3` available in the environment where you run it.
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
LOCAL_API="${LOCAL_API:-https://wiki.fluxious-rsps.com/api.php}"
LOCAL_USER="${LOCAL_USER:-}"
LOCAL_PASS="${LOCAL_PASS:-}"
FORCE=0
FROM_XML=""
NO_LOGIN=0
XML_NAMESPACE=""
PAGE_LIMIT=50
COOKIEJAR="/tmp/import_mw_cookies_$$.txt"
USER_AGENT="${USER_AGENT:-Mozilla/5.0 (import-script)}"

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
  --from-xml <file>   Import pages directly from a MediaWiki XML dump
  --xml-namespace NS  Limit XML import to a namespace name or numeric id
  --no-login         Skip local wiki login and edit anonymously
  --delay N          Seconds to sleep between remote requests (default: 1)
  --help             Show this help

Env:
  LOCAL_API, LOCAL_USER, LOCAL_PASS

EOF
}

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
          --from-xml) FROM_XML="$2"; shift 2;;
          --no-login) NO_LOGIN=1; shift;;
          --xml-namespace) XML_NAMESPACE="$2"; shift 2;;
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

# Import pages directly from a MediaWiki XML dump (streaming)
import_from_xml() {
  local xmlfile="$1"
  local ns="$2"
  if [[ ! -f "$xmlfile" ]]; then echo "XML file not found: $xmlfile" >&2; return 1; fi

  # map common namespace names to ids (default MediaWiki -> 8)
  case "${ns,,}" in
    mediawiki) ns_id=8;;
    template) ns_id=10;;
    main|\(main\)) ns_id=0;;
    '') ns_id="";;
    *)
      # if it's numeric use it, else use all namespaces
      if [[ "$ns" =~ ^-?[0-9]+$ ]]; then ns_id="$ns"; else ns_id=""; fi
      ;;
  esac

  if [[ "$NO_LOGIN" -ne 1 ]]; then
    if [[ -z "$LOCAL_USER" ]]; then
      read -r -p "Local wiki username: " LOCAL_USER
    fi
    if [[ -z "$LOCAL_PASS" ]]; then
      read -r -s -p "Local wiki password: " LOCAL_PASS
      echo
    fi
    if ! local_login; then echo "Login to local wiki failed" >&2; return 1; fi
  else
    echo "Skipping login (anonymous edits)"
  fi

  if [[ -z "$ns_id" ]]; then
    echo "Streaming import from XML $xmlfile for all namespaces"
  else
    echo "Streaming import from XML $xmlfile for namespace id $ns_id"
  fi

  python3 - "$xmlfile" "$ns_id" <<'PY' | while IFS='|' read -r btitle btext; do
import sys,xml.etree.ElementTree as ET,base64
nsid=sys.argv[2]
context=ET.iterparse(sys.argv[1],events=("end",))
for event,elem in context:
  if elem.tag.endswith('page'):
    title=elem.findtext('title') or ''
    ns=elem.findtext('ns') or '0'
    if nsid == '' or ns == nsid:
      text=elem.find('revision').findtext('text') if elem.find('revision') is not None else ''
      print(base64.b64encode(title.encode()).decode()+"|"+base64.b64encode((text or '').encode()).decode())
    elem.clear()
PY
    title=$(python3 -c "import sys,base64; print(base64.b64decode(sys.argv[1]).decode())" "$btitle")
    content=$(python3 -c "import sys,base64; print(base64.b64decode(sys.argv[1]).decode())" "$btext")
    echo "Importing from XML: $title"
    local_edit_page "$title" "$content" "Imported from XML"
    if [[ -n "$DELAY" && "$DELAY" -gt 0 ]]; then sleep "$DELAY"; fi
  done
}

resolve_namespace_names_to_ids() {
  # Accepts array of namespace names in NAMESPACES and prints numeric ids (one per line)
  local res
  res=$(curl -sS -A "$USER_AGENT" "${SOURCE_API}?action=query&meta=siteinfo&siprop=namespaces&format=json") || return 1
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
    id=$(echo "$res" | python3 -c 'import sys,json
name=sys.argv[1].lower()
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(0)
ns=j.get("query",{}).get("namespaces",{})
for k,v in ns.items():
  label=""
  if isinstance(v,dict):
    label=(v.get("canonical") or v.get("*") or v.get("name") or "")
  else:
    label=str(v)
  if label and label.lower()==name:
    print(k); sys.exit(0)
for k,v in ns.items():
  label=""
  if isinstance(v,dict):
    label=(v.get("canonical") or v.get("*") or v.get("name") or "")
  else:
    label=str(v)
  if name in label.lower():
    print(k); sys.exit(0)
' "$name")
    if [[ -n "$id" ]]; then
      echo "$id"
    else
      echo "Warning: namespace '$name' not found on source; skipping" >&2
    fi
  done
}

resolve_single_namespace_name_to_id() {
  local name="$1"
  if [[ -z "$name" ]]; then return 0; fi
  if [[ "$name" =~ ^-?[0-9]+$ ]]; then echo "$name"; return 0; fi
  local res
  res=$(curl -sS -A "$USER_AGENT" "${SOURCE_API}?action=query&meta=siteinfo&siprop=namespaces&format=json") || return 1
  local id
  id=$(echo "$res" | python3 -c 'import sys,json
name=sys.argv[1].lower()
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(0)
ns=j.get("query",{}).get("namespaces",{})
for k,v in ns.items():
  label=""
  if isinstance(v,dict):
    label=(v.get("canonical") or v.get("*") or v.get("name") or "")
  else:
    label=str(v)
  if label and label.lower()==name:
    print(k); sys.exit(0)
for k,v in ns.items():
  label=""
  if isinstance(v,dict):
    label=(v.get("canonical") or v.get("*") or v.get("name") or "")
  else:
    label=str(v)
  if name in label.lower():
    print(k); sys.exit(0)
'
"$name")
  echo "$id"
}

fetch_allpages_with_prefix() {
  # Fetch pages whose title starts with PREFIX:
  local prefix="$1"
  local apcontinue=""
  local -a pages=()
  while :; do
    local url="${SOURCE_API}?action=query&format=json&list=allpages&aplimit=max&apprefix=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${prefix}:")"
    if [[ -n "$apcontinue" ]]; then
      url+="&apcontinue=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$apcontinue")"
    fi
    local res
    res=$(curl -sS -A "$USER_AGENT" "$url")
    mapfile -t titles < <(echo "$res" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(0)
for p in j.get("query",{}).get("allpages",[]):
  print(p.get("title",""))
')
    pages+=("${titles[@]}")
    apcontinue=$(echo "$res" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  print(""); sys.exit(0)
print(j.get("continue",{}).get("apcontinue",""))
')
    if [[ -z "$apcontinue" ]]; then break; fi
    if [[ -n "$DELAY" && "$DELAY" -gt 0 ]]; then sleep "$DELAY"; fi
  done
  printf "%s\n" "${pages[@]}"
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
    mapfile -t titles < <(echo "$res" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(0)
for p in j.get("query",{}).get("allpages",[]):
  print(p.get("title",""))
')
    pages+=("${titles[@]}")
    apcontinue=$(echo "$res" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  print(""); sys.exit(0)
print(j.get("continue",{}).get("apcontinue",""))
')
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
    content=$(echo "$res" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(0)
pages=j.get("query",{}).get("pages",{})
for p in pages.values():
  revs=p.get("revisions") or []
  if revs:
    slots=revs[0].get("slots",{})
    main=slots.get("main",{})
    cont=main.get("*")
    if cont:
      print(cont)
      sys.exit(0)
print("")
')
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
  curl -sS -b "$COOKIEJAR" -c "$COOKIEJAR" --data "action=query&meta=tokens&format=json" "$LOCAL_API" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(1)
print(j.get("query",{}).get("tokens",{}).get("csrftoken",""))
'
}

local_login() {
  # Get login token
  local token
  token=$(curl -sS -c "$COOKIEJAR" "$LOCAL_API?action=query&meta=tokens&type=login&format=json" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(1)
print(j.get("query",{}).get("tokens",{}).get("logintoken",""))
')
  if [[ -z "$token" || "$token" == "null" ]]; then echo "Failed to get login token" >&2; return 1; fi

  # Post login
  local res
  res=$(curl -sS -b "$COOKIEJAR" -c "$COOKIEJAR" -X POST --data-urlencode "action=login" --data-urlencode "format=json" --data-urlencode "lgname=$LOCAL_USER" --data-urlencode "lgpassword=$LOCAL_PASS" --data-urlencode "lgtoken=$token" "$LOCAL_API")
  if echo "$res" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  sys.exit(1)
st=j.get("login",{}).get("status")
res=j.get("login",{}).get("result")
sys.exit(0 if st=="PASS" or res=="Success" else 1)
'; then
    echo "Logged in as $LOCAL_USER"
    return 0
  else
    echo "Login failed: $(echo "$res" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  print(""); sys.exit(0)
print((j.get("login",{}).get("description") or j.get("error",{}).get("info") or ""))
')" >&2
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
  missing=$(echo "$q" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
except Exception:
  print("false"); sys.exit(0)
pages=j.get("query",{}).get("pages",{}).values()
print("true" if any(("missing" in p) for p in pages) else "false")
')
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

if [[ -n "$FROM_XML" ]]; then
  import_from_xml "$FROM_XML" "$XML_NAMESPACE"
  exit $?
fi

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
