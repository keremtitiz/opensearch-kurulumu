#!/usr/bin/env bash
# node1 kurulumu: sertifikalar, kullanıcı şifreleri, node2-5 ve dashboard1/2 paketleri,
# node1 OpenSearch. hazirlik.sh'ten sonra çalıştırılır. Dashboards bu sunucuya kurulmaz;
# cluster green olduktan sonra dashboard1.sh ve dashboard2.sh ile kendi sunucularına kurulur.
#
# Kullanım: ./node1.sh [aşama]
#   all         (varsayılan) aşağıdaki aşamaların hepsi, sırayla
#   certs       root CA, admin, node ve Dashboards sertifikaları; Dashboards oturum
#               anahtarı; admin ve kibanaserver şifreleri; paketler ve scp ile dağıtım
#   opensearch  node1'de OpenSearch'ü yapılandırır, başlatır, 5 node'un katılmasını bekler
#
# Şifreler sorulur; otomasyon için ADMIN_PASSWORD ve KIBANASERVER_PASSWORD ortam
# değişkenleriyle de verilebilir. Tekrar çalıştırılabilir: mevcut CA, sertifikalar ve
# internal_users.yml yeniden kullanılır.
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# =============================================================================
# Sertifika yardımcıları (CERT_WORKDIR içinde çalışır)
# =============================================================================

gen_key() {
  local old
  old=$(umask); umask 077
  run_openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$KEY_BITS" -out "$1"
  umask "$old"
}

subject_dn() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//'; }

# $1 dosya adı, $2 subject, $3 extendedKeyUsage, $4 SAN (boş olabilir).
# Aynı parametrelerle üretilmiş ve CA ile doğrulanan sertifika varsa yeniden kullanılır.
sign_cert() {
  local name=$1 subj=$2 eku=$3 san=$4 params
  params=$(printf 'subject=%s\nsan=%s\neku=%s\ndays=%s\nbits=%s' "$subj" "$san" "$eku" "$CERT_DAYS" "$KEY_BITS")
  if [ -s "$name.pem" ] && [ -s "$name-key.pem" ] \
     && [ "$(cat "$name.params" 2>/dev/null || true)" = "$params" ] \
     && openssl verify -CAfile root-ca.pem "$name.pem" >/dev/null 2>&1; then
    info "$name.pem mevcut, yeniden kullanılıyor"
    return 0
  fi
  gen_key "$name-key.pem"
  run_openssl req -new -key "$name-key.pem" -subj "$subj" -out "$name.csr"
  {
    echo "basicConstraints = critical, CA:FALSE"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = $eku"
    echo "subjectKeyIdentifier = hash"
    echo "authorityKeyIdentifier = keyid, issuer"
    if [ -n "$san" ]; then echo "subjectAltName = $san"; fi
  } > "$name.ext"
  run_openssl x509 -req -in "$name.csr" -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial \
    -sha256 -days "$CERT_DAYS" -extfile "$name.ext" -out "$name.pem"
  rm -f "$name.csr" "$name.ext"
  printf '%s\n' "$params" > "$name.params"
  ok "$name.pem üretildi${san:+ (SAN: $san)}"
}

# self modda dashboard sunucusu $1'in sertifika SAN'ı: HAProxy dışarıya bu sertifikayı gösterdiği
# için ortak adres ve sanal IP, ardından HAProxy'nin doğrudan erişimi ve teşhis için sunucunun adı ve IP'si
dash_sans() {
  local name ip s
  name=$(dash_name "$1"); ip=$(dash_ip "$1")
  if valid_ip "$DASHBOARDS_FQDN"; then s="IP:$DASHBOARDS_FQDN"; else s="DNS:$DASHBOARDS_FQDN"; fi
  if [ "$DASHBOARDS_FQDN" != "$HAPROXY_VIP" ]; then s+=",IP:$HAPROXY_VIP"; fi
  s+=",DNS:$name,IP:$ip"
  if [ -n "$DASHBOARDS_EXTRA_SAN" ]; then s+=",$DASHBOARDS_EXTRA_SAN"; fi
  printf '%s' "$s"
}

# =============================================================================
# REST yardımcıları
# =============================================================================

# node1'deki admin sertifikasıyla REST çağrısı (şifre gerekmez). $1 yol, $2 zaman aşımı (sn)
os_admin_curl() {
  curl -sS --max-time "${2:-15}" --cacert "$OS_CONF/root-ca.pem" \
    --cert "$OS_CONF/admin.pem" --key "$OS_CONF/admin-key.pem" \
    "https://$NODE1_NAME:9200$1" 2>/dev/null || true
}

