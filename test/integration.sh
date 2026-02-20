#!/bin/bash
# Integration tests for the simp-webrick stack.
#
# Usage (compose — podman-compose or docker compose):
#   ./test/integration.sh              # run against already-running stack
#   ./test/integration.sh --up        # start stack, run tests, tear down
#   ./test/integration.sh --up --keep # start stack, run tests, keep running
#
# Usage (Minikube / Kubernetes):
#   k8s/minikube-deploy.sh                      # deploy the stack (once)
#   ./test/integration.sh --k8s        # run against the deployed k8s stack
#
# Output follows TAP conventions: "ok N - desc" / "not ok N - desc"
# Exit 0 on all-pass, exit 1 if any test failed.
#
# NOTE: Group 5 revokes client.localdomain. Repeated runs against the same
# stack are handled automatically — the script revokes any stale "signed"
# client.localdomain cert before Group 3 so the agent can re-register.
# Use --up (compose) or redeploy (k8s) for a guaranteed-clean stack.

set -uo pipefail

# ── Container engine / compose detection ──────────────────────────────────────
# Prefer podman; fall back to docker.  Override with CONTAINER_ENGINE=docker.
if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    _ENGINE="$CONTAINER_ENGINE"
elif command -v podman &>/dev/null; then
    _ENGINE=podman
elif command -v docker &>/dev/null; then
    _ENGINE=docker
else
    printf 'Error: neither podman nor docker found\n' >&2
    exit 1
fi

# Compose command as an array so it works whether it's one word or two.
if [[ "$_ENGINE" == podman ]]; then
    if ! command -v podman-compose &>/dev/null; then
        printf 'Error: podman found but podman-compose not found\n' >&2
        exit 1
    fi
    _COMPOSE=(podman-compose)
else
    if docker compose version &>/dev/null 2>&1; then
        _COMPOSE=(docker compose)
    elif command -v docker-compose &>/dev/null; then
        _COMPOSE=(docker-compose)
    else
        printf 'Error: docker found but neither "docker compose" nor docker-compose available\n' >&2
        exit 1
    fi
fi

# ── Configuration ─────────────────────────────────────────────────────────────
CA_URL="http://localhost:8141"
MASTER_URL="https://puppet.passenger.localdomain:8140"
MASTER_CONTAINER="simp-webrick_puppet-master_1"
CLIENT_CONTAINER="simp-webrick_puppet-client_1"
WORK_DIR=$(mktemp -d /tmp/simp-webrick-integ.XXXXXX)
# Unique per-run suffix ensures tests don't collide with previous runs' CA state.
RUN_ID=$(date +%s)

# ── Argument parsing ───────────────────────────────────────────────────────────
DO_UP=false
DO_KEEP=false
DO_K8S=false

for arg in "$@"; do
    case "$arg" in
        --up)   DO_UP=true ;;
        --keep) DO_KEEP=true ;;
        --k8s)  DO_K8S=true ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 1 ;;
    esac
done

# k8s mode and --up are mutually exclusive (k8s lifecycle is managed by deploy.sh).
if $DO_K8S && $DO_UP; then
    printf 'Error: --k8s and --up are mutually exclusive.\n' >&2
    printf 'Use k8s/minikube-deploy.sh to bring up the k8s stack, then ./test/integration.sh --k8s.\n' >&2
    exit 1
fi

# ── Container exec wrappers ────────────────────────────────────────────────────
# All container interactions go through these functions so the same test code
# works against both compose and kubectl (k8s mode).

