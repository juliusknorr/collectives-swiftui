#!/bin/sh
set -eu

cd /var/www/html
occ() { su -s /bin/sh www-data -c 'php /var/www/html/occ "$@"' -- occ "$@"; }

# These versions come from the pinned server image; install Collectives separately.
occ app:enable circles text

collectives_version=4.7.1
collectives_sha256=6aef84674527393edbfc2915d58014e4ef72bfb27f3ca606b7c1faf985ae0879
if [ ! -d custom_apps/collectives ]; then
    archive=$(mktemp /tmp/collectives-XXXXXX.tar.gz)
    trap 'rm -f "$archive"' EXIT HUP INT TERM
    curl --fail --location --retry 3 \
        "https://github.com/nextcloud/collectives/releases/download/v${collectives_version}/collectives-${collectives_version}.tar.gz" \
        --output "$archive"
    printf '%s  %s\n' "$collectives_sha256" "$archive" | sha256sum --check --status
    tar -xzf "$archive" -C custom_apps
    chown -R www-data:www-data custom_apps/collectives
fi
installed_version=$(php -r 'echo simplexml_load_file("custom_apps/collectives/appinfo/info.xml")->version;')
if [ "$installed_version" != "$collectives_version" ]; then
    echo "Expected Collectives $collectives_version, found $installed_version. Use the documented reset procedure." >&2
    exit 1
fi
occ app:enable collectives
occ background:ajax
