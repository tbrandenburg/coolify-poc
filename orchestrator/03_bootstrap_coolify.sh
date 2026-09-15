#!/usr/bin/env bash
# 03_bootstrap_coolify.sh: turn a fresh local Coolify install into one with a
# usable API token. GH_TOKEN is NOT a Coolify credential — Coolify's
# protected API requires its own bearer token, and self-hosted instances
# require API access to be enabled. This step acquires that credential
# locally (via `php artisan tinker` inside the Coolify container we just
# started ourselves) and stores it ONLY in a gitignored temp file.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

transition START_COOLIFY BOOTSTRAP_COOLIFY

CONTAINER="coolify-b-coolify-1"
COOLIFY_URL="$(state_get coolify_url)"
[ -n "$COOLIFY_URL" ] || fail "coolify_url missing; run 02_start_coolify.sh first"

docker exec "$CONTAINER" true >/dev/null 2>&1 || fail "Coolify container '$CONTAINER' not running"

PHP_SCRIPT="$(mktemp)"
cat > "$PHP_SCRIPT" << 'PHPEOF'
<?php
use App\Models\User;

// Coolify's dev seeder pre-creates user id=0 owning the root team (id=0) and
// the pre-provisioned "localhost" server. We reuse that identity instead of
// creating a parallel team with no server, and enable API access, which
// self-hosted Coolify keeps off by default.
$user = User::find(0);
if (!$user) {
    fwrite(STDERR, "seeded root user (id=0) not found — unexpected Coolify dev seed\n");
    exit(1);
}
$team = $user->teams()->where('team_id', 0)->exists() ? \App\Models\Team::find(0) : $user->teams()->first();

$settings = instanceSettings();
$settings->is_api_enabled = true;
$settings->save();

// Idempotent: replace any token from a previous run of this agent.
$user->tokens()->where('name', 'agent-bootstrap-token')->delete();

$tokenEntropy = \Illuminate\Support\Str::random(40);
$plainTextToken = $tokenEntropy . hash('crc32b', $tokenEntropy);
$token = $user->tokens()->create([
    'name' => 'agent-bootstrap-token',
    'token' => hash('sha256', $plainTextToken),
    'abilities' => ['*'],
    'team_id' => $team->id,
]);

echo "USER_ID=" . $user->id . PHP_EOL;
echo "TEAM_ID=" . $team->id . PHP_EOL;
echo "COOLIFY_TOKEN=" . $token->getKey() . '|' . $plainTextToken . PHP_EOL;
PHPEOF

docker cp "$PHP_SCRIPT" "$CONTAINER:/tmp/agent-bootstrap.php" >/dev/null
OUTPUT="$(docker exec "$CONTAINER" php artisan tinker --execute="require '/tmp/agent-bootstrap.php';" 2>&1)"
docker exec "$CONTAINER" rm -f /tmp/agent-bootstrap.php >/dev/null
rm -f "$PHP_SCRIPT"

echo "$OUTPUT" | grep -q '^COOLIFY_TOKEN=' || fail "bootstrap did not return a token; output was: $OUTPUT"

COOLIFY_TOKEN="$(echo "$OUTPUT" | grep '^COOLIFY_TOKEN=' | cut -d= -f2-)"
TEAM_ID="$(echo "$OUTPUT" | grep '^TEAM_ID=' | cut -d= -f2-)"

# Store the disposable credential ONLY in a gitignored temp file, never in
# state.json (which we may want to inspect/print) and never in the repo.
umask 077
echo "COOLIFY_TOKEN='$COOLIFY_TOKEN'" > "$SECRETS_FILE"
state_set coolify_team_id "$TEAM_ID"
resources_set coolify_token_created "true"

log "Verifying the freshly bootstrapped API token works..."
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/teams/current")"
[ "$CODE" = "200" ] || fail "Coolify API token verification failed (HTTP $CODE)"

log "Coolify API token bootstrapped and verified (team_id=$TEAM_ID)"

# The dev seeder's "localhost" server points its IP at a fixed hostname
# ("coolify-testing-host") that only exists in the single-instance
# docker-compose.dev.yml topology. scripts/dev-instances uses a different
# compose project/network, so that hostname doesn't resolve there. Bring up
# the optional "testing-host" profile (an SSH-reachable container with the
# Docker socket mounted, simulating the box Coolify would deploy to) and
# repoint the seeded server at its real DNS name inside this instance's
# network, then trigger + verify a real server validation round-trip.
COOLIFY_DIR="$(state_get coolify_dir)"
INSTANCE="$(state_get coolify_instance)"
TESTING_HOST_CONTAINER="coolify-$INSTANCE-testing-host-1"

log "Starting testing-host profile container ($TESTING_HOST_CONTAINER) as the SSH target for the seeded 'localhost' server"
( cd "$COOLIFY_DIR" && docker compose -p "coolify-$INSTANCE" -f docker-compose.dev-multi.yml \
    --env-file ".dev-instances/$INSTANCE.env" --profile testing-host up -d testing-host >/dev/null )

docker exec "$CONTAINER" php artisan tinker --execute="
\$s = \App\Models\Server::find(0);
\$s->ip = '$TESTING_HOST_CONTAINER';
\$s->save();
" >/dev/null

log "Triggering server validation via the API (not a shortcut — the real POST /servers/{uuid}/validate endpoint)"
curl -fsS -X POST -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api/v1/servers/localhost/validate" >/dev/null

ATTEMPTS=0
while true; do
  REACHABLE="$(docker exec "$CONTAINER" php artisan tinker --execute="
    \$s = \App\Models\Server::find(0); \$s->refresh();
    echo (\$s->settings->is_reachable ? 'true' : 'false') . ',' . (\$s->settings->is_usable ? 'true' : 'false');
  " 2>&1 | tail -1)"
  [ "$REACHABLE" = "true,true" ] && break
  ATTEMPTS=$((ATTEMPTS + 1))
  [ "$ATTEMPTS" -ge 15 ] && fail "server localhost never became reachable+usable (last state: $REACHABLE)"
  sleep 2
done

log "Server 'localhost' is reachable and usable"