# k8s helper: look up the first pod name for a given app label.
_k8s_pod() { kubectl get pod -l "app=$1" \
                 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

if $DO_K8S; then
    exec_client()   { kubectl exec    "$(_k8s_pod puppet-client)" -- "$@"; }
    exec_master()   { kubectl exec    "$(_k8s_pod puppet-master)" -- "$@"; }
    exec_master_i() { kubectl exec -i "$(_k8s_pod puppet-master)" -- "$@"; }
    copy_from_client() {  # src-path dest-path
        kubectl cp "$(_k8s_pod puppet-client):$1" "$2"
    }
else
    exec_client()   { "$_ENGINE" exec    "$CLIENT_CONTAINER" "$@"; }
    exec_master()   { "$_ENGINE" exec    "$MASTER_CONTAINER" "$@"; }
    exec_master_i() { "$_ENGINE" exec -i "$MASTER_CONTAINER" "$@"; }
    copy_from_client() {  # src-path dest-path
        "$_ENGINE" cp "${CLIENT_CONTAINER}:$1" "$2"
    }
fi

# ── Stack lifecycle ────────────────────────────────────────────────────────────
# Names of compose-managed containers (used for belt-and-suspenders cleanup).
_COMPOSE_CONTAINERS=(simp-webrick_puppet-ca_1 simp-webrick_puppet-master_1 simp-webrick_puppet-client_1)
# PIDs of background kubectl port-forward processes (k8s mode only).
_PF_CA_PID=0
_PF_MASTER_PID=0

cleanup() {
    rm -rf "$WORK_DIR"
    if $DO_K8S; then
        # Stop port-forwards started for this test run.
        kill "$_PF_CA_PID" "$_PF_MASTER_PID" 2>/dev/null || true
    fi
    if $DO_UP && ! $DO_KEEP; then
        printf '\n# Tearing down compose stack...\n'
        "${_COMPOSE[@]}" down --timeout 5 2>/dev/null || true
        # Belt-and-suspenders: forcefully remove by name in case compose down
        # silently skips them (a known podman-compose 1.5.0 quirk).
        for _c in "${_COMPOSE_CONTAINERS[@]}"; do
            "$_ENGINE" rm -f "$_c" 2>/dev/null || true
        done
    fi
    # Safety net: wipe the client SSL dir so the container is left pristine.
    exec_client rm -rf /etc/puppetlabs/puppet/ssl 2>/dev/null || true
}
trap cleanup EXIT

if $DO_K8S; then
    # Set up port-forwarding so localhost:8141 (CA) and localhost:8140 (master)
    # work identically to the compose setup.
    printf '# Setting up kubectl port-forwards...\n'
    kubectl port-forward svc/puppet-ca     8141:8140 >/dev/null 2>&1 &
    _PF_CA_PID=$!
    kubectl port-forward svc/puppet-master 8140:8140 >/dev/null 2>&1 &
    _PF_MASTER_PID=$!
    sleep 3   # allow port-forwards to establish

    printf '# Waiting for CA (port 8141)'
    for _i in $(seq 1 30); do
        curl -sf "http://localhost:8141/puppet-ca/v1/certificate/ca" >/dev/null 2>&1 && break
        printf '.'; sleep 2
    done
    printf ' OK\n'

    printf '# Waiting for master (port 8140)'
    for _i in $(seq 1 30); do
        curl -sfk "https://localhost:8140/puppet-ca/v1/certificate/ca" >/dev/null 2>&1 && break
        printf '.'; sleep 2
    done
    printf ' OK\n'
fi

if $DO_UP; then
    # Ensure a completely clean start: remove any leftover containers from previous runs.
    printf '# Removing any leftover containers from previous runs...\n'
    for _c in "${_COMPOSE_CONTAINERS[@]}"; do
        "$_ENGINE" rm -f "$_c" 2>/dev/null || true
    done

    printf '# Starting compose stack...\n'
    "${_COMPOSE[@]}" up -d

    printf '# Waiting for CA (port 8141)'
    for _i in $(seq 1 60); do
        curl -sf "http://localhost:8141/puppet-ca/v1/certificate/ca" >/dev/null 2>&1 && break
        printf '.'; sleep 2
    done
    printf ' OK\n'

    # Master must download its cert from the CA and start Apache before it can serve.
    # Use -k here (no CA cert yet); real cert validation happens in Group 2 onwards.
    printf '# Waiting for master (port 8140)'
    for _i in $(seq 1 60); do
        curl -sfk "https://localhost:8140/puppet-ca/v1/certificate/ca" >/dev/null 2>&1 && break
        printf '.'; sleep 2
    done
    printf ' OK\n'
fi

# ── Test counters ──────────────────────────────────────────────────────────────
T=0         # tests run
FAILURES=0  # tests failed

pass() {
    T=$(( T + 1 ))
    printf 'ok %d - %s\n' "$T" "$1"
}

fail() {
    T=$(( T + 1 ))
    FAILURES=$(( FAILURES + 1 ))
    printf 'not ok %d - %s\n' "$T" "$1"
    [ -n "${2:-}" ] && printf '  # %s\n' "$2"
}

# assert_http EXPECTED_CODE DESC [curl-opts...]
assert_http() {
    local exp="$1" desc="$2"
    shift 2
    local got
    got=$(curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null) || true
    if [ "$got" = "$exp" ]; then
        pass "$desc"
    else
        fail "$desc" "expected HTTP $exp, got HTTP $got"
    fi
}

# assert_contains FIXED_STRING DESC [curl-opts...]
assert_contains() {
    local pat="$1" desc="$2"
    shift 2
    local body
    body=$(curl -s "$@" 2>/dev/null) || true
    if grep -qF "$pat" <<< "$body"; then
        pass "$desc"
    else
        fail "$desc" "pattern not found: $pat"
    fi
}

# Run puppet agent --test in the client container; pass extra args (e.g. --waitforcert 30).
# Captures combined stdout+stderr. Call as: OUT=$(run_agent [...]) || EXIT=$?
run_agent() {
    exec_client \
        puppet agent --test \
        --server    puppet.passenger.localdomain \
        --ca_server puppet.passenger.localdomain \
        "$@" 2>&1
}

# Push a fresh CRL from the Go CA into the master container and trigger graceful reload.
refresh_master_crl() {
    local crl
    crl=$(curl -sf "$CA_URL/puppet-ca/v1/certificate_revocation_list/ca" 2>/dev/null) || return 1
    # $() strips trailing newlines; printf '%s\n' restores the required final newline
    printf '%s\n' "$crl" | \
        exec_master_i \
        sh -c 'cat > /etc/puppetlabs/puppet/ssl/ca/ca_crl.pem'
    exec_master kill -USR1 1 2>/dev/null || true
    sleep 3   # allow Apache graceful reload to complete
}

# Attempt an mTLS request using the integ-test (revoked) cert; prints HTTP status code.
# Note: _INTEG_HOST is set when Group 1 runs (after RUN_ID is defined).
curl_revoked() {
    curl -s -o /dev/null -w '%{http_code}' \
        --cacert "$WORK_DIR/ca.pem" \
        --cert   "$WORK_DIR/integ-test.crt" \
        --key    "$WORK_DIR/integ-test.key" \
        --resolve puppet.passenger.localdomain:8140:127.0.0.1 \
        "$MASTER_URL/puppet/v3/node/${_INTEG_HOST}?environment=production" \
        2>/dev/null || true
}

# ── Pre-flight: download CA cert ───────────────────────────────────────────────
printf '\n# Downloading CA cert from %s...\n' "$CA_URL"
if ! curl -sf "$CA_URL/puppet-ca/v1/certificate/ca" \
          -o "$WORK_DIR/ca.pem" 2>/dev/null; then
    printf 'FATAL: Cannot reach CA at %s — is the stack running?\n' "$CA_URL" >&2
    exit 1
fi
printf '# CA cert downloaded to %s/ca.pem\n' "$WORK_DIR"

# ═════════════════════════════════════════════════════════════════════════════
# Group 1 — Go CA direct HTTP (port 8141)
# ═════════════════════════════════════════════════════════════════════════════
printf '\n# Group 1 — Go CA direct HTTP\n'

assert_http 200 "CA cert endpoint returns 200" \
    "$CA_URL/puppet-ca/v1/certificate/ca"

assert_contains "BEGIN CERTIFICATE" "CA cert contains PEM header" \
    "$CA_URL/puppet-ca/v1/certificate/ca"

assert_http 200 "CRL endpoint returns 200" \
    "$CA_URL/puppet-ca/v1/certificate_revocation_list/ca"

assert_contains "BEGIN X509 CRL" "CRL contains PEM header" \
    "$CA_URL/puppet-ca/v1/certificate_revocation_list/ca"

assert_http 404 "Nonexistent cert status returns 404" \
    "$CA_URL/puppet-ca/v1/certificate_status/nonexistent.localdomain"

# Use a unique per-run name so this test never conflicts with a previous run's CA state.
_INTEG_HOST="integ-${RUN_ID}.localdomain"
openssl genrsa -out "$WORK_DIR/integ-test.key" 2048 2>/dev/null || true
[ -f "$WORK_DIR/integ-test.key" ] && chmod 600 "$WORK_DIR/integ-test.key"
openssl req -new \
    -key  "$WORK_DIR/integ-test.key" \
    -subj "/CN=${_INTEG_HOST}" \
    -out  "$WORK_DIR/integ-test.csr" 2>/dev/null || true

_csr_st=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "Content-Type: text/plain" \
    --data-binary @"$WORK_DIR/integ-test.csr" \
    "$CA_URL/puppet-ca/v1/certificate_request/${_INTEG_HOST}") || true
