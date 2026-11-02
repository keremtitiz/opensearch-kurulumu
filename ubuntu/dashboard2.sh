#!/usr/bin/env bash
# dashboard2 kurulumu (OpenSearch Dashboards). hazirlik.sh'ten sonra ve node1.sh cluster'ı
# kurup paketi gönderdikten sonra çalıştırılır. İki dashboard sunucusu sırayla kurulur.
#
#   - node1'in hazırladığı paketi doğrular (SHA256, config.env aynı mı)
#   - root CA'yı ve Dashboards sertifikasını yerleştirir (kurum sertifikası ya da node1'in ürettiği)
#   - opensearch_dashboards.yml'yi yazar (5 node, ortak oturum anahtarı), HTTPS ile başlatır
#   - HAProxy'yi (Dashboards ve OpenSearch için) ve keepalived'ı (sanal IP) yapılandırıp başlatır
#   - uçtan uca test; diğer dashboard çalışıyorsa oturumun orada da geçerli olduğunu doğrular
#
# Kullanım: ./dashboard2.sh [paket]
#   Varsayılan paket: <BUNDLE_TARGET_DIR>/opensearch-bundle-<DASHBOARD2_NAME>.tar.gz
#           ./dashboard2.sh test    yalnızca test (kibanaserver testi için KIBANASERVER_PASSWORD verilebilir)
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
run_dashboard_node 2 "${1:-}"
