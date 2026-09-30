#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d)
container_id=
cleanup() {
    if [[ -n "$container_id" ]]; then docker logs "$container_id"; docker rm -f "$container_id" >/dev/null; fi
    rm -rf "$fixture_dir"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/id"
docker build -t tokentick-ssh-test Tests/Fixtures/ssh
container_id=$(docker run -d --rm -p 127.0.0.1::22 tokentick-ssh-test)
docker cp "$fixture_dir/id.pub" "$container_id:/root/.ssh/authorized_keys" >/dev/null
docker exec "$container_id" chown root:root /root/.ssh/authorized_keys
docker exec "$container_id" chmod 600 /root/.ssh/authorized_keys
port=$(docker port "$container_id" 22/tcp | sed 's/.*://')
docker exec "$container_id" cat /etc/ssh/ssh_host_ed25519_key.pub > "$fixture_dir/host.pub"
printf 'tokentick-fixture %s\n' "$(cat "$fixture_dir/host.pub")" > "$fixture_dir/known_hosts"
cat > "$fixture_dir/config" <<CONFIG
Host fixture
    HostName 127.0.0.1
    Port $port
    User root
    IdentityFile $fixture_dir/id
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile $fixture_dir/known_hosts
    HostKeyAlias tokentick-fixture
    StrictHostKeyChecking yes
    BatchMode yes
CONFIG
TOKENTICK_TEST_SSH_CONFIG="$fixture_dir/config" swift test --filter SSHIntegrationTests