if [[ "$_csr_st" =~ ^2 ]]; then
    pass "CSR submission returns 2xx"
else
    fail "CSR submission returns 2xx" "got HTTP $_csr_st"
fi

sleep 1   # autosign is immediate but give it a moment

_status_body=$(curl -s \
    "$CA_URL/puppet-ca/v1/certificate_status/${_INTEG_HOST}" \
    2>/dev/null) || true
if grep -qF '"state":"signed"' <<< "$_status_body"; then
    pass "Autosigned cert status is 'signed'"
else
    fail "Autosigned cert status is 'signed'" "got: $_status_body"
fi

if curl -sf "$CA_URL/puppet-ca/v1/certificate/${_INTEG_HOST}" \
        -o "$WORK_DIR/integ-test.crt" 2>/dev/null; then
    pass "Signed cert downloadable"
else
    fail "Signed cert downloadable" "curl failed"
fi

if openssl verify -CAfile "$WORK_DIR/ca.pem" \
                  "$WORK_DIR/integ-test.crt" >/dev/null 2>&1; then
    pass "Signed cert verifies against CA"
else
    fail "Signed cert verifies against CA" "openssl verify failed"
fi

_revoke_st=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "Content-Type: application/json" \
    -d '{"desired_state":"revoked"}' \
    "$CA_URL/puppet-ca/v1/certificate_status/${_INTEG_HOST}") || true
