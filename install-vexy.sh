#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Avtix Game Panel — Theme Installer
#  Requires: Pterodactyl Panel 1.12.x already installed
#  Installs real DGEN/Hyper theme + nginx license intercepts
# ═══════════════════════════════════════════════════════════════

set -e

PANEL_PATH="/var/www/pterodactyl"
HYPER_UTIL_URL="https://hyper-r2.dgenx.net/hyperv1/hyper-utility"
HYPER_UTIL="/tmp/hyper-utility"
DB_NAME="panel"
DB_USER="root"
DB_PASS=""

# ─── Helpers ──────────────────────────────────────────────────
red()   { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        red "Error: Must be run as root"
        exit 1
    fi
}

check_panel() {
    if [[ ! -d "$PANEL_PATH" ]]; then
        red "Error: Pterodactyl Panel not found at $PANEL_PATH"
        red "Install Pterodactyl 1.12.x first, then re-run this script."
        exit 1
    fi
    if [[ ! -f "$PANEL_PATH/artisan" ]]; then
        red "Error: $PANEL_PATH/artisan not found. Is this a Pterodactyl installation?"
        exit 1
    fi
}

php() { php8.4 "$@" 2>/dev/null || php "$@"; }

# ─── Install hyper-utility ────────────────────────────────────
install_hyper_utility() {
    bold "[1/5] Downloading hyper-utility..."
    if [[ ! -f "$HYPER_UTIL" ]] || [[ $(stat -c%s "$HYPER_UTIL" 2>/dev/null || echo 0) -lt 1000000 ]]; then
        curl -fSL --retry 3 --progress-bar -o "$HYPER_UTIL" "$HYPER_UTIL_URL"
        chmod +x "$HYPER_UTIL"
    fi
    green "  hyper-utility ready ($(stat -c%s "$HYPER_UTIL") bytes)"
}

# ─── Run hyper-utility (installs real DGEN theme) ─────────────
run_hyper_utility() {
    bold "[2/5] Installing DGEN/Hyper theme..."
    cd /tmp
    echo "" | "$HYPER_UTIL" 2>&1 | tail -20
    green "  DGEN theme installed"
}

# ─── Apply custom branding ────────────────────────────────────
apply_branding() {
    bold "[3/5] Applying Avtix branding..."

    # Update wrapper blade title
    WRAPPER="$PANEL_PATH/resources/views/templates/wrapper.blade.php"
    if [[ -f "$WRAPPER" ]]; then
        sed -i 's/Hyper Game Panel/Avtix Game Panel/g' "$WRAPPER"
        sed -i 's/Hyper Panel/Avtix Game Panel/g' "$WRAPPER"
        sed -i 's/DGEN_HYPER/AVTIX/g' "$WRAPPER"
    fi

    # Update blade base template
    BASE="$PANEL_PATH/resources/views/templates/base.blade.php"
    if [[ -f "$BASE" ]]; then
        sed -i 's/Hyper Game Panel/Avtix Game Panel/g' "$BASE"
    fi

    green "  Branding applied"
}

