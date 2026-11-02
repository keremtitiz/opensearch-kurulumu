#!/usr/bin/env bash
# Kurulum script'lerini Docker'da, RHEL 10 + systemd konteynerlerinde çalıştırır (yerel deneme için).
# Script'ler değiştirilmez; hazirlik.sh, node1-5.sh ve dashboard1/2.sh README'deki sırayla çalışır.
#
#   - RPM'leri rpm/ altına indirir, şifreleri .env'ye üretir, config.env'yi ana config.env'den türetir
#   - 7 sunucuyu ve localhost köprüsünü başlatır, kurulumu yapar (loglar: logs/)
#   - Kurulum yapılmışsa yalnızca konteynerleri başlatır
#
# Kullanım: ./up.sh
# Durdurma: docker compose stop           (veri korunur, ./up.sh ile devam edilir)
# Silme   : docker compose down -v        (tüm kurulum silinir)
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"
cd "$SCRIPT_DIR"

NODES="node1 node2 node3 node4 node5"
DASHBOARDS="dashboard1 dashboard2"
ARTIFACTS=https://artifacts.opensearch.org

write_config() {
  local kv tmp=config.env.tmp
  cp ../config.env "$tmp"
  for kv in NODE1_IP=172.28.50.11 NODE2_IP=172.28.50.12 NODE3_IP=172.28.50.13 \
            NODE4_IP=172.28.50.14 NODE5_IP=172.28.50.15 \
            DASHBOARD1_IP=172.28.50.21 DASHBOARD2_IP=172.28.50.22 \
            DASHBOARDS_FQDN=localhost DASHBOARDS_EXTRA_SAN=IP:127.0.0.1 HAPROXY_VIP=172.28.50.40 \
            HEAP_SIZE=512m DISTRIBUTE_WITH_SCP=no BUNDLE_DIR=/bundle BUNDLE_TARGET_DIR=/bundle; do
    sed -i.bak -E "s|^${kv%%=*}=.*|${kv%%=*}=\"${kv#*=}\"|" "$tmp"
  done
  rm -f "$tmp.bak"
  # Aynıysa dokunulmaz: çalışan konteynerler dosyayı bind mount ile görür
  if cmp -s "$tmp" config.env; then
    rm -f "$tmp"
  else
    mv "$tmp" config.env
    ok "config.env üretildi"
  fi
}

download_rpms() {
  local os_version arch f
  os_version=$(. ./config.env && echo "$OS_VERSION")
  case "$(docker info --format '{{.Architecture}}')" in
    aarch64|arm64) arch=arm64 ;;
    *)             arch=x64 ;;
  esac
  mkdir -p rpm
  for f in "bundle/opensearch/$os_version/opensearch-$os_version-linux-$arch.rpm" \
           "bundle/opensearch-dashboards/$os_version/opensearch-dashboards-$os_version-linux-$arch.rpm"; do
    [ -s "rpm/$(basename "$f").sig" ] && continue
    info "İndiriliyor: $(basename "$f")"
    curl -fL --retry 3 -C - -o "rpm/$(basename "$f")" "$ARTIFACTS/releases/$f"
    curl -fsSL --retry 3 -o "rpm/$(basename "$f").sig" "$ARTIFACTS/releases/$f.sig"
  done
  [ -s rpm/opensearch-release.pgp ] \
    || curl -fsSL --retry 3 -o rpm/opensearch-release.pgp "$ARTIFACTS/publickeys/opensearch-release.pgp"
  ok "RPM'ler hazır (rpm/)"
}

load_passwords() {
  if [ ! -s .env ]; then
    ( umask 077
      printf 'ADMIN_PASSWORD=%s\nKIBANASERVER_PASSWORD=%s\n' \
        "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > .env )
    ok "Şifreler üretildi (.env)"
  fi
  set -a; . ./.env; set +a
}

# $1 servis, $2... komut; çıktı logs/<servis>-<script>.log dosyasına da yazılır
run_on() {
  local svc=$1 log="logs/$1-$2.log"
  shift
  docker compose exec -T -e ADMIN_PASSWORD -e KIBANASERVER_PASSWORD -w /root/opensearch-kurulum \
    "$svc" "./$1" "${@:2}" > "$log" 2>&1
}

# Arka plandaki işlerin (svc:pid) hepsini bekler; biri başarısızsa adını yazıp durur
wait_all() {
  local job failed=""
  for job in "$@"; do
    wait "${job#*:}" || failed+=" ${job%%:*}"
  done
  [ -z "$failed" ] || die "Başarısız:$failed (logs/ altına bakın)"
}

wait_systemd() {
  local svc state t
  for svc in $NODES $DASHBOARDS; do
    t=0
    until state=$(docker compose exec -T "$svc" systemctl is-system-running 2>/dev/null || true)
          [ "$state" = running ] || [ "$state" = degraded ]; do
      [ "$t" -lt 120 ] || die "$svc: systemd açılmadı (durum: ${state:-?})"
      sleep 2; t=$((t + 2))
    done
  done
  ok "7 sunucuda systemd çalışıyor"
}

install_all() {
  local svc jobs
  mkdir -p logs

  step "1) hazirlik.sh (7 sunucu, RPM kurulumu birkaç dakika sürer)"
  jobs=()
  for svc in $NODES $DASHBOARDS; do
    run_on "$svc" hazirlik.sh & jobs+=("$svc:$!")
  done
  wait_all "${jobs[@]}"
  ok "Hazırlık tamam"

  step "2) node1.sh certs"
  run_on node1 node1.sh certs || die "node1.sh certs başarısız (logs/node1-node1.sh.log)"
  mv logs/node1-node1.sh.log logs/node1-certs.log
  ok "Sertifikalar ve paketler hazır"

  step "3) node1.sh opensearch ve node2-5"
  # node1.sh tüm node'ları bekler; önce diğerleri beklenir ki biri düşerse hemen durulsun
  run_on node1 node1.sh opensearch & NODE1_PID=$!
  trap 'kill "$NODE1_PID" 2>/dev/null || true' EXIT
  jobs=()
  for svc in node2 node3 node4 node5; do
    run_on "$svc" "$svc.sh" & jobs+=("$svc:$!")
  done
  wait_all "${jobs[@]}"
  wait_all "node1:$NODE1_PID"
  trap - EXIT
  ok "Cluster 5 node, green"

  step "4) dashboard1.sh, dashboard2.sh (sırayla)"
  for svc in $DASHBOARDS; do
    run_on "$svc" "$svc.sh" || die "$svc.sh başarısız (logs/$svc-$svc.sh.log)"
    grep -E '^Sonuç:' "logs/$svc-$svc.sh.log" | sed "s/^/    $svc: /"
  done
}

main() {
  step "Hazırlık"
  write_config
  download_rpms
  load_passwords

  step "Konteynerler"
  # --build yok: imaj yeniden üretilirse konteynerler, içindeki kurulum ve veriyle silinir
  docker compose up -d
  wait_systemd

  if docker compose exec -T dashboard2 systemctl is-enabled keepalived >/dev/null 2>&1; then
    info "Kurulum daha önce yapılmış, yalnızca başlatıldı"
  else
    install_all
  fi

  docker compose cp node1:/root/opensearch-certs/root-ca.pem root-ca.pem >/dev/null 2>&1
  step "Hazır"
  info "Dashboards : https://localhost:8443 (kullanıcı: admin, şifre: docker/.env)"
  info "OpenSearch : https://localhost:9200"
  info "Root CA    : docker/root-ca.pem"
}

main "$@"