if [[ "$_revoke_st" =~ ^2 ]]; then
    pass "Cert revocation returns 2xx"
else
    fail "Cert revocation returns 2xx" "got HTTP $_revoke_st"
fi

_revoked_body=$(curl -s \
    "$CA_URL/puppet-ca/v1/certificate_status/${_INTEG_HOST}" \
    2>/dev/null) || true
if grep -qF '"state":"revoked"' <<< "$_revoked_body"; then
    pass "Revoked cert status is 'revoked'"
else
    fail "Revoked cert status is 'revoked'" "got: $_revoked_body"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Group 2 — CA proxy through Puppet master (HTTPS port 8140)
# ═════════════════════════════════════════════════════════════════════════════
printf '\n# Group 2 — CA proxy through Puppet master\n'

_PROXY=(--cacert "$WORK_DIR/ca.pem"
        --resolve puppet.passenger.localdomain:8140:127.0.0.1)

assert_http 200 "CA cert via proxy returns 200" \
    "${_PROXY[@]}" "$MASTER_URL/puppet-ca/v1/certificate/ca"

assert_contains "BEGIN CERTIFICATE" "CA cert via proxy contains PEM header" \
    "${_PROXY[@]}" "$MASTER_URL/puppet-ca/v1/certificate/ca"

assert_http 200 "CRL via proxy returns 200" \
    "${_PROXY[@]}" "$MASTER_URL/puppet-ca/v1/certificate_revocation_list/ca"

