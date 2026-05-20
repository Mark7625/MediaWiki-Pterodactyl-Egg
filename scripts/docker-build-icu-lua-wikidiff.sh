#!/bin/bash
# Build ICU 76.1, rebuild PHP intl against it, install LuaSandbox + Wikidiff2 for MediaWiki.
# Run during Docker image build. Requires: PHP_VERSION, build-essential, php dev packages.
set -euo pipefail

PHP_VERSION="${PHP_VERSION:-8.4}"
PHP_API="$(php${PHP_VERSION} -i | awk -F'=> ' '/^PHP API/{print $2; exit}')"
export PHP_API

apt-get install -y --no-install-recommends \
  build-essential pkg-config wget ca-certificates \
  "php${PHP_VERSION}-dev" php-pear \
  liblua5.1-0-dev libthai-dev \
  >/dev/null

ICU_TGZ="/tmp/icu4c-76_1-src.tgz"
if [[ ! -f "$ICU_TGZ" ]]; then
  wget -q -O "$ICU_TGZ" \
    "https://github.com/unicode-org/icu/releases/download/release-76-1/icu4c-76_1-src.tgz"
fi
rm -rf /tmp/icu-src
mkdir -p /tmp/icu-src
tar -xzf "$ICU_TGZ" -C /tmp/icu-src --strip-components=1
cd /tmp/icu-src/source
./configure --prefix=/usr/local --enable-release --disable-debug --enable-static=no
make -j"$(nproc)"
make install
ldconfig

# Rebuild intl against ICU 76.1 (Sury PHP is linked to older libicu otherwise).
PHP_SRC="/tmp/php-src-intl"
rm -rf "$PHP_SRC"
mkdir -p "$PHP_SRC"
PHP_TAR="/tmp/php-${PHP_VERSION}-intl.tar.xz"
PHP_VER="$(php${PHP_VERSION} -r 'echo PHP_VERSION;')"
if [[ ! -f "$PHP_TAR" ]]; then
  wget -q -O "$PHP_TAR" "https://www.php.net/distributions/php-${PHP_VER}.tar.xz"
fi
tar -xJf "$PHP_TAR" -C "$PHP_SRC" --strip-components=1
cd "${PHP_SRC}/ext/intl"
phpize${PHP_VERSION}
./configure --with-php-config="/usr/bin/php-config${PHP_VERSION}" --with-icu-dir=/usr/local
make -j"$(nproc)"
make install
echo "intl rebuilt against ICU $(/usr/local/bin/icu-config --version 2>/dev/null || echo 76.1)"

# LuaSandbox 4.1.3 via PECL ([LuaSandbox](https://www.mediawiki.org/wiki/LuaSandbox))
yes '' | pecl install luasandbox-4.1.3
echo "extension=luasandbox.so" >"/etc/php/${PHP_VERSION}/mods-available/luasandbox.ini"
phpenmod -v "${PHP_VERSION}" luasandbox 2>/dev/null || true

# Wikidiff2 from Wikimedia releases ([Wikidiff2](https://www.mediawiki.org/wiki/Wikidiff2))
WIKIDIFF2_VER="1.14.1"
WIKIDIFF2_TGZ="/tmp/wikidiff2-${WIKIDIFF2_VER}.tar.gz"
if [[ ! -f "$WIKIDIFF2_TGZ" ]]; then
  wget -q -O "$WIKIDIFF2_TGZ" \
    "https://releases.wikimedia.org/wikidiff2/wikidiff2-${WIKIDIFF2_VER}.tar.gz"
fi
rm -rf /tmp/wikidiff2-src
mkdir -p /tmp/wikidiff2-src
tar -xzf "$WIKIDIFF2_TGZ" -C /tmp/wikidiff2-src --strip-components=1
cd /tmp/wikidiff2-src
phpize${PHP_VERSION}
./configure --with-php-config="/usr/bin/php-config${PHP_VERSION}" --with-icu-dir=/usr/local
make -j"$(nproc)"
make install
echo "extension=wikidiff2.so" >"/etc/php/${PHP_VERSION}/mods-available/wikidiff2-built.ini"
phpenmod -v "${PHP_VERSION}" wikidiff2-built 2>/dev/null || true

php${PHP_VERSION} -m | grep -iE '^(intl|luasandbox|wikidiff2)$' || {
  echo "ERROR: intl, luasandbox, or wikidiff2 not loaded after build"
  exit 1
}

rm -rf /tmp/icu-src /tmp/wikidiff2-src "$PHP_SRC" "$ICU_TGZ" "$WIKIDIFF2_TGZ" "$PHP_TAR"