wait_cluster_green() {
  local body n st msg last="" end=$((SECONDS + CLUSTER_WAIT_TIMEOUT))
  while :; do
    body=$(os_admin_curl "/_cluster/health?wait_for_nodes=$NODE_COUNT&wait_for_status=green&timeout=20s" 30)
    if grep -q '^Unauthorized' <<<"$body"; then
      die "admin sertifikası REST'te kabul edilmedi; opensearch.yml'deki admin_dn ile admin.pem DN'sini karşılaştırın"
    fi
    n=$(json_num number_of_nodes "$body"); st=$(json_str status "$body")
    if [ "${n:-0}" -ge "$NODE_COUNT" ] && [ "$st" = green ]; then
      ok "Cluster hazır: $n node, durum green"
      return 0
    fi
    msg="cluster: ${n:-?}/$NODE_COUNT node, durum ${st:-?}"
    if [ "$msg" != "$last" ]; then info "$(date +%T) $msg"; last=$msg; fi
    if [ $SECONDS -ge "$end" ]; then
      os_admin_curl "/_cat/nodes?v" | sed 's/^/      /'
      die "Cluster $CLUSTER_WAIT_TIMEOUT saniyede $NODE_COUNT node / green olmadı"
    fi
    sleep 5
  done
}

show_node_paths() {
  local body
  body=$(os_admin_curl "/_nodes/settings?filter_path=nodes.*.name,nodes.*.settings.path")
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import json, sys
nodes = json.load(sys.stdin).get("nodes", {}).values()
for n in sorted(nodes, key=lambda x: x.get("name", "")):
    p = n.get("settings", {}).get("path", {})
    data = p.get("data")
    if isinstance(data, list):
        data = ",".join(data)
    print("      %-15s data=%s  logs=%s" % (n.get("name"), data, p.get("logs")))
' <<<"$body" || info "$body"
  else
    info "$body"
  fi
}

# =============================================================================
# Aşamalar
# =============================================================================

phase_certs() {
  local i name f old names=(admin)
  step "Sertifikalar: $CERT_WORKDIR"
  install -d -m 700 "$CERT_WORKDIR"
  cd "$CERT_WORKDIR"

  if [ -s root-ca.pem ] && [ -s root-ca-key.pem ]; then
    info "Root CA mevcut, yeniden kullanılıyor ($(subject_dn root-ca.pem))"
  else
    gen_key root-ca-key.pem
    cat > ca.cnf <<'EOF'
[ req ]
distinguished_name = req_dn
prompt             = no
[ req_dn ]
CN = opensearch-root-ca
[ v3_ca ]
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EOF
    run_openssl req -new -x509 -sha256 -config ca.cnf -extensions v3_ca -key root-ca-key.pem \
      -subj "$CERT_SUBJECT/CN=opensearch-root-ca" -days "$CA_DAYS" -out root-ca.pem
    rm -f ca.cnf
    ok "Root CA üretildi ($CA_DAYS gün)"
  fi

  sign_cert admin "$CERT_SUBJECT/CN=admin" clientAuth ""
  for i in $NODE_IDS; do
    name=$(node_name "$i")
    sign_cert "$name" "$CERT_SUBJECT/CN=$name" "serverAuth, clientAuth" "DNS:$name,IP:$(node_ip "$i")"
    names+=("$name")
  done
  # Kurum sertifikası dashboard sunucularında durur; auto modda orada bulunamazsa bu sertifikalar kullanılır
  if [ "$DASHBOARDS_CERT_MODE" = provided ]; then
    info "Dashboards için kurum sertifikası kullanılacak (dashboard sunucularında $DASHBOARDS_CERT_SRC)"
  else
    for i in $DASH_IDS; do
      name=$(dash_name "$i")
      sign_cert "$name" "$CERT_SUBJECT/CN=$name" serverAuth "$(dash_sans "$i")"
      names+=("$name")
    done
  fi

  # İki Dashboards'un oturum cookie'lerini şifrelediği ortak anahtar
  if [ -s "$DASH_COOKIE_FILE" ]; then
    info "Dashboards oturum anahtarı mevcut, yeniden kullanılıyor"
  else
    old=$(umask); umask 077
    run_openssl rand -hex -out "$DASH_COOKIE_FILE" 32
    umask "$old"
    ok "Dashboards oturum anahtarı üretildi ($DASH_COOKIE_FILE)"
  fi

  # opensearch.yml'deki admin_dn ve nodes_dn bu dosyalardan yazılır; elle yazım hatası olmaz
  subject_dn admin.pem > admin_dn.txt
  for i in $NODE_IDS; do subject_dn "$(node_name "$i").pem"; done > nodes_dn.txt

  info "Sertifikalar (DN ve bitiş tarihi):"
  for f in "${names[@]}"; do
    printf '      %-45s %s\n' "$(subject_dn "$f.pem")" "$(openssl x509 -in "$f.pem" -noout -enddate | cut -d= -f2)"
  done
  info "Bitiş tarihlerini takvime ekleyin. root-ca-key.pem diğer sunuculara kopyalanmaz."
}

