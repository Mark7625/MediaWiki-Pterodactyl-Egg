#!/usr/bin/env python3
"""Sync install-script.sh into egg-nginx-v3.json with Pterodactyl-style escaped slashes."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EGG = ROOT / "egg-nginx-v3.json"
INSTALL = ROOT / "scripts" / "install-script.sh"

DOCKER_IMAGES = {
    "mediawiki-pterodactyl-egg:8.5-latest": "mediawiki-pterodactyl-egg:8.5-latest",
    "mediawiki-pterodactyl-egg:8.4-latest": "mediawiki-pterodactyl-egg:8.4-latest",
    "mediawiki-pterodactyl-egg:8.3-latest": "mediawiki-pterodactyl-egg:8.3-latest",
    "mediawiki-pterodactyl-egg:8.2-latest": "mediawiki-pterodactyl-egg:8.2-latest",
}

REMOVE_VARS = {"WORDPRESS", "DB_ENGINE", "DB_HOST"}

NEW_VARIABLES = [
    {
        "name": "Egg Git Repository",
        "description": "GitHub repo URL for egg auto-updates (default: Mark7625/MediaWiki-Pterodactyl-Egg).",
        "env_variable": "EGG_REPO",
        "default_value": "https://github.com/Mark7625/MediaWiki-Pterodactyl-Egg",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|string",
        "field_type": "text",
    },
    {
        "name": "Egg Git Branch",
        "description": "Branch to track for auto-updates (default: master).",
        "env_variable": "EGG_BRANCH",
        "default_value": "master",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|string|max:128",
        "field_type": "text",
    },
    {
        "name": "Enable Auto-Install",
        "description": "Run MediaWiki CLI install on startup (creates LocalSettings.php).\r\n\r\n0 = false\r\n1 = true",
        "env_variable": "AUTOINSTALL_STATUS",
        "default_value": "1",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|boolean",
        "field_type": "text",
    },
    {
        "name": "Enable Bundled Database",
        "description": "Run MariaDB in this same server (127.0.0.1). Turn off to use an external database.\r\n\r\n0 = external DB\r\n1 = bundled (default)",
        "env_variable": "DB_STATUS",
        "default_value": "1",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|boolean",
        "field_type": "text",
    },
    {
        "name": "Database Port",
        "description": "MariaDB port on this server (default 3306). Change only if you need a different port.",
        "env_variable": "DB_PORT",
        "default_value": "3306",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|numeric|between:1,65535",
        "field_type": "text",
    },
    {
        "name": "Database Public",
        "description": "Expose bundled DB on 0.0.0.0 (not recommended). Wiki still uses 127.0.0.1.\r\n\r\n0 = local only\r\n1 = public",
        "env_variable": "DB_BIND_PUBLIC",
        "default_value": "0",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|boolean",
        "field_type": "text",
    },
    {
        "name": "Database Name",
        "description": "Leave empty to auto-generate on first start (.mw-secrets).",
        "env_variable": "DB_NAME",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string|max:64",
        "field_type": "text",
    },
    {
        "name": "Database User",
        "description": "Leave empty to auto-generate on first start (.mw-secrets).",
        "env_variable": "DB_USER",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string|max:64",
        "field_type": "text",
    },
    {
        "name": "Database Password",
        "description": "Leave empty to auto-generate on first start (.mw-secrets).",
        "env_variable": "DB_PASSWORD",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string|max:128",
        "field_type": "text",
    },
    {
        "name": "Database Root Password",
        "description": "Root password for bundled MariaDB setup. Leave empty to auto-generate.",
        "env_variable": "DB_ROOT_PASSWORD",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string|max:128",
        "field_type": "text",
    },
    {
        "name": "Wiki Site Name",
        "description": "MediaWiki site name (wiki name).",
        "env_variable": "MW_SITE_NAME",
        "default_value": "My Wiki",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|string|max:255",
        "field_type": "text",
    },
    {
        "name": "Wiki URL",
        "description": "Full wiki URL — leave blank to use server IP/port.",
        "env_variable": "MW_SERVER",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string",
        "field_type": "text",
    },
    {
        "name": "Wiki Language",
        "env_variable": "MW_LANG",
        "default_value": "en",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|string|max:20",
        "field_type": "text",
    },
    {
        "name": "Wiki Admin Username",
        "env_variable": "MW_ADMIN_USER",
        "default_value": "admin",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|string|max:255",
        "field_type": "text",
    },
    {
        "name": "Wiki Admin Password",
        "description": "Leave empty to auto-generate (.mw-secrets).",
        "env_variable": "MW_ADMIN_PASS",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string|max:128",
        "field_type": "text",
    },
    {
        "name": "MediaWiki Extensions",
        "description": "Extra extensions (comma-separated). Bundled lists in modules/mediawiki/*.txt are always installed.",
        "env_variable": "MW_EXTENSIONS",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string",
        "field_type": "text",
    },
    {
        "name": "MediaWiki Skins",
        "description": "Comma-separated skins (default: MinervaNeue,Vector from bundled list).",
        "env_variable": "MW_SKINS",
        "default_value": "",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string",
        "field_type": "text",
    },
    {
        "name": "Enable Redis",
        "description": "Use Redis for object cache.\r\n\r\n0 = false\r\n1 = true",
        "env_variable": "REDIS_STATUS",
        "default_value": "0",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|boolean",
        "field_type": "text",
    },
    {
        "name": "Redis Host",
        "env_variable": "REDIS_HOST",
        "default_value": "127.0.0.1",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string",
        "field_type": "text",
    },
    {
        "name": "Redis Port",
        "env_variable": "REDIS_PORT",
        "default_value": "6379",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|numeric|between:1024,65535",
        "field_type": "text",
    },
    {
        "name": "Enable Elasticsearch",
        "description": "CirrusSearch (needs external Elasticsearch).\r\n\r\n0 = false\r\n1 = true",
        "env_variable": "ELASTICSEARCH_STATUS",
        "default_value": "0",
        "user_viewable": True,
        "user_editable": True,
        "rules": "required|boolean",
        "field_type": "text",
    },
    {
        "name": "Elasticsearch Host",
        "env_variable": "ELASTICSEARCH_HOST",
        "default_value": "127.0.0.1:9200",
        "user_viewable": True,
        "user_editable": True,
        "rules": "nullable|string",
        "field_type": "text",
    },
]


def main():
    egg = json.loads(EGG.read_text(encoding="utf-8"))
    script = INSTALL.read_text(encoding="utf-8")
    if not script.startswith("#!/"):
        script = "#!/bin/bash\n" + script
    egg["scripts"]["installation"]["script"] = script.replace("\n", "\r\n")
    egg["docker_images"] = DOCKER_IMAGES
    egg["author"] = "Mark7625"
    egg["description"] = (
        "MediaWiki + Nginx + PHP with bundled MariaDB on the same server and CLI auto-install.\r\n\r\n"
        "DB_STATUS=1 (default): database runs at 127.0.0.1 — do not use your public IP for DB_HOST.\r\n"
        "Leave DB credentials empty to auto-generate. Set AUTOUPDATE_STATUS=0."
    )

    egg["variables"] = [v for v in egg["variables"] if v["env_variable"] not in REMOVE_VARS]
    existing = {v["env_variable"]: i for i, v in enumerate(egg["variables"])}
    for nv in NEW_VARIABLES:
        if nv["env_variable"] in existing:
            egg["variables"][existing[nv["env_variable"]]] = nv
        else:
            egg["variables"].append(nv)

    for v in egg["variables"]:
        if v["env_variable"] == "AUTOUPDATE_STATUS":
            v["default_value"] = "0"
        if v["env_variable"] == "PHP_VERSION":
            v["default_value"] = "8.4"
        if v["env_variable"] == "REDIS_STATUS":
            v["default_value"] = "0"

    raw = json.dumps(egg, indent=4, ensure_ascii=False).replace("/", r"\/")
    EGG.write_text(raw + "\n", encoding="utf-8")
    print("Updated", EGG)


if __name__ == "__main__":
    main()
