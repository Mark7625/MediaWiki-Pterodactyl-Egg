#!/usr/bin/env bash
# Download MediaWiki extensions/skins from bundled lists + MW_EXTENSIONS env override.

MW_EXT_WGET_TIMEOUT="${MW_EXT_WGET_TIMEOUT:-90}"
MW_EXT_GIT_TIMEOUT="${MW_EXT_GIT_TIMEOUT:-300}"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

mw_ext_module_dir() {
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mediawiki"
}

mw_ext_read_list() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -vE '^\s*($|#)' "$file" | sed 's/[[:space:]]*$//'
}

mw_ext_run_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

mw_ext_wget() {
  mw_ext_run_timeout "$((MW_EXT_WGET_TIMEOUT + 10))" \
    wget --timeout="$MW_EXT_WGET_TIMEOUT" --tries=2 "$@"
}

mw_ext_try_github_wikimedia() {
  local name="$1" dest="$2" branch="$3"
  rm -rf "$dest"
  mw_ext_run_timeout "$MW_EXT_GIT_TIMEOUT" git -c credential.helper= clone --depth 1 -b "${branch}" \
    "https://github.com/wikimedia/mediawiki-extensions-${name}.git" "$dest" >/dev/null 2>&1 \
    && [[ -f "${dest}/extension.json" ]]
}

mw_ext_try_extdist() {
  local name="$1" dest="$2" branch="$3" www="$4"
  local tgz="/tmp/mw-ext-${name}-${branch}.tar.gz"
  local extdist_url="https://extdist.wmflabs.org/dist/extensions/${name}-${branch}-latest.tar.gz"
  rm -f "$tgz"
  if mw_ext_wget -q "$extdist_url" -O "$tgz" 2>/dev/null; then
    tar xzf "$tgz" -C "${www}/extensions/" 2>/dev/null && rm -f "$tgz"
    [[ -f "${dest}/extension.json" ]]
  else
    rm -f "$tgz"
    return 1
  fi
}

mw_ext_download_wikimedia() {
  local name="$1"
  local branch="${MW_EXTENSION_BRANCH:-REL1_45}"
  local www="${WWW_DIR}"
  local dest="${www}/extensions/${name}"
  local -a try_branches=()
  local b via

  if [[ -f "${dest}/extension.json" ]]; then
    return 0
  fi

  echo -e "${WHITE}[MediaWiki] Extension ${name} (${branch})…${NC}"
  mkdir -p "${www}/extensions"

  try_branches+=("$branch" "REL1_45" "REL1_44" "master")
  for b in "${try_branches[@]}"; do
    if mw_ext_try_github_wikimedia "$name" "$dest" "$b"; then
      echo -e "${GREEN}[MediaWiki]   ✓ ${name} (GitHub ${b})${NC}"
      return 0
    fi
  done

  for b in "${try_branches[@]}"; do
    if mw_ext_try_extdist "$name" "$dest" "$b" "$www"; then
      echo -e "${GREEN}[MediaWiki]   ✓ ${name} (extdist ${b})${NC}"
      return 0
    fi
  done

  rm -rf "$dest"
  echo -e "${YELLOW}[MediaWiki]   Skipped ${name} (not on GitHub/extdist for REL1_45)${NC}"
  return 1
}

mw_ext_git_try_clone() {
  local url="$1" dest="$2" branch="$3"
  rm -rf "$dest"
  mw_ext_run_timeout "$MW_EXT_GIT_TIMEOUT" git -c credential.helper= clone --depth 1 -b "${branch}" "${url}" "$dest" >/dev/null 2>&1 \
    && [[ -f "${dest}/extension.json" ]]
}