# ─── Write nginx config with license intercepts ───────────────
write_nginx_config() {
    bold "[4/5] Writing nginx config with license intercepts..."

    # Find the existing nginx config file
    NGINX_CONF=""
    for path in \
        /etc/nginx/sites-available/pterodactyl.conf \
        /etc/nginx/sites-enabled/pterodactyl.conf \
        /etc/nginx/conf.d/pterodactyl.conf; do
        if [[ -f "$path" ]]; then
            NGINX_CONF="$path"
            break
        fi
    done

    if [[ -z "$NGINX_CONF" ]]; then
        red "  Error: No nginx config found for Pterodactyl"
        red "  Expected: /etc/nginx/sites-available/pterodactyl.conf"
        exit 1
    fi

    # Extract server_name and ssl settings from existing config
    SERVER_NAME=$(grep -oP 'server_name\s+\K[^;]+' "$NGINX_CONF" | head -1 | xargs)
    SSL_CERT=$(grep -oP 'ssl_certificate\s+\K[^;]+' "$NGINX_CONF" | head -1 | xargs)
    SSL_KEY=$(grep -oP 'ssl_certificate_key\s+\K[^;]+' "$NGINX_CONF" | head -1 | xargs)
    HAS_SSL=false
    [[ -n "$SSL_CERT" ]] && HAS_SSL=true

    if [[ -z "$SERVER_NAME" ]]; then
        SERVER_NAME=$(grep APP_URL "$PANEL_PATH/.env" 2>/dev/null | cut -d= -f2 | sed 's|https://||;s|http://||' | sed 's|/.*||')
    fi

    if [[ -z "$SERVER_NAME" ]]; then
        red "  Error: Could not detect server_name from nginx config or .env"
        exit 1
    fi

    green "  Server: $SERVER_NAME"
    green "  SSL: $HAS_SSL"

    # Backup existing config
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"

    # Write new config
    cat > "$NGINX_CONF" <<NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    root /var/www/pterodactyl/public;
    index index.html index.php;
    charset utf-8;
    client_max_body_size 100m;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    # ═══ LICENSE INTERCEPTS (bypass DGEN checks) ═══
    location = /api/public/license/verify {
        default_type application/json;
        return 200 '{"valid":true,"verified_at":"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)","reason":null,"community":false,"edition":"ultimate","license":{"ultimate_features":true,"premium_features":true,"basic_features":true,"minecraft_features":true,"fivem_features":true,"essentials_features":true,"special_features":true,"private_features":true,"ark_features":true,"hytale_features":true}}';
    }
    location = /api/public/license/status {
        default_type application/json;
        return 200 '{"configured":true,"domain":"$SERVER_NAME"}';
    }
    location = /api/public/license/clear-cache {
        default_type application/json;
        return 200 '{"success":true}';
    }
    location = /api/public/license/clear-all-cache {
        default_type application/json;
        return 200 '{"success":true}';
    }

    # ═══ DISCORD/DGEN VERIFICATION INTERCEPTS ═══
    location = /api/client/discord-verification {
        default_type application/json;
        return 200 '{"requires_dgen":true,"dgen_connected":true,"requires_discord":false,"discord_connected":true,"in_discord_server":true,"invite_link":"https://discord.gg/avtix"}';
    }
    location = /api/client/discord-verification/account {
        default_type application/json;
        return 200 '{"requires_dgen":true,"dgen_connected":true,"requires_discord":false,"discord_connected":true,"in_discord_server":true,"invite_link":"https://discord.gg/avtix"}';
    }
    location = /api/client/discord-verification/account/refresh {
        default_type application/json;
        return 200 '{"requires_dgen":true,"dgen_connected":true,"requires_discord":false,"discord_connected":true,"in_discord_server":true,"invite_link":"https://discord.gg/avtix"}';
    }
    location = /api/client/discord-verification/refresh {
        default_type application/json;
        return 200 '{"requires_dgen":true,"dgen_connected":true,"requires_discord":false,"discord_connected":true,"in_discord_server":true,"invite_link":"https://discord.gg/avtix"}';
    }

    # ═══ SSO/INFO INTERCEPT (prevents DGEN popup) ═══
    location = /api/client/theme/hyperv2/sso/info {
        default_type application/json;
        return 200 '{"license":{"tier":"ultimate","status":"valid","community":false,"edition":"ultimate","features":{"ultimate_features":true,"premium_features":true,"basic_features":true,"minecraft_features":true,"fivem_features":true,"essentials_features":true,"special_features":true,"private_features":true,"ark_features":true,"hytale_features":true}},"sso_connected":true,"sso":true,"dgen_connected":true,"discord_connected":true,"panel_url":"http://$SERVER_NAME","branding":{"site_name":"Avtix Game Panel"}}';
    }

    # ═══ ADDON SETTINGS INTERCEPTS (SPA calls /api/client/addons when logged in) ═══
    location = /api/client/addons {
        default_type application/json;
        return 200 '{"addons":{"UserRegister":{"enabled":true},"database-manager":{"enabled":true},"Notifications":{"enabled":true},"SubdomainManager":{"enabled":true},"staff-request":{"enabled":true},"server-importer":{"enabled":true},"custom-mod-manager":{"enabled":true},"github-source-control":{"enabled":true},"server-splitter":{"enabled":true},"server-type-changer":{"enabled":true},"startup-presets":{"enabled":true},"schedule-presets":{"enabled":true},"AccountInfoUpdate":{"enabled":true},"CloudflareTurnstile":{"enabled":false},"upload-from-url":{"enabled":true},"console-log-upload":{"enabled":true},"command-history":{"enabled":true}},"updated_at":null,"app_url":"http://$SERVER_NAME"}';
    }
    location = /api/client/theme/hyperv2/addon-settings {
        default_type application/json;
        return 200 '{"addons":{"UserRegister":{"enabled":true},"database-manager":{"enabled":true},"Notifications":{"enabled":true},"SubdomainManager":{"enabled":true},"staff-request":{"enabled":true},"server-importer":{"enabled":true},"custom-mod-manager":{"enabled":true},"github-source-control":{"enabled":true},"server-splitter":{"enabled":true},"server-type-changer":{"enabled":true},"startup-presets":{"enabled":true},"schedule-presets":{"enabled":true},"AccountInfoUpdate":{"enabled":true},"CloudflareTurnstile":{"enabled":false},"upload-from-url":{"enabled":true},"console-log-upload":{"enabled":true},"command-history":{"enabled":true}},"updated_at":null,"app_url":"http://$SERVER_NAME"}';
    }

    # ═══ THEME INFO INTERCEPTS ═══
    location = /api/client/theme/hyperv2 {
        default_type application/json;
        return 200 '{"theme":{"name":"hyperv2","version":"2.0.0","branding":{"site_name":"Avtix Game Panel","accent_color":"#6366f1"}},"site":{"name":"Avtix Game Panel","description":"Premium Game Server Hosting"},"license":{"tier":"ultimate","status":"valid","community":false},"features":{"all":true}}';
    }
    location = /api/client/theme/hyperv2/info {
        default_type application/json;
        return 200 '{"theme":{"name":"hyperv2","version":"2.0.0","branding":{"site_name":"Avtix Game Panel"}},"features":{"all":true},"license":{"tier":"ultimate","status":"valid","community":false}}';
    }
    location = /api/client/theme/hyperv2/version {
        default_type application/json;
        return 200 '{"version":"2.0.0","latest":"2.0.0","update_available":false}';
    }

    # ═══ STAFF-REQUEST INTERCEPT ═══
    location = /api/client/staff-request {
        default_type application/json;
        return 200 '{"object":"list","data":[],"meta":{"pagination":{"total":0,"count":0,"per_page":50,"current_page":1,"total_pages":1,"links":{}}}}';
    }

    # ═══ MAIN ROUTING ═══
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    access_log off;
    error_log /var/log/nginx/pterodactyl.app-error.log error;

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "http";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_param HTTPS off;
    }
    location ~ /\.(?!well-known).* { deny all; }
}
NGINXEOF

    # Add SSL server block if SSL was configured
    if $HAS_SSL; then
        cat >> "$NGINX_CONF" <<SSLEOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $SERVER_NAME;
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    return 301 http://\$host\$request_uri;
}
SSLEOF
    fi

    # Test and reload
    nginx -t 2>&1
    systemctl reload nginx 2>/dev/null || nginx -s reload
    green "  Nginx config written and reloaded"
}

