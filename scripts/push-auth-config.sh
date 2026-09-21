#!/usr/bin/env bash
# Push OpenCourt's auth settings to the Supabase project: the email templates in
# supabase/templates/, their subjects, the site URL and redirect allow-list, and the SMTP
# credentials that let us use our own templates at all (the built-in email service allows
# only 2 messages an hour and no template editing).
#
# Nothing secret is stored in the repo. Every credential comes from the environment, so
# type these in your own shell and don't paste them into a file or a chat:
#
#   export SUPABASE_ACCESS_TOKEN='sbp_...'     # supabase.com/dashboard/account/tokens
#   export SMTP_HOST=smtp.gmail.com SMTP_PORT=465
#   export SMTP_USER='you@gmail.com' SMTP_FROM='you@gmail.com'
#   export SMTP_PASS='abcd efgh ijkl mnop'     # Gmail app password, not your password
#   scripts/push-auth-config.sh
#
# Optional, to turn on Google sign-in at the same time:
#   export GOOGLE_CLIENT_ID='...apps.googleusercontent.com' GOOGLE_SECRET='GOCSPX-...'
#
# Run `unset SMTP_PASS GOOGLE_SECRET SUPABASE_ACCESS_TOKEN` when you're done.
# Set DRY_RUN=1 to see what would be sent without sending it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project="${SUPABASE_PROJECT_REF:-inkvqajxepcaqjubhfye}"
site="${SITE_URL:-https://viv-411.github.io/OpenCourt/}"
python="${PYTHON:-python3}"

: "${SUPABASE_ACCESS_TOKEN:?set SUPABASE_ACCESS_TOKEN (dashboard -> account -> access tokens)}"
: "${SMTP_HOST:?set SMTP_HOST}"
: "${SMTP_USER:?set SMTP_USER}"
: "${SMTP_PASS:?set SMTP_PASS}"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

SITE="$site" "$python" - "$root" >"$body" <<'PY'
import json, os, sys

root = sys.argv[1]


def template(name):
    with open(f"{root}/supabase/templates/{name}.html") as f:
        return f.read()


config = {
    "site_url": os.environ["SITE"],
    # Where the app and the hand-off page are allowed to send people back to.
    "uri_allow_list": ",".join([
        "opencourt://auth/**",
        os.environ["SITE"].rstrip("/") + "/auth/**",
    ]),
    "mailer_autoconfirm": False,
    "mailer_subjects_confirmation": "Confirm your OpenCourt account",
    "mailer_templates_confirmation_content": template("confirmation"),
    "mailer_subjects_recovery": "Reset your OpenCourt password",
    "mailer_templates_recovery_content": template("recovery"),
    "smtp_host": os.environ["SMTP_HOST"],
    "smtp_port": os.environ.get("SMTP_PORT", "465"),
    "smtp_user": os.environ["SMTP_USER"],
    "smtp_pass": os.environ["SMTP_PASS"],
    "smtp_admin_email": os.environ.get("SMTP_FROM", os.environ["SMTP_USER"]),
    "smtp_sender_name": os.environ.get("SMTP_SENDER_NAME", "OpenCourt"),
    "rate_limit_email_sent": int(os.environ.get("EMAIL_RATE_LIMIT", "30")),
}

if os.environ.get("GOOGLE_CLIENT_ID"):
    config["external_google_enabled"] = True
    config["external_google_client_id"] = os.environ["GOOGLE_CLIENT_ID"]
    config["external_google_secret"] = os.environ["GOOGLE_SECRET"]

json.dump(config, sys.stdout)
PY

# Keep this file plain ASCII: macOS ships bash 3.2, which folds a stray multi-byte
# character after "$project" into the variable name.
echo "Pushing auth config to project ${project}..."

if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN set: not sending. Settings that would be pushed:"
    BODY="$body" "$python" -c 'import json,os,sys
c = json.load(open(os.environ["BODY"]))
for k in sorted(c):
    v = c[k]
    if k in ("smtp_pass", "external_google_secret"):
        v = "(hidden, %d characters)" % len(v)
    elif k.startswith("mailer_templates_"):
        v = "(%d characters of HTML)" % len(v)
    print("  %s: %s" % (k, v))'
    exit 0
fi
out="$(curl -fsS -X PATCH "https://api.supabase.com/v1/projects/$project/config/auth" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "@$body")"

# Print back only the settings we set, never the secrets.
SUPA_OUT="$out" "$python" - <<'PY'
import json, os

c = json.loads(os.environ["SUPA_OUT"])
for key in ("site_url", "uri_allow_list", "mailer_subjects_confirmation",
            "mailer_subjects_recovery", "smtp_host", "smtp_admin_email",
            "smtp_sender_name", "rate_limit_email_sent", "external_google_enabled"):
    if key in c:
        print(f"  {key}: {c[key]}")
print("\nDone. Send yourself a test sign-up from the app to check the email.")
PY
