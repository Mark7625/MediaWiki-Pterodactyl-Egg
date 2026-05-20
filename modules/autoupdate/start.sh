#!/usr/bin/env bash
# Convert line endings to Unix format
sed -i 's/\r$//' "$0" 2>/dev/null || true

set -euo pipefail
trap 'echo -e "${RED}[AutoUpdate] Error on line $LINENO${NC}"' ERR

# Color definitions
BLUE='\033[0;34m'; BOLD_BLUE='\033[1;34m'
WHITE='\033[0;37m'; GREEN='\033[0;32m'
YELLOW='\033[0;33m'; RED='\033[0;31m'
MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# CRYPTOGRAPHIC SIGNATURE VERIFICATION
# ============================================================================
# GitHub updates are not signed via Tavuru; leave empty to skip signature checks.
PUBLIC_KEY_BASE64=""

# Verify signature of downloaded update
# Usage: verify_signature <file_path> <signature_base64> <expected_hash>
# Returns: 0 if valid, 1 if invalid or verification unavailable
verify_signature() {
    local file_path="$1"
    local signature_b64="$2"
    local expected_hash="$3"

    # Skip verification if no public key is configured
    if [[ -z "$PUBLIC_KEY_BASE64" ]]; then
        echo -e "${YELLOW}[AutoUpdate] ⚠ Signature verification skipped - no public key configured${NC}"
        return 0
    fi

    # Check if openssl is available
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${YELLOW}[AutoUpdate] ⚠ Signature verification skipped - openssl not available${NC}"
        return 0
    fi

    echo -e "${CYAN}[AutoUpdate] 🔐 Verifying cryptographic signature...${NC}"

    # Verify file hash first
    local actual_hash
    actual_hash=$(sha256sum "$file_path" | cut -d' ' -f1)

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo -e "${RED}[AutoUpdate] ✗ Hash mismatch!${NC}"
        echo -e "${RED}[AutoUpdate]   Expected: $expected_hash${NC}"
        echo -e "${RED}[AutoUpdate]   Actual:   $actual_hash${NC}"
        return 1
    fi

    echo -e "${GREEN}[AutoUpdate] ✓ Hash verified: ${actual_hash:0:16}...${NC}"

    # Decode public key and signature to temp files
    local temp_dir
    temp_dir=$(mktemp -d)
    local pub_key_file="$temp_dir/public.pem"
    local sig_file="$temp_dir/signature.bin"
    local hash_file="$temp_dir/hash.bin"

    # Convert base64 public key to PEM format for Ed25519
    # Ed25519 public key is 32 bytes, we need to wrap it in proper ASN.1 structure
    {
        echo "-----BEGIN PUBLIC KEY-----"
        # Add Ed25519 OID prefix (MCowBQYDK2VwAyEA) + base64 public key
        echo "MCowBQYDK2VwAyEA$(echo "$PUBLIC_KEY_BASE64")" | fold -w 64
        echo "-----END PUBLIC KEY-----"
    } > "$pub_key_file"

    # Decode signature from base64
    echo "$signature_b64" | base64 -d > "$sig_file" 2>/dev/null || {
        echo -e "${RED}[AutoUpdate] ✗ Failed to decode signature${NC}"
        rm -rf "$temp_dir"
        return 1
    }

    # Create hash file (the signature is over the hash, not the file directly)
    # Convert hex to binary - use xxd if available, otherwise use printf
    if command -v xxd >/dev/null 2>&1; then
        echo -n "$expected_hash" | xxd -r -p > "$hash_file"
    else
        # Fallback: convert hex to binary using printf
        local hex="$expected_hash"
        local i
        > "$hash_file"  # Create empty file
        for ((i=0; i<${#hex}; i+=2)); do
            printf "\x${hex:$i:2}" >> "$hash_file"
        done
    fi

    # Verify signature using openssl (Ed25519)
    if openssl pkeyutl -verify -pubin -inkey "$pub_key_file" \
        -sigfile "$sig_file" -in "$hash_file" -rawin 2>/dev/null; then
        echo -e "${GREEN}[AutoUpdate] ✓ Signature verified - update is authentic${NC}"
        rm -rf "$temp_dir"
        return 0
    else
        echo -e "${RED}[AutoUpdate] ✗ Signature verification FAILED!${NC}"
        echo -e "${RED}[AutoUpdate]   The update may have been tampered with.${NC}"
        echo -e "${RED}[AutoUpdate]   Update will NOT be applied for security reasons.${NC}"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Header function
header() {
  echo -e "${BLUE}───────────────────────────────────────────────${NC}"
  echo -e "${BOLD_BLUE}[AutoUpdate] $1${NC}"
}

# Configuration via environment variables
AUTOUPDATE_STATUS="${AUTOUPDATE_STATUS:-true}"
AUTOUPDATE_FORCE="${AUTOUPDATE_FORCE:-false}"
VERSION_FILE="/home/container/VERSION"
EGG_REPO="${EGG_REPO:-https://github.com/Mark7625/MediaWiki-Pterodactyl-Egg}"
EGG_BRANCH="${EGG_BRANCH:-master}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_OWNER="Mark7625"
GITHUB_REPO="MediaWiki-Pterodactyl-Egg"
CONTAINER_ROOT="/home/container"
TEMP_DIR="/home/container/tmp/autoupdate"

parse_egg_repo() {
  local url="${EGG_REPO%.git}"
  if [[ "$url" =~ github\.com[:/]+([^/]+)/([^/]+) ]]; then
    GITHUB_OWNER="${BASH_REMATCH[1]}"
    GITHUB_REPO="${BASH_REMATCH[2]}"
  fi
}
parse_egg_repo

http_download() {
  local url="$1" outfile="$2"
  local gh_headers=(
    -H "Accept: application/vnd.github+json"
    -H "User-Agent: MediaWiki-Pterodactyl-Egg"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  if command -v curl >/dev/null 2>&1; then
    local http_code
    http_code=$(curl -sSL --max-time 60 "${gh_headers[@]}" \
      -w "%{http_code}" -o "$outfile" "$url" 2>/dev/null) || http_code="000"
    if [[ "$http_code" == "200" && -s "$outfile" ]]; then
      return 0
    fi
    echo -e "${YELLOW}[AutoUpdate] HTTP ${http_code} — ${url}${NC}" >&2
    if [[ -s "$outfile" ]]; then
      grep -oE '"message":"[^"]*"' "$outfile" 2>/dev/null | head -1 >&2 || true
    fi
    return 1
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget --timeout=60 --tries=2 -q \
      --header="Accept: application/vnd.github+json" \
      --header="User-Agent: MediaWiki-Pterodactyl-Egg" \
      --header="X-GitHub-Api-Version: 2022-11-28" \
      -O "$outfile" "$url" 2>/dev/null && [[ -s "$outfile" ]]; then
      return 0
    fi
    echo -e "${YELLOW}[AutoUpdate] wget failed — ${url}${NC}" >&2
    return 1
  fi
  return 1
}

# Resolve latest short SHA for a branch (git ls-remote, then GitHub API).
latest_commit_sha_short() {
  local branch="$1"
  local sha="" url="${EGG_REPO%.git}"

  if command -v git >/dev/null 2>&1; then
    sha=$(git ls-remote "$url" "refs/heads/${branch}" 2>/dev/null | awk '{print $1; exit}')
    if [[ "$sha" =~ ^[a-f0-9]{40}$ ]]; then
      printf '%s\n' "${sha:0:7}"
      return 0
    fi
  fi

  local api_url="${GITHUB_API}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/commits/${branch}"
  local temp_file="${TEMP_DIR}/github_commit_${branch}.json"
  if http_download "$api_url" "$temp_file"; then
    sha=$(grep -oE '"sha"\s*:\s*"[a-f0-9]{40}"' "$temp_file" | head -1 | grep -oE '[a-f0-9]{40}')
    rm -f "$temp_file"
    if [[ "$sha" =~ ^[a-f0-9]{40}$ ]]; then
      printf '%s\n' "${sha:0:7}"
      return 0
    fi
  fi
  rm -f "$temp_file"
  return 1
}

# Check for staged self-update
check_staged_update() {
  local staging_dir="${CONTAINER_ROOT}/.autoupdate_staged"
  
  if [[ -d "$staging_dir/autoupdate" ]]; then
    echo -e "${YELLOW}[AutoUpdate] 🔄  Staged self-update detected${NC}"
    echo -e "${CYAN}[AutoUpdate] Applying staged auto-update module...${NC}"
    
    # Backup current autoupdate module
    local backup_dir="${CONTAINER_ROOT}/.autoupdate_backup_$(date +%s)"
    mkdir -p "$backup_dir"
    cp -r "${CONTAINER_ROOT}/modules/autoupdate" "$backup_dir/" 2>/dev/null || true
    
    # Apply staged update
    if cp -r "$staging_dir/autoupdate" "${CONTAINER_ROOT}/modules/" 2>/dev/null; then
      chmod +x "${CONTAINER_ROOT}/modules/autoupdate/start.sh" 2>/dev/null || true
      echo -e "${GREEN}[AutoUpdate] ✓ Self-update applied successfully${NC}"
      echo -e "${CYAN}[AutoUpdate] Backup saved to: $backup_dir${NC}"
      
      # Clean up staging
      rm -rf "$staging_dir" 2>/dev/null || true
      
      echo -e "${BOLD_BLUE}[AutoUpdate] Now running updated auto-update module${NC}"
    else
      echo -e "${RED}[AutoUpdate] Failed to apply staged update${NC}"
      echo -e "${YELLOW}[AutoUpdate] Continuing with current version${NC}"
    fi
  fi
}

# Function to check if auto-update should be enabled
enabled() { [[ "$1" =~ ^(true|1)$ ]]; }

# Skip if auto-update is disabled
if ! enabled "$AUTOUPDATE_STATUS"; then
  exit 0
fi

# Check for staged self-update first
check_staged_update

# Start header
header "Checking for Updates"

# Create temp directory for downloads
mkdir -p "$TEMP_DIR"

# Function to get current version from file
get_current_version() {
  if [[ -f "$VERSION_FILE" ]] && [[ -s "$VERSION_FILE" ]]; then
    local version
    version=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '\n\r' | head -1)
    if [[ -n "$version" && "$version" != "unknown" ]]; then
      echo "$version"
      return 0
    fi
  fi
  
  echo "unknown"
}

# Latest version = short git SHA on EGG_BRANCH (matches install-script VERSION file).
get_latest_version() {
  local branch sha seen_branches="" b
  echo -e "${WHITE}[AutoUpdate] Resolving latest commit (${GITHUB_OWNER}/${GITHUB_REPO})…${NC}" >&2

  for b in "$EGG_BRANCH" master main; do
    [[ -z "$b" ]] && continue
    [[ " $seen_branches " == *" $b "* ]] && continue
    seen_branches+=" $b"
    echo -e "${CYAN}[AutoUpdate] Trying branch: ${b}${NC}" >&2
    if sha=$(latest_commit_sha_short "$b"); then
      if [[ "$b" != "$EGG_BRANCH" ]]; then
        echo -e "${YELLOW}[AutoUpdate] Using branch '${b}' (set EGG_BRANCH=${b} in the panel)${NC}" >&2
      fi
      printf '%s\n' "$sha"
      return 0
    fi
  done

  echo -e "${RED}[AutoUpdate] Failed to fetch commit from GitHub (tried: ${seen_branches# })${NC}" >&2
  return 1
}

# True when an update should be applied (git SHAs or semver).
update_is_available() {
  local current="$1"
  local latest="$2"
  current=$(echo "$current" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  latest=$(echo "$latest" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [[ -n "$current" && -n "$latest" && "$current" != "$latest" ]]
}

# Function to compare versions with proper semantic versioning
version_compare() {
  local current="$1"
  local latest="$2"
  
  # Convert to lowercase for case-insensitive comparison
  current=$(echo "$current" | tr '[:upper:]' '[:lower:]')
  latest=$(echo "$latest" | tr '[:upper:]' '[:lower:]')
  
  # Remove 'v' prefix if present
  current="${current#v}"
  latest="${latest#v}"
  
  # Handle exact match
  if [[ "$current" == "$latest" ]]; then
    return 0  # Equal
  fi
  
  # Split versions into arrays (major.minor.patch)
  IFS='.' read -ra current_parts <<< "$current"
  IFS='.' read -ra latest_parts <<< "$latest"
  
  # Pad arrays to same length (fill missing parts with 0)
  local max_length=$(( ${#current_parts[@]} > ${#latest_parts[@]} ? ${#current_parts[@]} : ${#latest_parts[@]} ))
  
  # Ensure we have at least 3 parts for comparison
  while [[ ${#current_parts[@]} -lt $max_length ]] || [[ ${#current_parts[@]} -lt 3 ]]; do
    current_parts+=("0")
  done
  
  while [[ ${#latest_parts[@]} -lt $max_length ]] || [[ ${#latest_parts[@]} -lt 3 ]]; do
    latest_parts+=("0")
  done
  
  # Compare each version component numerically
  for i in $(seq 0 $((max_length - 1))); do
    local current_part="${current_parts[$i]:-0}"
    local latest_part="${latest_parts[$i]:-0}"
    
    # Remove leading zeros and ensure numeric comparison
    # Handle non-numeric parts by defaulting to 0
    if [[ "$current_part" =~ ^[0-9]+$ ]]; then
      current_part=$((10#$current_part))
    else
      current_part=0
    fi
    
    if [[ "$latest_part" =~ ^[0-9]+$ ]]; then
      latest_part=$((10#$latest_part))
    else
      latest_part=0
    fi
    
    if [[ $current_part -lt $latest_part ]]; then
      return 1  # Current is older
    elif [[ $current_part -gt $latest_part ]]; then
      return 2  # Current is newer
    fi
    # If equal, continue to next component
  done
  
  # All components are equal
  return 0
}

# Function to safely create or update version file
update_version_file() {
  local new_version="$1"
  
  if printf "%s\n" "$new_version" > "$VERSION_FILE" 2>/dev/null; then
    echo -e "${GREEN}[AutoUpdate] Version file updated to ${new_version}${NC}"
  else
    echo -e "${YELLOW}[AutoUpdate] Could not write version file, but update was successful${NC}"
  fi
}

# ============================================================================
# PRE-UPDATE BACKUP
# ============================================================================
# Creates a timestamped backup of every file that is about to be overwritten.
# Only files that already exist on disk AND appear in the update package are
# backed up – so the snapshot reflects exactly what will change.
#
# Backup location:
#   /home/container/.autoupdate_prebackup_<fromVer>_to_<toVer>_<timestamp>/
#
# A human-readable .backup_info file is written into the backup root so you
# can always tell at a glance what the backup contains and when it was made.
# ============================================================================
create_pre_update_backup() {
  local extract_dir="$1"
  local from_version="$2"
  local to_version="$3"

  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="${CONTAINER_ROOT}/.autoupdate_prebackup_${from_version}_to_${to_version}_${timestamp}"
  mkdir -p "$backup_dir"

  echo -e "${CYAN}[AutoUpdate] 💾 Creating pre-update backup...${NC}"
  local backed_up=0

  # Walk every file present in the extracted update package
  while IFS= read -r -d '' extracted_file; do
    local rel_path="${extracted_file#${extract_dir}/}"
    local live_file="${CONTAINER_ROOT}/${rel_path}"

    # Only back up files that actually exist on disk right now
    if [[ -f "$live_file" ]]; then
      local target_dir
      target_dir=$(dirname "${backup_dir}/${rel_path}")
      mkdir -p "$target_dir"
      cp "$live_file" "${backup_dir}/${rel_path}"
      backed_up=$((backed_up + 1))
    fi
  done < <(find "$extract_dir" -type f -print0)

  if [[ $backed_up -gt 0 ]]; then
    # Write human-readable info file
    {
      echo "Pre-update backup"
      echo "From version : $from_version"
      echo "To version   : $to_version"
      echo "Created at   : $(date)"
      echo "Files backed up: $backed_up"
    } > "${backup_dir}/.backup_info"

    echo -e "${GREEN}[AutoUpdate] ✓ Backed up ${backed_up} file(s) → $(basename "$backup_dir")${NC}"
    echo -e "${CYAN}[AutoUpdate] Backup location: ${backup_dir}${NC}"
  else
    echo -e "${YELLOW}[AutoUpdate] No existing files to back up${NC}"
    rmdir "$backup_dir" 2>/dev/null || true
  fi
}

# Clone or download egg source from GitHub into $1 (repo root).
fetch_egg_source() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"

  if command -v git >/dev/null 2>&1; then
    echo -e "${WHITE}[AutoUpdate] Cloning ${EGG_REPO} (branch ${EGG_BRANCH})…${NC}"
    if git clone --depth 1 --branch "$EGG_BRANCH" "$EGG_REPO" "$dest" >>"${TEMP_DIR}/git.log" 2>&1; then
      return 0
    fi
    echo -e "${YELLOW}[AutoUpdate] git clone failed, trying GitHub archive…${NC}"
    rm -rf "$dest"
  fi

  local archive_url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/archive/refs/heads/${EGG_BRANCH}.tar.gz"
  local tgz="${TEMP_DIR}/egg-archive.tar.gz"
  local extract_parent="${TEMP_DIR}/archive-extract"
  rm -rf "$extract_parent" "$tgz"
  mkdir -p "$extract_parent"

  echo -e "${WHITE}[AutoUpdate] Downloading ${archive_url}…${NC}"
  if ! http_download "$archive_url" "$tgz"; then
    echo -e "${RED}[AutoUpdate] Failed to download egg archive${NC}"
    return 1
  fi

  if ! tar -xzf "$tgz" -C "$extract_parent" 2>/dev/null; then
    echo -e "${RED}[AutoUpdate] Failed to extract egg archive${NC}"
    rm -f "$tgz"
    return 1
  fi
  rm -f "$tgz"

  local top_dir
  top_dir=$(find "$extract_parent" -mindepth 1 -maxdepth 1 -type d | head -1)
  if [[ -z "$top_dir" ]]; then
    echo -e "${RED}[AutoUpdate] Archive extract directory is empty${NC}"
    return 1
  fi
  mv "$top_dir" "$dest"
  rm -rf "$extract_parent"
  return 0
}

# Download from GitHub and apply allowed paths.
apply_update() {
  local from_version="$1"
  local to_version="$2"

  echo -e "${CYAN}[AutoUpdate] Updating egg files ${from_version} → ${to_version} from GitHub…${NC}"

  local extract_dir="${TEMP_DIR}/egg-source"
  if ! fetch_egg_source "$extract_dir"; then
    return 1
  fi

  echo -e "${WHITE}[AutoUpdate] Applying updates from repository…${NC}"

  local updated_files=0
  local allowed_dirs=("modules" "nginx" "php" "scripts")
  local allowed_files=("start-modules.sh" "README.md" "LICENSE")
  # Files that must never be overwritten by updates (relative to CONTAINER_ROOT)
  local protected_files=("nginx/conf.d/default.conf")
  local self_update_required=false

  # Remove protected files from the extraction directory before backup and copy.
  # This ensures they are neither backed up (they won't change) nor overwritten.
  echo -e "${CYAN}[AutoUpdate] Applying file protection rules...${NC}"
  for protected in "${protected_files[@]}"; do
    local protected_path="${extract_dir}/${protected}"
    if [[ -f "$protected_path" ]]; then
      rm -f "$protected_path"
      echo -e "${YELLOW}[AutoUpdate] 🔒 Protected (skipped): ${protected}${NC}"
    fi
  done

  # Back up every file that exists on disk and is about to be overwritten.
  # Runs AFTER protected files are removed so the backup only covers what
  # will actually change.
  create_pre_update_backup "$extract_dir" "$from_version" "$to_version"

  # Check if autoupdate module itself needs updating
  if [[ -f "${extract_dir}/modules/autoupdate/start.sh" ]]; then
    echo -e "${YELLOW}[AutoUpdate] ⚠ Auto-update module itself has updates${NC}"
    echo -e "${CYAN}[AutoUpdate] Self-update will be applied after server restart${NC}"
    self_update_required=true
  fi
  
  # Update allowed directories (skip autoupdate if it needs self-update)
  for dir in "${allowed_dirs[@]}"; do
    if [[ -d "${extract_dir}/${dir}" ]]; then
      if [[ "$dir" == "modules" && "$self_update_required" == "true" ]]; then
        echo -e "${CYAN}[AutoUpdate] Updating directory: ${dir} (excluding autoupdate)${NC}"
        
        # Copy all module directories except autoupdate
        for module_subdir in "${extract_dir}/${dir}"/*; do
          if [[ -d "$module_subdir" ]]; then
            local module_name=$(basename "$module_subdir")
            if [[ "$module_name" != "autoupdate" ]]; then
              echo -e "${WHITE}[AutoUpdate] Updating module: ${module_name}${NC}"
              cp -r "$module_subdir" "${CONTAINER_ROOT}/${dir}/" 2>/dev/null || true
              find "${CONTAINER_ROOT}/${dir}/${module_name}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
            fi
          fi
        done
        
        # Stage autoupdate for next restart in protected location
        local staging_dir="${CONTAINER_ROOT}/.autoupdate_staged"
        mkdir -p "$staging_dir"
        cp -r "${extract_dir}/modules/autoupdate" "$staging_dir/" 2>/dev/null || true
        chmod +x "$staging_dir/autoupdate/start.sh" 2>/dev/null || true
        echo "$(date): Auto-update module staged for next restart" > "$staging_dir/.staging_info"
        echo -e "${YELLOW}[AutoUpdate] Auto-update module staged for next restart${NC}"
        
      else
        echo -e "${CYAN}[AutoUpdate] Updating directory: ${dir}${NC}"
        cp -r "${extract_dir}/${dir}/"* "${CONTAINER_ROOT}/${dir}/" 2>/dev/null || true
        find "${CONTAINER_ROOT}/${dir}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
      fi
      updated_files=$((updated_files + 1))
    fi
  done
  
  # Update allowed files
  for file in "${allowed_files[@]}"; do
    if [[ -f "${extract_dir}/${file}" ]]; then
      echo -e "${CYAN}[AutoUpdate] Updating file: ${file}${NC}"
      cp "${extract_dir}/${file}" "${CONTAINER_ROOT}/${file}"
      if [[ "$file" == "start-modules.sh" ]]; then
        chmod +x "${CONTAINER_ROOT}/${file}"
      fi
      updated_files=$((updated_files + 1))
    fi
  done
  
  # Clean up temporary files
  rm -rf "$extract_dir"
  
  if [[ $updated_files -gt 0 ]]; then
    echo -e "${GREEN}[AutoUpdate] Successfully updated ${updated_files} components${NC}"
    
    # Update version file
    update_version_file "$to_version"
    
    # Show self-update notice if applicable
    if [[ "$self_update_required" == "true" ]]; then
      echo -e " "
      echo -e "${BOLD_BLUE}[AutoUpdate] 🔄  IMPORTANT NOTICE:${NC}"
      echo -e "${YELLOW}[AutoUpdate] The auto-update module itself has been updated${NC}"
      echo -e "${YELLOW}[AutoUpdate] Changes will take effect on next server restart${NC}"
      echo -e "${CYAN}[AutoUpdate] Staged location: /home/container/.autoupdate_staged${NC}"
    fi
    
    return 0
  else
    echo -e "${YELLOW}[AutoUpdate] No applicable updates found${NC}"
    return 1
  fi
}

# Main update logic
main() {
  local current_version
  local latest_version
  
  # Get current version
  current_version=$(get_current_version)
  echo -e "${WHITE}[AutoUpdate] Current version: ${current_version}${NC}"
  
  echo -e "${CYAN}[AutoUpdate] Source: ${EGG_REPO} @ ${EGG_BRANCH}${NC}"

  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}[AutoUpdate] No HTTP client available (need wget or curl)${NC}"
    echo -e "${YELLOW}[AutoUpdate] Skipping update check${NC}"
    return 0
  fi

  echo -e "${CYAN}[AutoUpdate] Testing connectivity to GitHub…${NC}"
  if http_download "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}" "${TEMP_DIR}/github_repo.json"; then
    echo -e "${GREEN}[AutoUpdate] GitHub API connectivity OK${NC}"
    rm -f "${TEMP_DIR}/github_repo.json"
  else
    echo -e "${YELLOW}[AutoUpdate] GitHub API check failed, will still try commit lookup…${NC}"
  fi

  if ! latest_version=$(get_latest_version); then
    echo -e "${YELLOW}[AutoUpdate] Could not fetch latest commit from GitHub${NC}"
    echo -e "${CYAN}[AutoUpdate] Check EGG_REPO / EGG_BRANCH and outbound HTTPS access${NC}"
    echo -e "${YELLOW}[AutoUpdate] Skipping update check${NC}"
    return 0
  fi
  
  if [[ -z "$latest_version" ]]; then
    echo -e "${YELLOW}[AutoUpdate] Could not determine latest version, skipping update${NC}"
    return 0
  fi
  
  echo -e "${WHITE}[AutoUpdate] Latest version: ${latest_version}${NC}"
  
  # If current version is unknown, just save the latest version and continue
  if [[ "$current_version" == "unknown" ]]; then
    echo -e "${CYAN}[AutoUpdate] No version information found, saving current latest version${NC}"
    update_version_file "$latest_version"
    echo -e "${GREEN}[AutoUpdate] ✓ Version tracking initialized with ${latest_version}${NC}"
    return 0
  fi
  
  if ! update_is_available "$current_version" "$latest_version"; then
    echo -e "${GREEN}[AutoUpdate] ✓ You are running the latest commit (${current_version})${NC}"
    return 0
  fi

  echo -e "${YELLOW}[AutoUpdate] ⚠ Update available: ${current_version} → ${latest_version}${NC}"

  if enabled "$AUTOUPDATE_FORCE"; then
    header "Applying Update"

    if apply_update "$current_version" "$latest_version"; then
      echo -e "${GREEN}[AutoUpdate] ✓ Update completed successfully${NC}"
      echo -e "${CYAN}[AutoUpdate] Server will continue with commit ${latest_version}${NC}"
    else
      echo -e "${YELLOW}[AutoUpdate] ⚠ Update failed, continuing with current version${NC}"
    fi
  else
    echo -e "${CYAN}[AutoUpdate] Auto-update is enabled but force apply is disabled${NC}"
    echo -e "${CYAN}[AutoUpdate] Set AUTOUPDATE_FORCE=1 to pull updates from GitHub on startup${NC}"
  fi
}

# Run main update logic - with proper error handling
main || echo -e "${YELLOW}[AutoUpdate] Update check completed${NC}"

# Clean up temp directory
rm -rf "$TEMP_DIR" 2>/dev/null || true