assert_contains "BEGIN X509 CRL" "CRL via proxy contains PEM header" \
    "${_PROXY[@]}" "$MASTER_URL/puppet-ca/v1/certificate_revocation_list/ca"

# Use a unique per-run name so this test never conflicts with a previous run's CA state.
_PROXY_HOST="proxy-${RUN_ID}.localdomain"
openssl genrsa -out "$WORK_DIR/proxy-test.key" 2048 2>/dev/null || true
[ -f "$WORK_DIR/proxy-test.key" ] && chmod 600 "$WORK_DIR/proxy-test.key"
openssl req -new \
    -key  "$WORK_DIR/proxy-test.key" \
    -subj "/CN=${_PROXY_HOST}" \
    -out  "$WORK_DIR/proxy-test.csr" 2>/dev/null || true

_proxy_st=$(curl -s -o /dev/null -w '%{http_code}' \
    "${_PROXY[@]}" \
    -X PUT \
    -H "Content-Type: text/plain" \
    --data-binary @"$WORK_DIR/proxy-test.csr" \
    "$MASTER_URL/puppet-ca/v1/certificate_request/${_PROXY_HOST}") || true
if [[ "$_proxy_st" =~ ^2 ]]; then
    pass "CSR via proxy returns 2xx"
else
    fail "CSR via proxy returns 2xx" "got HTTP $_proxy_st"
fi

sleep 1

if curl -sf "${_PROXY[@]}" \
        "$MASTER_URL/puppet-ca/v1/certificate/${_PROXY_HOST}" \
        -o "$WORK_DIR/proxy-test.crt" 2>/dev/null; then
    pass "Autosigned cert downloadable via proxy"
else
    fail "Autosigned cert downloadable via proxy" "curl failed"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Group 3 — Full puppet agent end-to-end
# ═════════════════════════════════════════════════════════════════════════════
printf '\n# Group 3 — Full puppet agent end-to-end\n'

