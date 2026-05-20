#!/bin/bash
# Bundle a full MariaDB basedir into the server volume (install container has apt mariadb-server).
set -uo pipefail

TARGET="${1:-/mnt/server/mariadb-bundle}"
MARKER="${TARGET}/.bundled"

if [[ -f "$MARKER" ]]; then
  echo "[Bundle] MariaDB bundle already present at ${TARGET}"
  exit 0
fi

echo "[Bundle] Installing MariaDB packages for bundling…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || { echo "[Bundle] apt-get update failed"; exit 1; }
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  mariadb-server mariadb-client apt-utils 2>/dev/null \
  || apt-get install -y -qq mariadb-server mariadb-client \
  || { echo "[Bundle] apt-get install mariadb failed"; exit 1; }

mkdir -p "${TARGET}/"{bin,sbin,lib,share,plugin}

copy_deps() {
  local bin="$1"
  [[ -f "$bin" ]] || return 0
  local lib
  while IFS= read -r lib; do
    [[ -n "$lib" && -f "$lib" ]] || continue
    cp -L "$lib" "${TARGET}/lib/$(basename "$lib")" 2>/dev/null || true
  done < <(ldd "$bin" 2>/dev/null | awk '/=> \// {print $3}')
  [[ -f /lib64/ld-linux-x86-64.so.2 ]] && \
    cp -L /lib64/ld-linux-x86-64.so.2 "${TARGET}/lib/" 2>/dev/null || true
}

copy_file() {
  local src="$1"
  local dest_dir="$2"
  [[ -f "$src" ]] || return 0
  cp -L "$src" "${dest_dir}/$(basename "$src")" 2>/dev/null || return 0
  chmod +x "${dest_dir}/$(basename "$src")" 2>/dev/null || true
  copy_deps "$src"
}

echo "[Bundle] Copying MariaDB binaries (sbin)…"
shopt -s nullglob
for src in /usr/sbin/mariadb* /usr/sbin/mysql*; do
  copy_file "$src" "${TARGET}/sbin"
  echo "[Bundle]   sbin/$(basename "$src")"
done

echo "[Bundle] Copying MariaDB binaries (bin)…"
for src in /usr/bin/mariadb* /usr/bin/mysql* /usr/bin/my_* /usr/bin/resolveip /usr/bin/perror /usr/bin/replace; do
  copy_file "$src" "${TARGET}/bin"
  echo "[Bundle]   bin/$(basename "$src")"
done
shopt -u nullglob

echo "[Bundle] Copying share files…"
for share_dir in /usr/share/mariadb /usr/share/mysql /usr/share/mecab; do
  if [[ -d "$share_dir" ]]; then
    cp -a "$share_dir" "${TARGET}/share/$(basename "$share_dir")"
    echo "[Bundle]   share/$(basename "$share_dir")/"
  fi
done

# Debian Bookworm ships /usr/share/mysql (not always /usr/share/mariadb). install-db needs both names.
if [[ -d "${TARGET}/share/mariadb" && ! -e "${TARGET}/share/mysql" ]]; then
  ln -sfn mariadb "${TARGET}/share/mysql"
elif [[ -d "${TARGET}/share/mysql" && ! -e "${TARGET}/share/mariadb" ]]; then
  ln -sfn mysql "${TARGET}/share/mariadb"
fi

# install-db expects $basedir/share/mysql/extra/my_print_defaults
MYSQL_SHARE=""
if [[ -d "${TARGET}/share/mysql" ]]; then
  MYSQL_SHARE="${TARGET}/share/mysql"
elif [[ -d "${TARGET}/share/mariadb" ]]; then
  MYSQL_SHARE="${TARGET}/share/mariadb"
fi
[[ -n "$MYSQL_SHARE" ]] || { echo "[Bundle] Error: no share/mysql or share/mariadb"; exit 1; }

EXTRA_DIR="${MYSQL_SHARE}/extra"
mkdir -p "$EXTRA_DIR"
for src_extra in /usr/share/mysql/extra /usr/share/mariadb/extra; do
  [[ -d "$src_extra" ]] && cp -a "${src_extra}/." "$EXTRA_DIR/" 2>/dev/null || true
done
if [[ ! -x "${EXTRA_DIR}/my_print_defaults" && -x /usr/bin/my_print_defaults ]]; then
  cp -L /usr/bin/my_print_defaults "${EXTRA_DIR}/my_print_defaults"
  chmod +x "${EXTRA_DIR}/my_print_defaults"
  echo "[Bundle]   ${EXTRA_DIR#${TARGET}/}/my_print_defaults"
fi

echo "[Bundle] Copying plugins and libraries…"
for plugin_dir in \
  /usr/lib/mysql/plugin \
  /usr/lib/x86_64-linux-gnu/mariadb19/plugin \
  /usr/lib/x86_64-linux-gnu/mariadb/plugin; do
  if [[ -d "$plugin_dir" ]]; then
    cp -a "${plugin_dir}/." "${TARGET}/plugin/" 2>/dev/null || true
    echo "[Bundle]   plugin/ ($(basename "$plugin_dir"))"
  fi
done

for lib_dir in /usr/lib/x86_64-linux-gnu/mariadb* /usr/lib/mariadb; do
  if [[ -d "$lib_dir" ]]; then
    cp -a "${lib_dir}/." "${TARGET}/lib/" 2>/dev/null || true
  fi
done

while IFS= read -r -d '' lib; do
  cp -L "$lib" "${TARGET}/lib/" 2>/dev/null || true
done < <(find /usr/lib /usr/lib/x86_64-linux-gnu -maxdepth 1 \
  \( -name 'libmariadb*' -o -name 'libmysqlclient*' -o -name 'libaio*' \
     -o -name 'libssl*' -o -name 'libcrypto*' -o -name 'libz*' -o -name 'liblz4*' \
     -o -name 'libsnappy*' -o -name 'libpcre2*' \) -type f -print0 2>/dev/null)

# install-db expects $basedir/sbin/mariadbd
if [[ ! -x "${TARGET}/sbin/mariadbd" && -x "${TARGET}/bin/mariadbd" ]]; then
  ln -sf ../bin/mariadbd "${TARGET}/sbin/mariadbd"
  echo "[Bundle]   sbin/mariadbd -> ../bin/mariadbd"
fi
if [[ ! -x "${TARGET}/sbin/mysqld" && -x "${TARGET}/sbin/mariadbd" ]]; then
  ln -sf mariadbd "${TARGET}/sbin/mysqld"
fi
[[ -x "${TARGET}/bin/mariadbd" && ! -e "${TARGET}/bin/mysqld" ]] && \
  ln -sf mariadbd "${TARGET}/bin/mysqld"

# Validate layout required by mariadb-install-db --basedir
missing=0
for required in sbin/mariadbd bin/mariadb-install-db share/mysql share/mysql/extra/my_print_defaults; do
  if [[ ! -e "${TARGET}/${required}" ]]; then
    echo "[Bundle] Error: missing ${required}"
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || exit 1

date -u +%Y-%m-%dT%H:%M:%SZ >"$MARKER" 2>/dev/null || date >"$MARKER"
echo "[Bundle] Full MariaDB basedir bundled to ${TARGET}"
