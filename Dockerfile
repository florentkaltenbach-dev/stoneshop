FROM dunglas/frankenphp:latest-php8.3-bookworm

# PHP extensions for WordPress + WooCommerce
RUN install-php-extensions \
    mysqli \
    pdo_mysql \
    gd \
    intl \
    zip \
    bcmath \
    exif \
    imagick \
    opcache \
    redis

# Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# WP-CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# Set working directory
WORKDIR /app

# Install Bedrock dependencies first (better layer caching)
COPY composer.json composer.lock* ./
RUN composer install --no-dev --optimize-autoloader --no-scripts

# Copy application code
COPY config/ config/
COPY web/ web/

# Ensure writable runtime dirs exist; chown the entire web tree so www-data
# can write WP core, plugins, and themes (plugins are now in the image, not
# in a named volume — see DECISIONS.md 2026-04-25).
RUN mkdir -p /app/web/app/uploads /app/web/app/wflogs \
             /app/web/app/upgrade /app/web/app/upgrade-temp-backup \
             /app/web/app/languages \
    && chown -R www-data:www-data /data/caddy /config/caddy /app/web \
    && setcap -r /usr/local/bin/frankenphp

# Document root for Caddy
ENV SERVER_ROOT=/app/web

USER www-data