# On repeated runs against the same stack, a prior cycle may have left
# client.localdomain in "signed" state (test 33's agent re-registered after
# a cert/key mismatch caused by the failed Group 3 in that run). Revoke it
# now so signing.go will permit a fresh CSR when the agent bootstraps below.
_cld_state=$(curl -s \
    "$CA_URL/puppet-ca/v1/certificate_status/client.localdomain" \
    2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" \
    2>/dev/null || true)
if [ "$_cld_state" = "signed" ]; then
    printf '# Pre-group-3: revoking stale client.localdomain to allow re-registration\n'
    curl -s -X PUT -H "Content-Type: application/json" \
        -d '{"desired_state":"revoked"}' \
        "$CA_URL/puppet-ca/v1/certificate_status/client.localdomain" \
        >/dev/null 2>&1 || true
fi

# Clean SSL dir so the agent bootstraps fresh
exec_client rm -rf /etc/puppetlabs/puppet/ssl 2>/dev/null || true

AGENT_EXIT=0
AGENT_OUT=$(run_agent --waitforcert 30) || AGENT_EXIT=$?

if [[ "$AGENT_EXIT" =~ ^(0|2)$ ]]; then
    pass "Puppet agent exits 0 or 2"
else
    fail "Puppet agent exits 0 or 2" "exit code: $AGENT_EXIT"
fi

if grep -qiE "crl|revocation" <<< "$AGENT_OUT"; then
    pass "Agent output references CRL"
else
    fail "Agent output references CRL" "no CRL mention in output"
fi

if grep -qi "certificate" <<< "$AGENT_OUT"; then
    pass "Agent output references certificate"
else
    fail "Agent output references certificate" "no certificate mention in output"
fi

if grep -qi "Applied catalog" <<< "$AGENT_OUT"; then
    pass "Agent output contains 'Applied catalog'"
else
    fail "Agent output contains 'Applied catalog'" "not found in output"
fi

if grep -qiE "SSL_read|certificate revoked" <<< "$AGENT_OUT"; then
    fail "Agent output contains no SSL errors" "found SSL/revocation error in output"
else
    pass "Agent output contains no SSL errors"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Group 4 — Individual master mTLS endpoints
# ═════════════════════════════════════════════════════════════════════════════
printf '\n# Group 4 — Individual master mTLS endpoints\n'

copy_from_client \
    /etc/puppetlabs/puppet/ssl/certs/client.localdomain.pem \
    "$WORK_DIR/client.crt" 2>/dev/null || true
copy_from_client \
    /etc/puppetlabs/puppet/ssl/private_keys/client.localdomain.pem \
    "$WORK_DIR/client.key" 2>/dev/null || true
# Private key must not be world-readable
[ -f "$WORK_DIR/client.key" ] && chmod 600 "$WORK_DIR/client.key"

if [[ -f "$WORK_DIR/client.crt" && -f "$WORK_DIR/client.key" ]]; then
    _MTLS=(--cacert  "$WORK_DIR/ca.pem"
           --cert    "$WORK_DIR/client.crt"
           --key     "$WORK_DIR/client.key"
           --resolve puppet.passenger.localdomain:8140:127.0.0.1)

    assert_http 200 "Node endpoint returns 200" \
        "${_MTLS[@]}" \
        "$MASTER_URL/puppet/v3/node/client.localdomain?environment=production"

    assert_contains '"name"' "Node endpoint contains 'name'" \
        "${_MTLS[@]}" \
        "$MASTER_URL/puppet/v3/node/client.localdomain?environment=production"

    assert_http 200 "Catalog endpoint returns 200" \
        "${_MTLS[@]}" \
        "$MASTER_URL/puppet/v3/catalog/client.localdomain?environment=production"

    assert_contains '"name"' "Catalog response contains 'name'" \
        "${_MTLS[@]}" \
        "$MASTER_URL/puppet/v3/catalog/client.localdomain?environment=production"

    assert_http 200 "File metadatas endpoint returns 200" \
        "${_MTLS[@]}" \
        "$MASTER_URL/puppet/v3/file_metadatas/plugins?recurse=false&links=manage&checksum_type=sha256&source_permissions=ignore&environment=production"

    AGENT2_EXIT=0
    _AGENT2_OUT=$(run_agent) || AGENT2_EXIT=$?
    if [[ "$AGENT2_EXIT" =~ ^(0|2)$ ]]; then
        pass "Second agent run (idempotency) exits 0 or 2"
    else
        fail "Second agent run (idempotency) exits 0 or 2" "exit code: $AGENT2_EXIT"
    fi
else
    for _desc in \
        "Node endpoint returns 200" \
        "Node endpoint contains 'name'" \
        "Catalog endpoint returns 200" \
        "Catalog response contains 'name'" \
        "File metadatas endpoint returns 200" \
        "Second agent run (idempotency) exits 0 or 2"
    do
        fail "$_desc" "could not copy client cert from container"
    done
fi

# ═════════════════════════════════════════════════════════════════════════════
# Group 5 — Certificate revocation enforcement
# ═════════════════════════════════════════════════════════════════════════════
printf '\n# Group 5 — Certificate revocation enforcement\n'

if [[ -f "$WORK_DIR/integ-test.crt" && -f "$WORK_DIR/integ-test.key" ]]; then
    pass "Revoked cert/key available for enforcement tests"

    # Refresh master CRL so it includes the integ-test revocation from Group 1
    refresh_master_crl || true

    _st=$(curl_revoked)
    if [[ "$_st" = "000" ]] || [[ "$_st" =~ ^4 ]]; then
        pass "Revoked cert request is rejected (SSL error or 4xx)"
    else
        fail "Revoked cert request is rejected (SSL error or 4xx)" "got HTTP $_st"
    fi

    # Explicit second refresh, then verify still rejected (plan test 27)
    refresh_master_crl || true
    _st=$(curl_revoked)
    if [[ "$_st" = "000" ]] || [[ "$_st" =~ ^4 ]]; then
        pass "Revoked cert still rejected after explicit CRL refresh"
    else
        fail "Revoked cert still rejected after explicit CRL refresh" "got HTTP $_st"
    fi
else
    fail "Revoked cert/key available for enforcement tests" \
         "integ-test files not found (Group 1 may have failed)"
    fail "Revoked cert request is rejected (SSL error or 4xx)" "integ-test cert unavailable"
    fail "Revoked cert still rejected after explicit CRL refresh" "integ-test cert unavailable"
fi

# Revoke client.localdomain (the cert used by the puppet-client container)
_client_revoke_st=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "Content-Type: application/json" \
    -d '{"desired_state":"revoked"}' \
    "$CA_URL/puppet-ca/v1/certificate_status/client.localdomain") || true