mw_ext_download_git() {
  local name="$1" url="$2" branch="$3"
  local dest="${WWW_DIR}/extensions/${name}"
  local -a try_branches=()
  local b

  if [[ -f "${dest}/extension.json" ]]; then
    return 0
  fi

  echo -e "${WHITE}[MediaWiki] Extension ${name} (git ${branch})…${NC}"
  try_branches+=("$branch")
  if [[ "$branch" == REL1_* ]]; then
    try_branches+=("weirdgloop/${branch}")
  elif [[ "$branch" == weirdgloop/REL1_* ]]; then
    try_branches+=("${branch#weirdgloop/}")
  fi
  if [[ "$branch" != "master" && "$branch" != "main" ]]; then
    try_branches+=("master" "main")
  fi

  for b in "${try_branches[@]}"; do
    if mw_ext_git_try_clone "$url" "$dest" "$b"; then
      echo -e "${GREEN}[MediaWiki]   ✓ ${name} (branch ${b})${NC}"
      return 0
    fi
  done

  rm -rf "$dest"
  echo -e "${YELLOW}[MediaWiki]   Skipped git extension ${name} — ${url} (tried: ${try_branches[*]})${NC}"
  return 1
}

mw_ext_ensure_dependencies() {
  local -a resolved=("$@")
  local -a deps=()
  local ext d

  for ext in "${resolved[@]}"; do
    case "$ext" in
      Kartographer)
        [[ -f "${WWW_DIR}/extensions/JsonConfig/extension.json" ]] || deps+=(JsonConfig)
        ;;
    esac
  done

  [[ ${#deps[@]} -eq 0 ]] && { printf '%s\n' "${resolved[@]}"; return 0; }

  for d in "${deps[@]}"; do
    for ext in "${resolved[@]}"; do
      [[ "$ext" == "$d" ]] && continue 2
    done
    echo -e "${WHITE}[MediaWiki] Dependency ${d} required by bundled extensions…${NC}"
    if mw_ext_download_wikimedia "$d"; then
      resolved+=("$d")
    fi
  done

  if [[ ${#resolved[@]} -gt 0 ]]; then
    printf '%s\n' "${resolved[@]}"
  fi
}

mw_ext_filter_installed() {
  local -a resolved=("$@")
  local -a ok=()
  local ext
  for ext in "${resolved[@]}"; do
    if [[ -f "${WWW_DIR}/extensions/${ext}/extension.json" ]]; then
      ok+=("$ext")
    else
      echo -e "${YELLOW}[MediaWiki] Not on disk, omitting from install: ${ext}${NC}"
    fi
  done
  printf '%s\n' "${ok[@]}"
}

mw_skin_ready() {
  [[ -f "${WWW_DIR}/skins/${1}/skin.json" ]]
}

mw_skin_download() {
  local name="$1"
  local branch="${MW_SKIN_BRANCH:-${MW_EXTENSION_BRANCH:-REL1_45}}"
  local dest="${WWW_DIR}/skins/${name}"
  local -a try_branches=("$branch" "REL1_45" "master")
  local b

  if mw_skin_ready "$name"; then
    return 0
  fi

  echo -e "${WHITE}[MediaWiki] Skin ${name} (${branch})…${NC}"
  mkdir -p "${WWW_DIR}/skins"

  for b in "${try_branches[@]}"; do
    local tgz="/tmp/mw-skin-${name}-${b}.tar.gz"
    if mw_ext_wget -q "https://extdist.wmflabs.org/dist/skins/${name}-${b}-latest.tar.gz" -O "$tgz" 2>/dev/null; then
      tar xzf "$tgz" -C "${WWW_DIR}/skins/" 2>/dev/null && rm -f "$tgz"
      if mw_skin_ready "$name"; then
        echo -e "${GREEN}[MediaWiki]   ✓ skin ${name} (extdist ${b})${NC}"
        return 0
      fi
      rm -f "$tgz"
    fi
  done

  for b in "${try_branches[@]}"; do
    rm -rf "$dest"
    if mw_ext_run_timeout "$MW_EXT_GIT_TIMEOUT" git -c credential.helper= clone --depth 1 -b "${b}" \
      "https://github.com/wikimedia/mediawiki-skins-${name}.git" "$dest" >/dev/null 2>&1 \
      && mw_skin_ready "$name"; then
      echo -e "${GREEN}[MediaWiki]   ✓ skin ${name} (GitHub ${b})${NC}"
      return 0
    fi
  done

  echo -e "${YELLOW}[MediaWiki]   Skipped skin ${name}${NC}"
  return 1
}

mw_resolve_all_extensions() {
  local mod_dir
  mod_dir="$(mw_ext_module_dir)"
  local -a resolved=()
  local line name url branch raw ext total
  local -a filtered deps_out

  total=$(mw_ext_read_list "${mod_dir}/extensions-wikimedia.txt" | wc -l | tr -d ' ')
  total=$((total + $(mw_ext_read_list "${mod_dir}/extensions-weirdgloop.txt" | wc -l | tr -d ' ')))
  echo -e "${WHITE}[MediaWiki] Downloading up to ${total} extensions (git ${MW_EXT_GIT_TIMEOUT}s max each)…${NC}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    name="${line%%#*}"
    name="${name// /}"
    [[ -z "$name" ]] && continue
    [[ "${name,,}" == "wikidiff2" ]] && continue
    if mw_ext_download_wikimedia "$name"; then
      resolved+=("$name")
    fi
  done < <(mw_ext_read_list "${mod_dir}/extensions-wikimedia.txt")

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    IFS='|' read -r name url branch <<<"$line"
    name="${name// /}"
    url="${url// /}"
    branch="${branch:-${MW_EXTENSION_BRANCH:-REL1_45}}"
    [[ -z "$name" || -z "$url" ]] && continue
    if mw_ext_download_git "$name" "$url" "$branch"; then
      resolved+=("$name")
    fi
  done < <(mw_ext_read_list "${mod_dir}/extensions-weirdgloop.txt")

  if [[ -n "${MW_EXTENSIONS:-}" ]]; then
    IFS=',' read -ra _extra <<<"$MW_EXTENSIONS"
    for raw in "${_extra[@]}"; do
      ext="${raw// /}"
      [[ -z "$ext" ]] && continue
      if mw_ext_download_wikimedia "$ext"; then
        resolved+=("$ext")
      fi
    done
  fi

  if is_enabled "$ELASTICSEARCH_STATUS"; then
    for ext in CirrusSearch Elastica; do
      mw_ext_download_wikimedia "$ext" && resolved+=("$ext")
    done
  fi
  if is_enabled "$REDIS_STATUS"; then
    mw_ext_download_wikimedia Redis && resolved+=("Redis")
  fi

  if [[ ${#resolved[@]} -gt 0 ]]; then
    mapfile -t deps_out < <(mw_ext_ensure_dependencies "${resolved[@]}")
    resolved=("${deps_out[@]}")
  fi

  local -a uniq=()
  local e u
  for e in "${resolved[@]}"; do
    [[ -z "$e" ]] && continue
    for u in "${uniq[@]:-}"; do [[ "$u" == "$e" ]] && continue 2; done
    uniq+=("$e")
  done

  if [[ ${#uniq[@]} -gt 0 ]]; then
    mapfile -t filtered < <(mw_ext_filter_installed "${uniq[@]}")
    uniq=("${filtered[@]}")
  fi

  RESOLVED_EXTENSIONS=""
  if [[ ${#uniq[@]} -gt 0 ]]; then
    RESOLVED_EXTENSIONS=$(IFS=,; echo "${uniq[*]}")
  fi
}

mw_resolve_skins() {
  local mod_dir
  mod_dir="$(mw_ext_module_dir)"
  local -a skins=()
  local line s

  if [[ -n "${MW_SKINS:-}" ]]; then
    IFS=',' read -ra skins <<<"$MW_SKINS"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      skins+=("${line// /}")
    done < <(mw_ext_read_list "${mod_dir}/skins-default.txt")
  fi

  RESOLVED_SKINS=""
  local -a ok=()
  for s in "${skins[@]}"; do
    [[ -z "$s" ]] && continue
    if mw_skin_download "$s"; then
      ok+=("$s")
    fi
  done
  if [[ ${#ok[@]} -gt 0 ]]; then
    RESOLVED_SKINS=$(IFS=,; echo "${ok[*]}")
  fi
}
