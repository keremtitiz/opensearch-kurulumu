#!/usr/bin/env bash
# node3 kurulumu. hazirlik.sh'ten sonra ve node1.sh paketi gönderdikten sonra çalıştırılır.
#
#   - node1'in hazırladığı paketi doğrular (SHA256, config.env aynı mı)
#   - node3 sertifikalarını, root CA'yı ve internal_users.yml'yi yerleştirir
#   - opensearch.yml ve jvm.options'ı yazar, OpenSearch'ü başlatır
#   - cluster'a katılmasını bekler, ardından bootstrap ayarını kapatır
#
# Kullanım: ./node3.sh [paket]
#   Varsayılan paket: <BUNDLE_TARGET_DIR>/opensearch-bundle-<NODE3_NAME>.tar.gz
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
run_member_node 3 "${1:-}"