if [[ "$_client_revoke_st" =~ ^2 ]]; then
    pass "Client cert revocation returns 2xx"
else
    fail "Client cert revocation returns 2xx" "got HTTP $_client_revoke_st"
fi

# Refresh master CRL to include the newly revoked client cert
refresh_master_crl || true

# Run puppet agent — master should reject the revoked client cert
AGENT3_EXIT=0
AGENT3_OUT=$(run_agent) || AGENT3_EXIT=$?

if grep -qiE "revoked|SSL_read|certificate verify" <<< "$AGENT3_OUT"; then
    pass "Agent run with revoked cert shows revocation error"
else
    fail "Agent run with revoked cert shows revocation error" \
         "exit=$AGENT3_EXIT; last lines: $(tail -3 <<< "$AGENT3_OUT" | tr '\n' ' ')"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Teardown: restore stack to a clean state for re-use
# ═════════════════════════════════════════════════════════════════════════════
printf '\n# Teardown\n'

# Revoke any per-run test certs still in "signed" state.
# (integ-${RUN_ID} is already revoked by test 10; proxy-${RUN_ID} is not.)
for _td_host in "${_PROXY_HOST:-}" "${_INTEG_HOST:-}"; do
    [[ -z "$_td_host" ]] && continue
    _td_state=$(curl -s \
        "$CA_URL/puppet-ca/v1/certificate_status/${_td_host}" \
        2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" \
        2>/dev/null || true)
    if [[ "$_td_state" = "signed" ]]; then
        curl -sf -o /dev/null \
            -X PUT -H "Content-Type: application/json" \
            -d '{"desired_state":"revoked"}' \
            "$CA_URL/puppet-ca/v1/certificate_status/${_td_host}" \
            2>/dev/null || true
        printf '#   revoked stale cert: %s\n' "$_td_host"
    fi
done

# Wipe the client SSL dir so the container can bootstrap fresh on next use.
# The test suite leaves it with a revoked cert after Group 5.
if exec_client rm -rf /etc/puppetlabs/puppet/ssl 2>/dev/null; then
    printf '#   client SSL dir cleaned\n'
fi

# Push the final CRL to the master so its revocation list is current.
if refresh_master_crl 2>/dev/null; then
    printf '#   master CRL refreshed\n'
fi

# ═════════════════════════════════════════════════════════════════════════════
# Results
# ═════════════════════════════════════════════════════════════════════════════
printf '\n# Results: %d/%d passed, %d failed\n' \
    $(( T - FAILURES )) "$T" "$FAILURES"

[ "$FAILURES" -eq 0 ]
