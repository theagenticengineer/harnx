#!/usr/bin/env bash
# create-app.sh — creates the GitHub App the ai-review pipeline mints its
# write-scoped token from, automating everything GitHub allows to be
# automated and stopping cleanly at the one step it does not.
#
# This is the first half of the ai-review setup pipeline; configure-environment.sh
# runs immediately after and consumes this script's two outputs (an app id and
# a .pem private key file). docs/ai-review-setup.md is the operator's guide and
# explains, from scratch and without reference to either script, what all of
# this is for, including how to do every step of it by hand.
#
# WHY A BROWSER STEP IS UNAVOIDABLE: GitHub has no API that creates an App.
# The nearest thing is the App MANIFEST flow, which is deliberately
# human-confirmed: a program submits a manifest describing the App it wants,
# a HUMAN confirms the creation in a browser, and GitHub hands back a
# short-lived code that a program exchanges for the App's real credentials.
# The confirmation is the point of the design, not an omission in it, so this
# script automates the manifest, the exchange, and the key handling, and
# leaves exactly one click to a person.
#
# WHY THE PERMISSIONS ARE WHAT THEY ARE: `pull_requests: write`, and nothing
# else. That is what posting a finding as a resolvable review thread and
# upserting the status comment need, and it is deliberately the whole list. The
# token this App mints is handed to a job that also processes review output, so
# its scope IS the blast radius if it ever leaks: at `pull_requests: write` the
# worst case is tampering with this repository's pull request conversations, not
# with the repository.
#
# WHAT THIS PERMISSION DOES NOT BUY, corrected here because the sentence above
# used to claim it and that claim is what would stop the next person looking.
# It said this scope covers "reopening one that regressed". It does not.
# `unresolveReviewThread` is refused for an App installation token with
# `Resource not accessible by integration`, and there is no permission to widen:
# resolving and unresolving review threads are not available to Apps at all.
#
# MEASURED, NOT INFERRED. In one run of ai-review-trunk.yml on this repository,
# the same token created three pull request review comments, which requires
# exactly this permission, while four `unresolveReviewThread` calls in that same
# job were refused. One token, one run, writes accepted and unresolve denied.
# The App's own metadata confirms the grant is present:
# `gh api /apps/harnx-ai-review` reports `pull_requests: write`.
#
# post-findings.sh therefore does not depend on reopening. A recurrence it
# cannot reopen is posted as a NEW thread, which is unresolved by construction,
# so check-resolved.sh blocks the merge exactly as a reopened thread would.
#
# HANDLING OF SECRET MATERIAL: the private key GitHub returns is written
# straight from the API response into a file created under a 077 umask. It is
# never printed, never placed in a variable, and never passed as an argument.
# The script prints its PATH, which is what the next script needs.
#
# WHICH IDENTIFIER THE PIPELINE USES: the App's CLIENT ID, not its numeric app
# id. actions/create-github-app-token deprecated `app-id` in v3, and the two
# are separate values rather than two spellings of one, so the conversion
# response's `client_id` is what the next script consumes. The numeric id is
# still printed, because it is what the App's settings pages and the Apps API
# are keyed on when something needs debugging, but nothing in the pipeline
# reads it any more.
#
# Env:
#   APP_NAME   optional; the App's name, which must be unique across all of
#              GitHub. Default "<repo>-ai-review".
#   ORG        optional; create the App under this organisation instead of
#              under your own user account.
#   OUT_DIR    optional; where to write the .pem, default the current
#              directory.
#   PORT       optional; the loopback port the browser is redirected back to,
#              default 8787.
#   DRY_RUN    optional; set to 1 to render and validate the manifest and
#              print what would happen, without opening a browser or calling
#              GitHub. This is the only way to exercise this script without
#              actually creating an App.
#   GITHUB_REPOSITORY optional; owner/repo, otherwise read from `gh`.
set -euo pipefail

repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
if [ -z "$repo" ]; then
  echo "create-app: cannot determine the repository; set GITHUB_REPOSITORY or authenticate gh." >&2
  exit 1
fi
repo_name="${repo#*/}"
app_name="${APP_NAME:-${repo_name}-ai-review}"
out_dir="${OUT_DIR:-.}"
port="${PORT:-8787}"
dry_run="${DRY_RUN:-}"

if [ -n "${ORG:-}" ]; then
  create_url="https://github.com/organizations/${ORG}/settings/apps/new"
  owner_desc="organisation ${ORG}"
else
  create_url="https://github.com/settings/apps/new"
  owner_desc="your user account"
fi

