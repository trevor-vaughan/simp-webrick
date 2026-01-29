#!/bin/bash
# Entrypoint for the Puppet master container.
# Bootstraps the master's TLS certificate from the Go CA service,
# then starts Apache + Passenger.

set -euo pipefail

export PATH=/opt/puppetlabs/puppet/bin:$PATH

CA_HOST="${PUPPET_CA_HOST:-puppet-ca}"
CA_PORT="${PUPPET_CA_PORT:-8140}"
CA_URL="http://${CA_HOST}:${CA_PORT}"

PUPPET_SSL=/etc/puppetlabs/puppet/ssl

# PUPPET_FQDN may be injected by Kubernetes deployments where the pod's
# kernel hostname (facter fqdn) differs from the desired SSL cert CN.
fqdn=${PUPPET_FQDN:-$(facter fqdn 2>/dev/null || hostname -f)}

echo "=== Puppet Master Bootstrap ==="
echo "  FQDN : ${fqdn}"
echo "  CA   : ${CA_URL}"

# ── Directory structure ──────────────────────────────────────────────────────
mkdir -p "${PUPPET_SSL}/ca" \
         "${PUPPET_SSL}/certs" \
         "${PUPPET_SSL}/private_keys" \
         "${PUPPET_SSL}/certificate_requests" \
         "${PUPPET_SSL}/public_keys"

# ── Wait for Go CA ───────────────────────────────────────────────────────────
echo "Waiting for Go CA..."
until curl -sf "${CA_URL}/puppet-ca/v1/certificate/ca" > /dev/null 2>&1; do
    sleep 2
done
echo "Go CA is ready."

# ── Download CA cert + CRL ───────────────────────────────────────────────────
curl -sf "${CA_URL}/puppet-ca/v1/certificate/ca" \
     -o "${PUPPET_SSL}/ca/ca_crt.pem"
echo "CA cert downloaded."

curl -sf "${CA_URL}/puppet-ca/v1/certificate_revocation_list/ca" \
     -o "${PUPPET_SSL}/ca/ca_crl.pem"
echo "CRL downloaded."

# ── Generate server key + signed cert (idempotent) ───────────────────────────
if [ ! -f "${PUPPET_SSL}/certs/${fqdn}.pem" ]; then
    echo "Generating 4096-bit RSA key for ${fqdn}..."
    openssl genrsa -out "${PUPPET_SSL}/private_keys/${fqdn}.pem" 4096 2>/dev/null

    echo "Creating CSR..."
    openssl req -new \
        -key "${PUPPET_SSL}/private_keys/${fqdn}.pem" \
        -subj "/CN=${fqdn}" \
        -out "/tmp/${fqdn}.csr"

    echo "Submitting CSR to Go CA..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT \
        -H "Content-Type: text/plain" \
        --data-binary @/tmp/${fqdn}.csr \
        "${CA_URL}/puppet-ca/v1/certificate_request/${fqdn}")
    echo "CSR submission HTTP status: ${HTTP_STATUS}"

    echo "Waiting for cert to be signed (autosign should be immediate)..."
    for i in $(seq 1 30); do
        if curl -sf "${CA_URL}/puppet-ca/v1/certificate/${fqdn}" \
                -o "${PUPPET_SSL}/certs/${fqdn}.pem" 2>/dev/null; then
            echo "Server cert obtained for ${fqdn}."
            break
        fi
        sleep 2
    done

    if [ ! -f "${PUPPET_SSL}/certs/${fqdn}.pem" ]; then
        echo "ERROR: Timed out waiting for cert to be signed." >&2
        exit 1
    fi
else
    echo "Server cert already exists, skipping generation."
fi

# ── Permissions ──────────────────────────────────────────────────────────────
chmod 640 "${PUPPET_SSL}/private_keys/${fqdn}.pem"
chmod 644 "${PUPPET_SSL}/certs/${fqdn}.pem" \
           "${PUPPET_SSL}/ca/ca_crt.pem" \
           "${PUPPET_SSL}/ca/ca_crl.pem"

# ── Configure Apache ──────────────────────────────────────────────────────────
sed -i "s/__FQDN__/${fqdn}/g" /etc/httpd/conf.d/puppet_apache.conf

# ── Background CRL refresh ────────────────────────────────────────────────────
# Refresh the CRL from the Go CA based on the CRL's own nextUpdate field:
# sleep for half the remaining validity period so we always have a fresh CRL
# well before expiry, then gracefully reload Apache to pick up the new file.
crl_sleep_secs() {
    local NEXT_UPDATE NEXT_TS NOW_TS SECS_UNTIL HALF_LIFE
    NEXT_UPDATE=$(openssl crl -in "${PUPPET_SSL}/ca/ca_crl.pem" \
        -noout -nextupdate 2>/dev/null | sed 's/nextUpdate=//')
    if [ -z "${NEXT_UPDATE}" ]; then
        echo 3600; return
    fi
    NEXT_TS=$(date -d "${NEXT_UPDATE}" +%s 2>/dev/null) || { echo 3600; return; }
    NOW_TS=$(date +%s)
    SECS_UNTIL=$(( NEXT_TS - NOW_TS ))
    if [ "${SECS_UNTIL}" -le 0 ]; then
        echo 60; return   # Already expired – retry quickly
    fi
    HALF_LIFE=$(( SECS_UNTIL / 2 ))
    # Clamp: at least 60 s, at most 86400 s (1 day)
    if   [ "${HALF_LIFE}" -lt 60    ]; then echo 60
    elif [ "${HALF_LIFE}" -gt 86400 ]; then echo 86400
    else echo "${HALF_LIFE}"
    fi
}
(
    while true; do
        sleep "$(crl_sleep_secs)"
        NEW_CRL=$(curl -sf "${CA_URL}/puppet-ca/v1/certificate_revocation_list/ca" 2>/dev/null || true)
        if [ -n "${NEW_CRL}" ]; then
            echo "${NEW_CRL}" > "${PUPPET_SSL}/ca/ca_crl.pem"
            # USR1 triggers a graceful restart (drains active connections
            # before reloading config).  apachectl requires systemd which
            # is not available inside a container.
            kill -USR1 1 2>/dev/null || true
            echo "CRL refreshed at $(date -u +%FT%TZ)"
        fi
    done
) &

echo "Starting Apache..."
exec /usr/sbin/httpd -D FOREGROUND
