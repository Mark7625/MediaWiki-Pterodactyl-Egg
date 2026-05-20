#!/bin/bash

# [SETUP] Install necessary packages, including git
echo -e "[SETUP] Install packages"
apt-get update -qq > /dev/null 2>&1 && apt-get install -qq > /dev/null 2>&1 -y git wget perl perl-doc fcgiwrap

EGG_REPO="https://github.com/Mark7625/MediaWiki-Pterodactyl-Egg"

# Change to server directory
cd /mnt/server

# [SETUP] Create necessary folders
echo -e "[SETUP] Create folders"
mkdir -p logs tmp www cache mysql www/images php/conf.d

# Clone the egg repository into a temporary directory
echo "[Git] Cloning egg repository '${EGG_REPO}' into temporary directory."
git clone "${EGG_REPO}" /mnt/server/gtemp > /dev/null 2>&1 && echo "[Git] Repository cloned successfully." || { echo "[Git] Error: Egg repository clone failed."; exit 21; }

# Add VERSION file from latest commit
git -C /mnt/server/gtemp rev-parse --short HEAD > /mnt/server/VERSION 2>/dev/null || echo "unknown" > /mnt/server/VERSION

# Copy the www folder and files from the temporary repository to the target directory
echo "[Git] Copying folder and files from default repository."
cp -r /mnt/server/gtemp/nginx /mnt/server || { echo "[Git] Error: Copying 'nginx' folder failed."; exit 22; }
cp -r /mnt/server/gtemp/php /mnt/server || { echo "[Git] Error: Copying 'php' folder failed."; exit 22; }
cp -r /mnt/server/gtemp/modules /mnt/server || { echo "[Git] Error: Copying 'modules' folder failed."; exit 22; }
cp /mnt/server/gtemp/start-modules.sh /mnt/server || { echo "[Git] Error: Copying 'start-modules.sh' file failed."; exit 22; }
cp /mnt/server/gtemp/LICENSE /mnt/server || { echo "[Git] Error: Copying 'LICENSE' file failed."; exit 22; }
chmod +x /mnt/server/start-modules.sh
find /mnt/server/modules -type f -name "*.sh" -exec chmod +x {} \;

if [[ -f /mnt/server/gtemp/scripts/bundle-mariadb.sh ]]; then
    echo "[SETUP] Bundling MariaDB (same-server database)"
    bash /mnt/server/gtemp/scripts/bundle-mariadb.sh /mnt/server/mariadb-bundle || exit 23
    if [[ ! -x /mnt/server/mariadb-bundle/sbin/mariadbd \
      && ! -x /mnt/server/mariadb-bundle/bin/mariadbd \
      && ! -x /mnt/server/mariadb-bundle/sbin/mysqld ]]; then
        echo "[SETUP] Error: MariaDB bundle incomplete (mariadbd missing)."; exit 23
    fi
    if [[ ! -x /mnt/server/mariadb-bundle/bin/mariadb-install-db ]]; then
        echo "[SETUP] Error: MariaDB bundle incomplete (mariadb-install-db missing)."; exit 23
    fi
    echo "[SETUP] MariaDB bundle OK"
else
    echo "[SETUP] Error: bundle-mariadb.sh missing."; exit 23
fi

# Remove the temporary cloned repository
rm -rf /mnt/server/gtemp

# Install MediaWiki 1.45.3 into www on first run (empty directory)
MEDIAWIKI_VERSION="1.45.3"
MEDIAWIKI_URL="https://releases.wikimedia.org/mediawiki/1.45/mediawiki-${MEDIAWIKI_VERSION}.tar.gz"

if [ ! -d /mnt/server/www ]; then
    mkdir -p /mnt/server/www
fi

if [ -z "$(ls -A /mnt/server/www 2>/dev/null)" ]; then
    echo "[SETUP] Installing MediaWiki ${MEDIAWIKI_VERSION}"
    cd /mnt/server/www || { echo "[SETUP] Error: Could not access /mnt/server/www directory."; exit 1; }
    wget -q "${MEDIAWIKI_URL}" -O mediawiki.tar.gz || { echo "[SETUP] Error: Downloading MediaWiki failed."; exit 16; }
    tar xzf mediawiki.tar.gz --strip-components=1 >/dev/null 2>&1 || { echo "[SETUP] Error: Extracting MediaWiki failed."; exit 17; }
    rm -f mediawiki.tar.gz
    echo "[SETUP] MediaWiki ${MEDIAWIKI_VERSION} installed - visit http://ip:port/ to run the web installer"
else
    echo "[SETUP] www directory is not empty; skipping MediaWiki download."
fi

echo -e "[DONE] Everything has been installed successfully"
echo -e "[INFO] You can now start the nginx web server"