# Built with jq, not a heredoc: the App name and repository URL are
# interpolated values, and jq is what guarantees they are JSON-escaped rather
# than trusted to contain no quote.
#
# hook_attributes carries a placeholder URL with active:false because the
# manifest schema requires the key to be present; this App receives no
# webhooks and needs no endpoint. default_events is empty for the same reason.
manifest="$(jq -cn \
  --arg name "$app_name" \
  --arg url "https://github.com/$repo" \
  --arg redirect "http://127.0.0.1:${port}/callback" '
  {
    name: $name,
    url: $url,
    redirect_url: $redirect,
    public: false,
    hook_attributes: { url: "https://example.invalid/unused", active: false },
    default_events: [],
    default_permissions: { pull_requests: "write" }
  }')"

echo "create-app: repository   $repo"
echo "create-app: app name     $app_name"
echo "create-app: owner        $owner_desc"
echo "create-app: permissions  pull_requests: write"
echo "create-app: manifest:"
printf '%s\n' "$manifest" | jq .

if [ -n "$dry_run" ]; then
  # Validating the manifest is the whole point of the dry run: it is the only
  # part of this flow that can be checked without creating a real App.
  if ! printf '%s' "$manifest" | jq -e '
    (.name | type == "string" and length > 0)
    and (.url | type == "string")
    and (.redirect_url | startswith("http://127.0.0.1:"))
    and (.public == false)
    and (.default_permissions.pull_requests == "write")
    and (.hook_attributes.active == false)' >/dev/null; then
    echo "create-app: the rendered manifest failed validation." >&2
    exit 1
  fi
  echo
  echo "create-app: DRY_RUN. The manifest above is well-formed and carries the"
  echo "            permissions the pipeline needs. A live run would POST it to"
  echo "            $create_url"
  echo "            for you to confirm in a browser, exchange the returned code,"
  echo "            and write the private key to $out_dir/${app_name}.pem."
  exit 0
fi

mkdir -p "$out_dir"
# Everything this script writes is either secret or leads to something
# secret, so the whole run is under a private umask rather than chmod-ing
# after the fact, which would leave a window where the key is world-readable.
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A nonce echoed back by GitHub with the code. A stray or replayed callback
# hitting this loopback port then cannot be mistaken for this run's answer.
state="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# An auto-submitting form, because a manifest is delivered to GitHub as a
# FORM POST from a browser, not as an API call: GitHub needs the human's
# authenticated session to be the thing that submits it.
{
  printf '%s\n' '<!doctype html><html><head><meta charset="utf-8">'
  printf '%s\n' "<title>Create the ${app_name} GitHub App</title></head><body>"
  printf '%s\n' "<p>Sending the App manifest to GitHub. Confirm the creation there.</p>"
  printf '%s' "<form id=\"f\" method=\"post\" action=\"${create_url}?state=${state}\">"
  printf '%s' '<input type="hidden" name="manifest" value="'
  # The manifest goes into a double-quoted HTML attribute, so every character
  # that could end it early, or be read as markup, is entity-escaped. `&`
  # first, deliberately: escaping it after the others would re-escape the
  # ampersands they just introduced.
  printf '%s' "$manifest" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
  printf '%s\n' '"><noscript><button type="submit">Continue</button></noscript></form>'
  printf '%s\n' '<script>document.getElementById("f").submit()</script></body></html>'
} >"$work/manifest.html"

code_file="$work/code"

if command -v python3 >/dev/null 2>&1; then
  cat >"$work/serve.py" <<'PY'
import http.server
import sys
import time
import urllib.parse

page, code_path, want_state = sys.argv[1], sys.argv[2], sys.argv[3]
DEADLINE = time.monotonic() + 300


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/callback":
            query = urllib.parse.parse_qs(parsed.query)
            code = (query.get("code") or [""])[0]
            state = (query.get("state") or [""])[0]
            if not code or state != want_state:
                self.send_error(400, "unexpected callback")
                return
            with open(code_path, "w") as handle:
                handle.write(code)
            body = b"<p>App created. You can close this tab and return to the terminal.</p>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.server.done = True
            return
        with open(page, "rb") as handle:
            body = handle.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.HTTPServer(("127.0.0.1", int(sys.argv[4])), Handler)
server.done = False
# Bounded, not open-ended: an abandoned confirmation must give the terminal
# back rather than leave a listener holding the port forever. The bash side
# reads this as "no code received" and exits without creating anything.
server.timeout = 5
while not server.done and time.monotonic() < DEADLINE:
    server.handle_request()