# ─── Configure database ───────────────────────────────────────
configure_database() {
    bold "[5/5] Configuring database..."

    # Enable registration
    php8.4 -r "
    try {
        \$pdo = new PDO('mysql:host=127.0.0.1;dbname=$DB_NAME', '$DB_USER', '$DB_PASS');
        \$pdo->exec(\"INSERT IGNORE INTO settings (\`key\`, \`value\`) VALUES ('settings::auth:registration', '1')\");
        \$pdo->exec(\"INSERT IGNORE INTO settings (\`key\`, \`value\`) VALUES ('settings::auth:2fa_required', '0')\");
        \$pdo->exec(\"INSERT IGNORE INTO settings (\`key\`, \`value\`) VALUES ('settings::app:admin_theme', 'hyper')\");

        // Enable all DGEN addons
        \$addons = json_encode([
            'UserRegister' => ['enabled' => true],
            'theme-settings' => ['enabled' => true],
            'SiteAlerts' => ['enabled' => true, 'alerts' => []],
            'Notifications' => ['enabled' => true, 'notifications' => ['serverEnabled' => false, 'soundsEnabled' => false]],
        ]);
        \$pdo->exec(\"INSERT IGNORE INTO settings (\`key\`, \`value\`) VALUES ('settings::app:addons:hyperv2', '\" . addslashes(\$addons) . \"')\");

        // Theme settings
        \$theme = json_encode(['site_name' => 'Avtix Game Panel', 'accent_color' => '#6366f1']);
        \$pdo->exec(\"INSERT IGNORE INTO settings (\`key\`, \`value\`) VALUES ('settings::app:theme:hyperv2', '\" . addslashes(\$theme) . \"')\");

        echo \"  Database configured\n\";
    } catch (PDOException \$e) {
        echo \"  Warning: \" . \$e->getMessage() . \"\n\";
    }
    "

    # Remove recaptcha middleware from auth routes
    AUTH_ROUTES="$PANEL_PATH/routes/auth.php"
    if [[ -f "$AUTH_ROUTES" ]]; then
        sed -i "s/->middleware('recaptcha')//g" "$AUTH_ROUTES"
        green "  Recaptcha middleware removed"
    fi

    # Fix permissions
    chown -R www-data:www-data "$PANEL_PATH"
    green "  Permissions set"
}

# ═══════════════════════════════════════════════════════════════
#  INSTALL MENU
# ═══════════════════════════════════════════════════════════════

do_install() {
    echo ""
    bold "═══════════════════════════════════════"
    bold "  Avtix Game Panel — Full Install"
    bold "═══════════════════════════════════════"
    echo ""
    check_root
    check_panel

    install_hyper_utility
    run_hyper_utility
    apply_branding
    write_nginx_config
    configure_database

    echo ""
    bold "═══════════════════════════════════════"
    green "  Install Complete!"
    bold "═══════════════════════════════════════"
    echo ""
    echo "  Panel:  $(grep APP_URL "$PANEL_PATH/.env" 2>/dev/null | cut -d= -f2)"
    echo "  Admin:  admin@admin.com / admin"
    echo "  Theme:  Avtix Game Panel (DGEN/Hyper)"
    echo ""
}

do_repair() {
    echo ""
    bold "═══════════════════════════════════════"
    bold "  Avtix Game Panel — Repair Theme"
    bold "═══════════════════════════════════════"
    echo ""
    check_root
    check_panel

    read -p "Continue with repair? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi

    install_hyper_utility
    run_hyper_utility
    apply_branding
    write_nginx_config
    configure_database

    echo ""
    bold "═══════════════════════════════════════"
    green "  Repair Complete!"
    bold "═══════════════════════════════════════"
}

do_uninstall() {
    echo ""
    bold "═══════════════════════════════════════"
    bold "  Avtix Game Panel — Uninstall"
    bold "═══════════════════════════════════════"
    echo ""
    check_root
    check_panel

    read -p "Type 'UNINSTALL' to confirm: " CONFIRM
    [[ "$CONFIRM" != "UNINSTALL" ]] && echo "Aborted." && exit 0

    # Restore vanilla Pterodactyl
    echo "Restoring vanilla Pterodactyl..."
    TMP=$(mktemp -d)
    git clone https://github.com/pterodactyl/panel.git "$TMP/vanilla" --depth 1

    rm -rf "$PANEL_PATH/public/assets" "$PANEL_PATH/public/DGEN" 2>/dev/null || true
    cp -rf "$TMP/vanilla/public/assets" "$PANEL_PATH/public/"
    rm -rf "$PANEL_PATH/resources/views" 2>/dev/null || true
    cp -rf "$TMP/vanilla/resources/views" "$PANEL_PATH/resources/"
    rm -f "$PANEL_PATH/routes/"*.php 2>/dev/null || true
    cp -f "$TMP/vanilla/routes/"*.php "$PANEL_PATH/routes/"

    # Restore vanilla nginx config (remove intercepts)
    NGINX_CONF=""
    for path in /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf; do
        [[ -f "$path" ]] && NGINX_CONF="$path" && break
    done
    if [[ -n "$NGINX_CONF" ]]; then
        SERVER_NAME=$(grep -oP 'server_name\s+\K[^;]+' "$NGINX_CONF" | head -1 | xargs)
        cat > "$NGINX_CONF" <<vanillaNGX
server {
    listen 80;
    server_name $SERVER_NAME;
    root /var/www/pterodactyl/public;
    index index.html index.php;
    charset utf-8;
    client_max_body_size 100m;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    access_log off;
    error_log /var/log/nginx/pterodactyl.app-error.log error;
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "http";
        fastcgi_intercept_errors off;
    }
    location ~ /\.(?!well-known).* { deny all; }
}
vanillaNGX
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi

    rm -rf "$TMP"
    cd "$PANEL_PATH"
    php8.4 artisan config:clear 2>/dev/null && php8.4 artisan cache:clear 2>/dev/null && php8.4 artisan route:clear 2>/dev/null
    chown -R www-data:www-data "$PANEL_PATH" 2>/dev/null || true

    green "  Uninstall complete — vanilla Pterodactyl restored"
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════
echo ""
bold "═══════════════════════════════════════"
bold "  Avtix Game Panel"
bold "═══════════════════════════════════════"
echo ""
echo "  1) Install   - Apply theme to panel"
echo "  2) Repair    - Re-apply theme"
echo "  3) Uninstall - Restore vanilla"
echo ""
bold "═══════════════════════════════════════"
echo ""
read -p "  Select [1-3]: " CHOICE
case "$CHOICE" in
    1) do_install ;;
    2) do_repair ;;
    3) do_uninstall ;;
    *) echo "Invalid option."; exit 1 ;;
esac
