#!/usr/bin/env bash
# Builds and (re)starts the dev backend on the VM. Cross-compiles with Zig here,
# sends only the binary, the Dockerfile and the compose file, and builds the
# image on the VM (no local Docker needed; no .env or key leaves this machine).
# Usage: backend-exp/deploy/deploy.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="${EVERYAI_VM:-ttt-server}"
zone="${EVERYAI_ZONE:-us-east1-b}"
project="${EVERYAI_PROJECT:-ttt-ultimate-b7097a}"
host="${EVERYAI_HOSTNAME:-everyai.136-108-68-64.sslip.io}"
tag="everyai-backend:0.1.0-dev-nonsigned"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
(cd "$here/.." && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix "$out")
cp "$out/bin/everyai-backend-exp" "$here/Dockerfile" "$here/docker-compose.yml" \
  "$here/everyai-cert-reload.service" "$here/everyai-cert-reload.timer" "$out/"
printf 'HOSTNAME=%s\n' "$host" >"$out/.env"

ssh_vm() { gcloud compute ssh "$vm" --zone "$zone" --project "$project" --command "$1"; }
ssh_vm 'rm -rf /tmp/everyai-build && mkdir -p /tmp/everyai-build'
gcloud compute scp --zone "$zone" --project "$project" \
  "$out/everyai-backend-exp" "$out/Dockerfile" "$out/docker-compose.yml" "$out/.env" \
  "$out/everyai-cert-reload.service" "$out/everyai-cert-reload.timer" "$vm:/tmp/everyai-build/"
ssh_vm "set -e
cd /tmp/everyai-build
sudo docker build -t $tag -f Dockerfile .
sudo mkdir -p /opt/everyai
sudo cp docker-compose.yml .env /opt/everyai/
sudo cp everyai-cert-reload.service everyai-cert-reload.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now everyai-cert-reload.timer
cd /opt/everyai && sudo docker compose up -d --force-recreate
rm -rf /tmp/everyai-build"
echo "deployed: https://$host:8443"