PY
  echo
  echo "create-app: open http://127.0.0.1:${port}/ and confirm the App creation."
  # Best-effort: a headless or remote machine has neither, and the URL above
  # is all the operator actually needs.
  (command -v open >/dev/null 2>&1 && open "http://127.0.0.1:${port}/") ||
    (command -v xdg-open >/dev/null 2>&1 && xdg-open "http://127.0.0.1:${port}/") ||
    true
  python3 "$work/serve.py" "$work/manifest.html" "$code_file" "$state" "$port"
else
  echo
  echo "create-app: python3 is not available, so this run cannot catch the"
  echo "            browser redirect for you. Two manual steps instead:"
  echo
  echo "  1. Open this file in your browser and confirm the App creation:"
  echo "       $work/manifest.html"
  echo "  2. GitHub will then redirect you to a http://127.0.0.1:${port}/callback?..."
  echo "     address that will FAIL to load. That is expected. Copy the whole"
  echo "     failed URL out of the address bar and paste it below."
  echo
  printf 'Redirect URL: '
  read -r pasted
  printf '%s' "$pasted" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' >"$code_file"
  if ! printf '%s' "$pasted" | grep -q "state=${state}"; then
    echo "create-app: that URL does not carry this run's state value; refusing it." >&2
    exit 1
  fi
fi

if [ ! -s "$code_file" ]; then
  echo "create-app: no manifest code was received; nothing was created." >&2
  exit 1
fi

# The exchange. The code is single-use and short-lived, which is why this
# happens immediately rather than being handed back to the operator.
response="$work/conversion.json"
if ! gh api -X POST "app-manifests/$(cat "$code_file")/conversions" \
  -H "Accept: application/vnd.github+json" >"$response"; then
  echo "create-app: exchanging the manifest code failed. Codes expire quickly; re-run this script." >&2
  exit 1
fi

app_id="$(jq -r '.id' "$response")"
client_id="$(jq -r '.client_id // empty' "$response")"
slug="$(jq -r '.slug' "$response")"
# The conversion response has carried client_id for as long as the endpoint has
# existed, but it is the one field the whole handoff now depends on, so an
# absent value is recovered from the public Apps endpoint rather than allowed
# to produce a banner with an empty command in it.
if [ -z "$client_id" ]; then
  client_id="$(gh api "/apps/${slug}" -q .client_id 2>/dev/null || true)"
fi
if [ -z "$client_id" ]; then
  echo "create-app: the App was created, but its client id could not be read from the conversion response or from /apps/${slug}. Copy it from https://github.com/settings/apps/${slug} and pass it to configure-environment.sh as CLIENT_ID." >&2
  client_id="<copy the Client ID from the App's settings page>"
fi
pem_path="$out_dir/${app_name}.pem"
# jq reads the key out of the response FILE and writes it to the key FILE. It
# is never a shell value, so no trace, no history, and no `ps` listing can
# show it.
jq -r '.pem' "$response" >"$pem_path"

if ! grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$pem_path"; then
  echo "create-app: the App was created but its private key did not come back in a usable form; generate a new key from the App's settings page." >&2
  exit 1
fi

# The branch name the next step needs, read live rather than assumed. The
# trunk workflow is workflow_run-triggered, so it always runs on the
# repository's DEFAULT branch, and that is the branch the environment's
# allow-list has to name. configure-environment.sh defaults to "main", which
# is right for an ordinary repository and exactly wrong during an epic that
# keeps a trust-anchor branch as the default: the operator would follow this
# banner, accept the default, and get an environment that releases nothing to
# the branch that needs it.
default_branch="$(gh api "repos/$repo" -q .default_branch 2>/dev/null || true)"
if [ -z "$default_branch" ]; then
  default_branch="<the repository's default branch>"
fi

cat <<HANDOFF

create-app: created the App.

  app id     $app_id   (public; for the settings pages and the Apps API)
  client id  $client_id   (public; this is what the token action consumes)
  slug       $slug
  key file   $pem_path   (never printed; keep it out of the repository)

NEXT STEPS

  1. INSTALL the App on $repo. Creating an App does not install it, and an
     uninstalled App can mint no token:

       https://github.com/settings/apps/${slug}/installations

  2. Configure the environment that will hold its credentials. ALLOWED_BRANCHES
     must name the branch the credentialed workflow actually runs on, which is
     $repo's DEFAULT branch, currently '$default_branch':

       CLIENT_ID=$client_id APP_KEY_PATH=$pem_path \\
         ALLOWED_BRANCHES=$default_branch \\
         bash scripts/ai-review/configure-environment.sh

  3. Once that has run and you have supplied the engine token it asks for,
     DELETE $pem_path. GitHub keeps no copy, but neither should your disk:
     the environment secret is the deployed copy, and a new key can always be
     generated from the App's settings page.
HANDOFF