make_hash() {
  local out h
  out=$(HASH_PW="$1" OPENSEARCH_JAVA_HOME="$OS_HOME/jdk" \
          bash "$OS_HOME/plugins/opensearch-security/tools/hash.sh" -env HASH_PW 2>&1 || true)
  h=$(grep -E '^\$2[aby]\$' <<<"$out" | tail -1 || true)
  [ -n "$h" ] || die "hash.sh hash üretemedi: $(tail -3 <<<"$out")"
  printf '%s' "$h"
}

phase_users() {
  local f="$CERT_WORKDIR/internal_users.yml" admin_hash ks_hash old
  step "Kullanıcı şifreleri (admin, kibanaserver)"
  if [ -s "$f" ]; then
    info "$f mevcut, yeniden kullanılıyor"
    info "Cluster kurulmadan önce şifreleri değiştirmek için dosyayı silip './node1.sh certs' çalıştırın"
    return 0
  fi
  ask_password ADMIN_PASSWORD "admin şifresi" confirm
  ask_password KIBANASERVER_PASSWORD "kibanaserver şifresi" confirm
  if [ "$ADMIN_PASSWORD" = "$KIBANASERVER_PASSWORD" ]; then
    warn "admin ve kibanaserver şifreleri aynı; farklı olması önerilir"
  fi
  info "Hash'ler üretiliyor (hash.sh)"
  admin_hash=$(make_hash "$ADMIN_PASSWORD") || exit 1
  ks_hash=$(make_hash "$KIBANASERVER_PASSWORD") || exit 1

  old=$(umask); umask 077
  cat > "$f" <<EOF
---
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "${admin_hash}"
  reserved: true
  backend_roles: ["admin"]
  description: "Admin user"

kibanaserver:
  hash: "${ks_hash}"
  reserved: true
  description: "OpenSearch Dashboards server user"
EOF
  umask "$old"
  ok "internal_users.yml üretildi (yalnızca admin ve kibanaserver; demo kullanıcılar tanımlanmadı)"
}

distribute_bundle() {
  local tarf=$1 host=$2
  if [ "$DISTRIBUTE_WITH_SCP" = yes ] \
     && scp -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
          "$tarf" "root@$host:$BUNDLE_TARGET_DIR/" 2>/dev/null; then
    ok "root@$host:$BUNDLE_TARGET_DIR/ dizinine kopyalandı"
    return 0
  fi
  if [ "$DISTRIBUTE_WITH_SCP" = yes ]; then warn "scp ile kopyalanamadı (node1'den root SSH erişimi yok olabilir)"; fi
  info "Elle kopyalayın: scp $tarf root@$host:$BUNDLE_TARGET_DIR/"
}

# $1 hedef sunucu adı, $2 içerik açıklaması, $3... CERT_WORKDIR'den pakete girecek dosyalar
make_bundle() {
  local name=$1 desc=$2 dir tarf f
  shift 2
  dir=$(mktemp -d "$BUNDLE_DIR/.tmp.XXXXXX")
  for f in "$@"; do
    [ -s "$CERT_WORKDIR/$f" ] || die "$CERT_WORKDIR/$f yok"
    cp "$CERT_WORKDIR/$f" "$dir/"
  done
  cp "$SCRIPT_DIR/config.env" "$dir/"
  (cd "$dir" && sha256sum -- * > SHA256SUMS)
  tarf="$BUNDLE_DIR/opensearch-bundle-$name.tar.gz"
  tar -czf "$tarf" -C "$dir" .
  chmod 600 "$tarf"
  rm -rf "$dir"
  ok "$tarf ($desc)"
  distribute_bundle "$tarf" "$name"
}

