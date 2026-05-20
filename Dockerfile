FROM debian:bookworm-slim

LABEL author="Mark7625" maintainer="https://github.com/Mark7625/MediaWiki-Pterodactyl-Egg"

ARG PHP_VERSION=8.4

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
        git \
        apt-transport-https \
        lsb-release \
        ca-certificates \
        wget \
        curl \
        gnupg2 \
        debian-archive-keyring \
        unzip \
        certbot \
        python3 \
        python3-pygments \
        lua5.1 \
        liblua5.1-0 \
        libthai0 \
        libthai-dev \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/debian bookworm nginx" > /etc/apt/sources.list.d/nginx.list \
    && printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx \
    && apt-get update \
    && apt-get install -y nginx \
    && ARCH=$(uname -m) \
    && if [ "$ARCH" = "x86_64" ]; then \
        wget -O /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb; \
    elif [ "$ARCH" = "aarch64" ]; then \
        wget -O /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi \
    && dpkg -i /tmp/cloudflared.deb \
    && rm /tmp/cloudflared.deb \
    && wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg \
    && echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list \
    # Retry apt-get update with exponential backoff for Sury repository
    && { \
        success=0; \
        for i in 1 2 3 4 5; do \
            if apt-get update; then \
                success=1; \
                break; \
            else \
                echo "apt-get update failed (attempt $i/5), retrying in $((i * 10)) seconds..."; \
                sleep $((i * 10)); \
            fi; \
        done; \
        if [ "$success" -ne 1 ]; then \
            echo "ERROR: apt-get update failed after 5 attempts. Sury repository may be unavailable."; \
            exit 1; \
        fi; \
    } \
    # Verify Sury repository is accessible
    && apt-cache show php${PHP_VERSION}-fpm >/dev/null 2>&1 || { \
        echo "ERROR: php${PHP_VERSION}-fpm package not found. Sury repository may be unavailable."; \
        exit 1; \
    } \
    && apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        php${PHP_VERSION} \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-apcu \
        php${PHP_VERSION}-opcache \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-pdo \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-xmlreader \
        php${PHP_VERSION}-xmlwriter \
        php${PHP_VERSION}-simplexml \
        php${PHP_VERSION}-ctype \
        php${PHP_VERSION}-iconv \
        php${PHP_VERSION}-fileinfo \
        php${PHP_VERSION}-dom \
        php${PHP_VERSION}-calendar \
        php${PHP_VERSION}-sodium \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-imagick \
        php${PHP_VERSION}-exif \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-phar \
        php${PHP_VERSION}-tokenizer \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-readline \
    # Optional extras (Scribunto / caching / etc.)
    && apt-get install -y --no-install-recommends php${PHP_VERSION}-redis || true \
    && apt-get install -y --no-install-recommends php${PHP_VERSION}-memcached || true \
    && apt-get install -y --no-install-recommends php${PHP_VERSION}-memcache || true \
    && apt-get install -y --no-install-recommends php${PHP_VERSION}-igbinary || true \
    # Final verification: ensure PHP-FPM was installed correctly
    && command -v php-fpm${PHP_VERSION} >/dev/null 2>&1 || { \
        echo "ERROR: php-fpm${PHP_VERSION} binary not found after installation!"; \
        echo "This indicates the PHP installation failed. Aborting build."; \
        exit 1; \
    } \
    && echo "PHP ${PHP_VERSION} installed successfully: $(php${PHP_VERSION} -v | head -1)" \
    && wget -q -O /tmp/composer.phar https://getcomposer.org/download/latest-stable/composer.phar \
    && SHA256=$(wget -q -O - https://getcomposer.org/download/latest-stable/composer.phar.sha256) \
    && echo "$SHA256 /tmp/composer.phar" | sha256sum -c - \
    && mv /tmp/composer.phar /usr/local/bin/composer \
    && chmod +x /usr/local/bin/composer \
    && rm -rf /var/lib/apt/lists/*

# ICU 76.1, LuaSandbox 4.1.3, Wikidiff2 — https://www.mediawiki.org/wiki/LuaSandbox https://www.mediawiki.org/wiki/Wikidiff2
COPY scripts/docker-build-icu-lua-wikidiff.sh /tmp/docker-build-icu-lua-wikidiff.sh
RUN chmod +x /tmp/docker-build-icu-lua-wikidiff.sh \
    && PHP_VERSION="${PHP_VERSION}" /tmp/docker-build-icu-lua-wikidiff.sh \
    && rm -f /tmp/docker-build-icu-lua-wikidiff.sh \
    && apt-get purge -y build-essential php-pear "php${PHP_VERSION}-dev" \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# ionCube Loader (optional - may not be available for newest PHP versions)
RUN ARCH=$(uname -m); \
    if [ "$ARCH" = "x86_64" ]; then \
        IONCUBE_ARCH="x86-64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        IONCUBE_ARCH="aarch64"; \
    else \
        echo "ionCube: Unsupported architecture $ARCH - skipping"; \
        exit 0; \
    fi; \
    cd /tmp; \
    wget -q -O ioncube.tar.gz "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${IONCUBE_ARCH}.tar.gz" || { echo "ionCube download failed - skipping"; exit 0; }; \
    tar xzf ioncube.tar.gz; \
    if [ -f "ioncube/ioncube_loader_lin_${PHP_VERSION}.so" ]; then \
        PHP_EXT_DIR=$(find /usr/lib/php -maxdepth 1 -type d -name "20*" | head -1); \
        if [ -n "$PHP_EXT_DIR" ]; then \
            cp "ioncube/ioncube_loader_lin_${PHP_VERSION}.so" "$PHP_EXT_DIR/"; \
            echo "zend_extension=${PHP_EXT_DIR}/ioncube_loader_lin_${PHP_VERSION}.so" > /etc/php/${PHP_VERSION}/cli/conf.d/00-ioncube.ini; \
            echo "zend_extension=${PHP_EXT_DIR}/ioncube_loader_lin_${PHP_VERSION}.so" > /etc/php/${PHP_VERSION}/fpm/conf.d/00-ioncube.ini; \
            echo "ionCube Loader installed for PHP ${PHP_VERSION}"; \
        else \
            echo "PHP extension directory not found - skipping ionCube"; \
        fi; \
    else \
        echo "ionCube Loader not available for PHP ${PHP_VERSION} - skipping"; \
    fi; \
    rm -rf /tmp/ioncube*

# ImageMagick security policy to allow PDF operations
RUN POLICY_FILE=$(find /etc -name "policy.xml" -path "*/ImageMagick*" 2>/dev/null | head -1); \
    if [ -n "$POLICY_FILE" ]; then \
        echo "Updating ImageMagick policy: $POLICY_FILE"; \
        sed -i 's/<policy domain="coder" rights="none" pattern="PDF" \/>/<policy domain="coder" rights="read|write" pattern="PDF" \/>/g' "$POLICY_FILE"; \
        sed -i 's/<policy domain="coder" rights="none" pattern="PS" \/>/<policy domain="coder" rights="read|write" pattern="PS" \/>/g' "$POLICY_FILE"; \
        sed -i 's/<policy domain="coder" rights="none" pattern="EPS" \/>/<policy domain="coder" rights="read|write" pattern="EPS" \/>/g' "$POLICY_FILE"; \
        sed -i 's/<policy domain="coder" rights="none" pattern="XPS" \/>/<policy domain="coder" rights="read|write" pattern="XPS" \/>/g' "$POLICY_FILE"; \
        echo "ImageMagick PDF/PS policy updated successfully"; \
    else \
        echo "ImageMagick policy.xml not found - skipping"; \
    fi

# Create user and set environment variables
RUN useradd -m -d /home/container/ -s /bin/bash container \
    && echo "USER=container" >> /etc/environment \
    && echo "HOME=/home/container" >> /etc/environment \
    && mkdir -p /home/container/cache /home/container/tmp /home/container/logs /home/container/www \
    && chown -R container:container /home/container

WORKDIR /home/container

STOPSIGNAL SIGINT

# Copy entrypoint script
COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh


CMD ["/entrypoint.sh"]
