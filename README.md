# MediaWiki Pterodactyl Egg

Run **MediaWiki 1.45** on Pterodactyl with Nginx, PHP 8.x, and **bundled MariaDB**. The egg installs the wiki from the CLI, syncs settings from the panel, and ships a large extension set similar to [Old School RuneScape Wiki](https://oldschool.runescape.wiki/w/Special:Version).

Repo: [Mark7625/MediaWiki-Pterodactyl-Egg](https://github.com/Mark7625/MediaWiki-Pterodactyl-Egg)

---

## What it does

- Downloads MediaWiki into `www/` and runs **auto-install** when `AUTOINSTALL_STATUS=1`
- Starts **MariaDB** in the container (default port `3406`) or uses an external database
- Keeps `LocalSettings.php` in sync with panel vars (`MW_SERVER`, DB credentials, site name, language)
- Configures **short URLs** and serves the **main page at `/`** (not `/index.php`)
- Bundles **50+ extensions** and **2 skins** on install (lists below)
- Optional: Git pull, Composer, Cron, Certbot, Cloudflare Tunnel, Redis cache, Elasticsearch search

**Web root:** `www`  
**Wiki URL:** set `MW_SERVER` to your public URL with port, e.g. `http://your-ip:9090`

---

## Quick start

1. Import `egg-nginx-v3.json` in Pterodactyl → **Nests** → **Import Egg**
2. Create a server with the **Nginx** egg and a Docker image that matches `PHP_VERSION` (e.g. `mediawiki-pterodactyl-egg:8.2-latest`)
3. Set `MW_SERVER`, admin password, and database vars (defaults work for bundled MariaDB)
4. Start the server and wait for install to finish (many extensions → first install can take a while)
5. Rebuild the image after Dockerfile changes: `./scripts/build-image.sh 8.2`

**Branch:** `EGG_BRANCH=master` (this repo uses `master`, not `main`).

---

## Default install

### PHP (Docker image)

| Component | Version |
|-----------|---------|
| ICU (intl) | 76.1 |
| [Wikidiff2](https://www.mediawiki.org/wiki/Wikidiff2) | 1.14.1 |
| [LuaSandbox](https://www.mediawiki.org/wiki/LuaSandbox) | 4.1.3 |
| Lua | 5.1.x |
| Pygments | (for SyntaxHighlight) |

Plus usual MediaWiki modules: mysqli, intl, mbstring, xml, curl, gd, imagick, apcu, opcache, etc.

### URLs and entry points

| Setting | Value |
|---------|--------|
| Main page | `/` |
| Articles | `/w/$1` |
| Script path | `/` |
| API | `/api.php` |
| REST | `/rest.php` |

Nginx rewrites and `LocalSettings.php` are applied on install and on each start (`$wgMainPageIsDomainRoot`, `$wgArticlePath`, etc.).

### Default skins

- [MinervaNeue](https://www.mediawiki.org/wiki/Skin:MinervaNeue) — mobile default
- [Vector](https://www.mediawiki.org/wiki/Skin:Vector) — desktop default

Override with panel var `MW_SKINS` (comma-separated). List: `modules/mediawiki/skins-default.txt`.

### Bundled extensions (REL1_45)

Installed from `modules/mediawiki/extensions-wikimedia.txt` (extdist) and `extensions-weirdgloop.txt` (Git forks). Add more with optional `MW_EXTENSIONS`.

**Wikimedia / extdist:** AJAXPoll, AntiSpoof, CategoryTree, CheckUser, Cite, CodeEditor, CodeMirror, ContactPage, Description2, Editcount, Gadgets, GlobalBlocking, ImageMap, InputBox, JsonConfig, Kartographer, LinkSuggest, LoginNotify, LuaSandbox, Math, MultimediaViewer, NewUserMessage, OATHAuth, OAuth, ParserFunctions, Poem, ProtectSite, RandomSelection, RevisionSlider, SpamBlacklist, SyntaxHighlight, TemplateData, TemplateSandbox, TemplateStyles, TextExtracts, Thanks, TitleBlacklist, Variables, WikiEditor

**Weird Gloop / community forks:** VariablesLua, SimpleBatchUpload, GloopTweaks, GCS, Tabber, DynamicPageList4, Bucket, RSHiscores, TimedMediaHandler, MigrateUserAccount, Scribunto, VisualEditor, Echo, GlobalUserrights, MobileFrontend, Popups, EmbedVideo, SearchDigest, Less, PageImages, DismissableSiteNotice, TemplateStylesExtender, Discord, EasyTimeline, GloopControl, InternalExternalLinks, RSLookup, Parsoid

*See `modules/mediawiki/extensions-weirdgloop.txt` and `extensions-wikimedia.txt` for full details.*

**Optional (panel, not in default lists)**

| Variable | Adds |
|----------|------|
| `ELASTICSEARCH_STATUS=1` | CirrusSearch, Elastica (needs Elasticsearch at `ELASTICSEARCH_HOST`) |
| `REDIS_STATUS=1` | Redis object cache extension |

**Not included** (private or hosted-only on OSRS Wiki): GloopAnalytics, GloopControl, RSLookup, TempUserWordNames, InternalExternalLinks, and production Elasticsearch/GCP wiring.

### Other defaults

- Uploads hardened in nginx (`/images/` — no PHP execution, nosniff)
- APCu object cache when Redis is off
- Egg auto-update for `modules/`, `nginx/`, `php/` (not your `www/` data)

---

## Panel variables (common)

| Variable | Purpose |
|----------|---------|
| `MW_SERVER` | Public wiki URL (with port if needed) |
| `AUTOINSTALL_STATUS` | `1` = run CLI install |
| `MW_EXTENSIONS` | Extra extensions (comma-separated); bundled lists always apply |
| `MW_SKINS` | Override default skins |
| `DB_*` / `DB_PORT` | Database (default bundled MariaDB on `3406`) |
| `PHP_VERSION` | Must match Docker image tag |

---

## SSL Certificate Setup Tutorial

With **Certbot DNS-01 Challenge**, you can create SSL certificates for your domain **without** needing port 80 or 443 open on the host.  
[Let's Encrypt | Getting Started](https://letsencrypt.org/getting-started/)

### Requirements

- A [DNS provider](https://www.cloudflare.com/) account where you can create TXT records  
- Your domain name

### Steps

1. **Enable Certbot** in Pterodactyl startup: `CERTBOT_STATUS=true`
2. **Email:** `CERTBOT_EMAIL=your@email.com`
3. **Domain:** `CERTBOT_DOMAIN=yourdomain.com`
4. **Restart** the server and watch the console — Certbot prints a DNS TXT record
5. **Create the TXT record** at your DNS provider:
   - Name: `_acme-challenge.yourdomain.com`
   - Type: `TXT`
   - Value: copy from Certbot output
   - Wait 2–5 minutes for propagation
6. **Verify DNS:** https://toolbox.googleapps.com/apps/dig/#TXT/_acme-challenge.yourdomain.com
7. **Continue in the Pterodactyl console** — press SPACE then ENTER twice
8. **Copy SSL template** from `/nginx/conf.d/default-ssl.conf.temp` into `default.conf`
9. **Replace placeholders** in `default.conf`: `<port>` (e.g. `25783`), `<domain>` (e.g. `yourdomain.com`)
10. **Restart** nginx / the server
11. **DNS A records:** `@` and `www` → your server IP
12. Open `https://<domain>:<port>`

### Notes

- Staging certs are for testing only (`CERTBOT_STAGING=true` for production use `false` and `CERTBOT_FORCE_RENEWAL=true` if renewing)
- Certificates expire after 90 days — renewal is manual for now
- Cert files: `/home/container/letsencrypt/config/live/yourdomain.com/`

---

## Composer

Install PHP dependencies on startup.

- If `composer.json` exists in `/home/container`, Composer runs automatically
- Otherwise set `COMPOSER_MODULES` with space-separated packages, e.g.  
  `symfony/http-foundation:^6.0 monolog/monolog`
- Format: `vendor/package[:version]` — packages must exist on [Packagist](https://packagist.org/)
- Wrong names show errors in the console; many packages increase startup time

---

## ionCube Loader

- **ionCube Loader** is included in the Docker image and enabled automatically when encrypted PHP files are detected
- Upload ionCube-encoded scripts and run them — no extra panel vars required

---

## Cloudflare Tunnel

Expose the wiki with **Cloudflared** without opening ports on your router.  
[Create a remotely-managed tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/)

### Requirements

- A [Cloudflare](https://dash.cloudflare.com/) account

### Steps

1. In **Zero Trust** → **Networks** → **Tunnels**, choose **Create a tunnel**
2. Connector type: **Cloudflared** → **Next**
3. Name the tunnel → **Save tunnel**
4. Copy the **tunnel token** (very long string)
5. In Pterodactyl startup, enable Cloudflared and paste the token into the tunnel variable
6. Add a **public hostname**: type **HTTP**, URL **`localhost`** + your **allocation port** (same port Pterodactyl uses for the web server)
7. Restart the server

Traffic goes Cloudflare → tunnel → `localhost:<port>` → nginx in the container.

---

## Git module

- Set `GIT_ADDRESS` to your repository URL
- Set `GIT_STATUS=1` (or `true`)
- On first start the repo is cloned into `www/`
- On each restart, `git pull` runs (use with care on production wikis)

---

## Cron

- Set `CRON_STATUS=1` and edit `/home/container/crontab`
- Jobs run in-container; logs go to `/home/container/logs/cron.log`
- Use **absolute paths** in commands

Example:

```bash
# Daily backup at 2 AM
0 2 * * * tar -czf /home/container/backups/backup-$(date +%Y%m%d).tar.gz /home/container/www
```

---

## Troubleshooting: Missing PHP Extensions

If you see errors about **LuaSandbox, Wikidiff2, or Excimer** not being available:

### Cause

These extensions are compiled at **Docker image build time**. They are not available in older images.

### Solution: Rebuild the image

Rebuild with the updated build script:

```bash
./scripts/build-image.sh 8.2  # or your PHP version (8.2, 8.3, 8.4)
```

Then redeploy the container using the new image.

### Manual install (if needed)

If the image has build tools available, you can build locally inside the container as root:

```bash
apt-get update && apt-get install -y build-essential php-dev php-pear liblua5.1-dev libthai-dev zlib1g-dev libzip-dev

# LuaSandbox
yes '' | pecl install luasandbox-4.1.3
echo "extension=luasandbox.so" > /home/container/php/conf.d/20-luasandbox.ini

# Wikidiff2
cd /tmp && wget https://releases.wikimedia.org/wikidiff2/wikidiff2-1.14.1.tar.gz && tar -xzf wikidiff2-1.14.1.tar.gz && cd wikidiff2-1.14.1
phpize8.2 && ./configure --with-php-config=/usr/bin/php-config8.2 && make && make install
echo "extension=wikidiff2.so" > /home/container/php/conf.d/20-wikidiff2.ini

# Restart
systemctl restart php8.2-fpm
```

**Note:** Non-root containers cannot install at runtime. Rebuild the image instead.

---

## Change PHP version

1. Pterodactyl **Startup** tab → change **PHP VERSION** variable  
2. **Startup** → select the Docker image tag that matches (e.g. `8.2` vs `8.4`)  
3. Restart the server  

[PHP supported versions](https://www.php.net/supported-versions.php)

---

## Credits

| Project | Author | Link |
|---------|--------|------|
| Base Pterodactyl Nginx egg | **Ym0T** | [github.com/Ym0T](https://github.com/Ym0T) |
| Earlier nginx egg | tenten8401 | [pterodactyl-nginx](https://gitlab.com/tenten8401/pterodactyl-nginx) |
| MediaWiki + MariaDB bundle, extensions, auto-install | **Mark7625** | [MediaWiki-Pterodactyl-Egg](https://github.com/Mark7625/MediaWiki-Pterodactyl-Egg) |

Extension forks and tooling also come from [Weird Gloop](https://github.com/orgs/weirdgloop/repositories) and the wider MediaWiki community.

---

## License

[MIT License](LICENSE)