phase_bundle() {
  local i name files desc
  step "Node ve dashboard paketleri"
  install -d -m 700 "$BUNDLE_DIR"
  for i in $NODE_IDS; do
    [ "$i" != 1 ] || continue
    name=$(node_name "$i")
    make_bundle "$name" "sertifika, root CA, internal_users.yml, config.env" \
      root-ca.pem "$name.pem" "$name-key.pem" internal_users.yml admin_dn.txt nodes_dn.txt
  done
  for i in $DASH_IDS; do
    name=$(dash_name "$i")
    files=(root-ca.pem "$DASH_COOKIE_FILE")
    desc="root CA, oturum anahtarı, config.env"
    if [ "$DASHBOARDS_CERT_MODE" != provided ]; then
      files+=("$name.pem" "$name-key.pem"); desc="sertifika, $desc"
    fi
    make_bundle "$name" "$desc" "${files[@]}"
  done
}

phase_opensearch() {
  local f code i
  require_prep_done
  for f in root-ca.pem admin.pem admin-key.pem "$NODE1_NAME.pem" "$NODE1_NAME-key.pem" \
           internal_users.yml admin_dn.txt nodes_dn.txt; do
    [ -s "$CERT_WORKDIR/$f" ] || die "$CERT_WORKDIR/$f yok; önce './node1.sh certs' çalıştırın"
  done

  step "Sertifikalar ve güvenlik kullanıcıları"
  install_node_certs 1 "$CERT_WORKDIR"
  install_internal_users "$CERT_WORKDIR/internal_users.yml"

  step "opensearch.yml ve jvm.options"
  write_opensearch_yml 1 "$CERT_WORKDIR"
  configure_jvm

  step "OpenSearch başlatılıyor"
  start_opensearch

  step "Cluster'ın oluşması bekleniyor"
  info "Şimdi diğer node'larda kendi script'lerini çalıştırın (sıra fark etmez):"
  for i in $NODE_IDS; do
    if [ "$i" != 1 ]; then info "  $(node_name "$i"): ./node$i.sh"; fi
  done
  info "En fazla $((CLUSTER_WAIT_TIMEOUT / 60)) dakika beklenir. Ctrl+C ile çıkarsanız './node1.sh opensearch' ile devam edin."
  wait_security_ready 1
  wait_cluster_green
  disable_bootstrap_setting

  step "Cluster durumu"
  os_admin_curl "/_cat/nodes?v&h=ip,name,node.roles,cluster_manager,heap.percent,ram.percent" | sed 's/^/      /'
  info "Data ve log yolları:"
  show_node_paths
  if [ -n "${ADMIN_PASSWORD:-}" ]; then
    code=$(http_code_as admin "$ADMIN_PASSWORD" "https://$NODE1_NAME:9200/_plugins/_security/authinfo")
    if [ "$code" = 200 ]; then
      ok "admin şifresiyle giriş başarılı"
    else
      warn "admin şifresiyle giriş başarısız (HTTP $code); girilen şifre internal_users.yml'dekiyle aynı değil"
    fi
  fi
}

print_summary() {
  local i urls=""
  for i in $NODE_IDS; do urls+="${urls:+, }https://$(node_name "$i"):9200"; done
  step "OpenSearch cluster kuruldu"
  info "OpenSearch  : $urls (HAProxy üzerinden erişim dashboard1/2 kurulunca açılır)"
  info "Sertifikalar: $CERT_WORKDIR root CA key'ini içerir; güvenli bir yere yedekleyip bu sunucudan kaldırın"
  info "Paketler    : $BUNDLE_DIR ve diğer sunuculardaki paketler private key içerir; kurulum bitince silin"
  info "Node sertifikalarının bitişi: $(openssl x509 -in "$OS_CONF/$NODE1_NAME.pem" -noout -enddate | cut -d= -f2)"
  step "Sonraki adım: Dashboards (sırayla, önce biri bitsin)"
  for i in $DASH_IDS; do info "  $(dash_name "$i"): ./dashboard$i.sh"; done
}

# =============================================================================

main() {
  local phase=${1:-all}
  case "$phase" in
    -h|--help) usage; exit 0 ;;
    all|certs|opensearch) ;;
    *) usage; die "Bilinmeyen aşama: $phase" ;;
  esac

  require_root
  load_config
  require_node 1
  require_cmds openssl tar sha256sum curl ss
  if [ "$DISTRIBUTE_WITH_SCP" = yes ]; then require_cmds scp; fi

  case "$phase" in
    all)
      require_prep_done
      phase_certs
      phase_users
      phase_bundle
      phase_opensearch
      print_summary
      ;;
    certs)
      require_prep_done
      phase_certs
      phase_users
      phase_bundle
      step "Sertifikalar hazır"
      info "Sonraki adım: './node1.sh opensearch' (ya da './node1.sh' ile kalan aşamalar)"
      ;;
    opensearch) phase_opensearch; print_summary ;;
  esac
}

main "$@"
