#!/usr/bin/env bash
# Ortak fonksiyonlar ve sabitler. Doğrudan çalıştırılmaz; diğer script'ler source eder.

# --- RPM paketlerinin kullandığı sabit yollar ---
OS_HOME=/usr/share/opensearch
OS_CONF=/etc/opensearch
OS_SEC_DIR=$OS_CONF/opensearch-security
OS_OVERRIDE=/etc/systemd/system/opensearch.service.d/override.conf
OS_TMPDIR=/var/lib/opensearch/tmp       # yalnızca /tmp noexec ise kullanılır
OSD_CONF=/etc/opensearch-dashboards
OSD_CERT_DIR=$OSD_CONF/certs
HAPROXY_CONF=/etc/haproxy/haproxy.cfg
HAPROXY_CERT_DIR=/etc/haproxy/certs
KEEPALIVED_CONF=/etc/keepalived/keepalived.conf
# SELinux'ta keepalived script'leri için ayrılmış dizin
HAPROXY_CHECK=/usr/libexec/keepalived/check_haproxy.sh
OS_CA_FILE=$OS_CONF/root-ca.pem         # REST çağrılarında kullanılan cluster root CA'sı
CA_BUNDLE=/root/opensearch-ca-bundle.pem
DASH_COOKIE_FILE=dashboards_cookie_password   # iki Dashboards'un ortak oturum anahtarı (paket içinde)
HOSTS_BEGIN="# BEGIN opensearch-cluster (kurulum script'leri yönetir)"
HOSTS_END="# END opensearch-cluster"

# --- Sunucular: config.env'deki NODE<n>_* ve DASHBOARD<n>_* numaraları ---
NODE_IDS="1 2 3 4 5"
NODE_COUNT=5
DASH_IDS="1 2"

# --- Çıktı ---
if [ -t 1 ]; then
  C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_BLU=$'\033[1;34m' C_OFF=$'\033[0m'
else
  C_RED='' C_GRN='' C_YEL='' C_BLU='' C_OFF=''
fi
step() { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[OK]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '    %s[UYARI]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '\n%s[HATA]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

trap 'die "Beklenmeyen hata (satır $LINENO): $BASH_COMMAND"' ERR

# =============================================================================
# Ayarlar ve node kimliği
# =============================================================================

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Script root ile çalıştırılmalı"
}

require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "Eksik komut(lar): ${missing[*]} (dnf ile kurun)"
}

load_config() {
  local f="$SCRIPT_DIR/config.env" v i p dup
  [ -r "$f" ] || die "$f bulunamadı"
  # shellcheck source=config.env
  . "$f"

  for v in CLUSTER_NAME OS_VERSION NODE_ROLES RPM_DIR VERIFY_RPM_SIGNATURE GPG_KEY_FILE \
           DATA_DIR LOG_DIR REQUIRE_DATA_MOUNT HEAP_SIZE CERT_WORKDIR CERT_SUBJECT CA_DAYS \
           CERT_DAYS KEY_BITS ADD_CA_TO_SYSTEM_TRUST BUNDLE_DIR BUNDLE_TARGET_DIR \
           DISTRIBUTE_WITH_SCP SET_HOSTNAME DASHBOARDS_CERT_MODE DASHBOARDS_CERT_SRC \
           CLUSTER_WAIT_TIMEOUT HAPROXY_VIP HAPROXY_VRID HAPROXY_DASHBOARDS_PORT \
           HAPROXY_OPENSEARCH_PORT; do
    [ -n "${!v:-}" ] || die "config.env: $v tanımlı değil"
  done
  for v in FIREWALL_ZONE HTTP_ALLOWED_SOURCES DASHBOARDS_ALLOWED_SOURCES \
           OPENSEARCH_LB_ALLOWED_SOURCES DASHBOARDS_EXTRA_SAN; do
    printf -v "$v" '%s' "${!v:-}"
  done

  for p in $(server_vars); do
    for v in "${p}_NAME" "${p}_IP"; do
      [ -n "${!v:-}" ] && [ "${!v}" != CHANGE_ME ] || die "config.env: $v değerini girin"
    done
    v="${p}_IP";   valid_ip "${!v}" || die "config.env: $v geçerli bir IPv4 değil: ${!v}"
    v="${p}_NAME"; [[ ${!v} =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "config.env: $v geçersiz"
  done
  # 5 node ve 2 dashboard sunucusunun adları ve IP'leri birbirinden farklı olmalı
  for i in NAME IP; do
    dup=$(for p in $(server_vars); do v="${p}_$i"; printf '%s\n' "${!v}"; done | sort | uniq -d)
    [ -z "$dup" ] || die "config.env: aynı değer birden fazla sunucuda kullanılmış: $(tr '\n' ' ' <<<"$dup")"
  done

  for v in VERIFY_RPM_SIGNATURE REQUIRE_DATA_MOUNT ADD_CA_TO_SYSTEM_TRUST DISTRIBUTE_WITH_SCP SET_HOSTNAME; do
    case "${!v}" in yes|no) ;; *) die "config.env: $v yes ya da no olmalı" ;; esac
  done
  case "$DASHBOARDS_CERT_MODE" in auto|provided|self) ;; *) die "config.env: DASHBOARDS_CERT_MODE auto, provided ya da self olmalı" ;; esac
  [[ $HEAP_SIZE == auto || $HEAP_SIZE =~ ^[0-9]+[mMgG]$ ]] || die "config.env: HEAP_SIZE 'auto' ya da '8g' gibi olmalı"
  check_cert_subject
  [ -n "${DASHBOARDS_FQDN:-}" ] && [ "$DASHBOARDS_FQDN" != CHANGE_ME ] \
    || die "config.env: DASHBOARDS_FQDN değerini girin (iki Dashboards sunucusunun ortak adresi)"
  [[ $DASHBOARDS_FQDN =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "config.env: DASHBOARDS_FQDN geçersiz: $DASHBOARDS_FQDN"
  # Ortak ad tek bir sunucuya çözülmemeli (/etc/hosts'a sunucu adları yazılır)
  for p in $(server_vars); do
    for v in "${p}_NAME" "${p}_IP"; do
      [ "$DASHBOARDS_FQDN" != "${!v}" ] || die "config.env: DASHBOARDS_FQDN, $v ile aynı olamaz; sanal IP'yi gösteren ortak ad olmalı"
    done
  done
  for v in CA_DAYS CERT_DAYS KEY_BITS CLUSTER_WAIT_TIMEOUT HAPROXY_VRID HAPROXY_DASHBOARDS_PORT HAPROXY_OPENSEARCH_PORT; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "config.env: $v sayı olmalı"
  done
  [ "$HAPROXY_VIP" != CHANGE_ME ] || die "config.env: HAPROXY_VIP değerini girin (iki HAProxy sunucusunun ortak sanal IP'si)"
  valid_ip "$HAPROXY_VIP" || die "config.env: HAPROXY_VIP geçerli bir IPv4 değil: $HAPROXY_VIP"
  for p in $(server_vars); do
    v="${p}_IP"; [ "$HAPROXY_VIP" != "${!v}" ] || die "config.env: HAPROXY_VIP, $v ile aynı olamaz"
  done
  [ "$HAPROXY_VRID" -ge 1 ] && [ "$HAPROXY_VRID" -le 255 ] || die "config.env: HAPROXY_VRID 1-255 arasında olmalı"
  [ "$HAPROXY_DASHBOARDS_PORT" != "$HAPROXY_OPENSEARCH_PORT" ] || die "config.env: HAProxy portları farklı olmalı"
  for v in HAPROXY_DASHBOARDS_PORT HAPROXY_OPENSEARCH_PORT; do
    [ "${!v}" != 5601 ] || die "config.env: $v 5601 olamaz; Dashboards aynı sunucuda bu portu dinliyor"
  done

  OS_LOG_FILE="$LOG_DIR/$CLUSTER_NAME.log"

  # RPM dosya adlarındaki mimari: x86_64 -> x64, aarch64 -> arm64
  case "$(uname -m)" in
    x86_64)  RPM_ARCH=x64 ;;
    aarch64) RPM_ARCH=arm64 ;;
    *)       RPM_ARCH="" ;;
  esac
  OS_RPM="$RPM_DIR/opensearch-${OS_VERSION}-linux-${RPM_ARCH}.rpm"
  OSD_RPM="$RPM_DIR/opensearch-dashboards-${OS_VERSION}-linux-${RPM_ARCH}.rpm"
}

# DN'ler opensearch.yml'de birebir eşleşmeli; Türkçe karakter ve özel işaretler
# sertifika ile Java tarafında farklı yazılabildiği için yalnızca sade ASCII kabul edilir
check_cert_subject() {
  local re='^[A-Za-z]+=[A-Za-z0-9 ._-]+$' comp comps
  [[ $CERT_SUBJECT == /?* ]] || die "config.env: CERT_SUBJECT '/' ile başlamalı (ör. /C=TR/O=Sirket/OU=IT)"
  [[ $CERT_SUBJECT != */CN=* ]] || die "config.env: CERT_SUBJECT içinde CN olmamalı; CN'leri script ekler"
  IFS=/ read -ra comps <<<"${CERT_SUBJECT#/}"
  for comp in "${comps[@]}"; do
    [[ $comp =~ $re ]] || die "config.env: CERT_SUBJECT içinde geçersiz bölüm '$comp' (yalnızca ASCII harf, rakam, boşluk, . _ -)"
  done
}

valid_ip() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}

node_name() { local v="NODE${1}_NAME"; printf '%s' "${!v}"; }
node_ip()   { local v="NODE${1}_IP";   printf '%s' "${!v}"; }
dash_name() { local v="DASHBOARD${1}_NAME"; printf '%s' "${!v}"; }
dash_ip()   { local v="DASHBOARD${1}_IP";   printf '%s' "${!v}"; }

# config.env'deki sunucu değişkenlerinin önekleri: NODE1 ... NODE5 DASHBOARD1 DASHBOARD2
server_vars() {
  local i
  for i in $NODE_IDS; do printf 'NODE%s ' "$i"; done
  for i in $DASH_IDS; do printf 'DASHBOARD%s ' "$i"; done
}

# Tüm node adları, YAML/JSON listesi olarak: "node1", "node2", ...
node_list() {
  local i sep=""
  for i in $NODE_IDS; do printf '%s"%s"' "$sep" "$(node_name "$i")"; sep=", "; done
}

local_ips() { ip -4 -o addr show | awk '{split($4, a, "/"); print a[1]}'; }

# Sunucunun IP'lerinden hangi node olduğunu bulur (1-5); bulamazsa boş döner
detect_node_id() {
  local i mine
  mine=$(local_ips)
  for i in $NODE_IDS; do
    if grep -qxF "$(node_ip "$i")" <<<"$mine"; then printf '%s' "$i"; return 0; fi
  done
}

# Sunucunun IP'lerinden hangi dashboard sunucusu olduğunu bulur (1 ya da 2); bulamazsa boş döner
detect_dash_id() {
  local i mine
  mine=$(local_ips)
  for i in $DASH_IDS; do
    if grep -qxF "$(dash_ip "$i")" <<<"$mine"; then printf '%s' "$i"; return 0; fi
  done
}

# Bu sunucunun config.env'deki adı ve IP'si ("dashboard1 (10.0.0.11)"); bulunamazsa boş
this_server() {
  local id
  id=$(detect_node_id)
  if [ -n "$id" ]; then printf '%s (%s)' "$(node_name "$id")" "$(node_ip "$id")"; return 0; fi
  id=$(detect_dash_id)
  if [ -n "$id" ]; then printf '%s (%s)' "$(dash_name "$id")" "$(dash_ip "$id")"; fi
}

# Script yanlış sunucuda çalıştırılırsa durur. $1 beklenen node no
require_node() {
  local id
  id=$(detect_node_id)
  if [ "$id" = "$1" ]; then return 0; fi
  [ -n "$(this_server)" ] || die "Bu sunucunun IP'leri ($(local_ips | tr '\n' ' ')) config.env'deki IP'lerle eşleşmiyor"
  die "Bu sunucu $(this_server); bu script $(node_name "$1") içindir"
}

# $1 beklenen dashboard sunucusu no
require_dashboard() {
  local id
  id=$(detect_dash_id)
  if [ "$id" = "$1" ]; then return 0; fi
  [ -n "$(this_server)" ] || die "Bu sunucunun IP'leri ($(local_ips | tr '\n' ' ')) config.env'deki IP'lerle eşleşmiyor"
  die "Bu sunucu $(this_server); bu script $(dash_name "$1") içindir"
}

port_listening() {
  local out
  out=$(ss -ltnH "( sport = :$1 )" 2>/dev/null || true)
  [ -n "$out" ]
}

require_prep_done() {
  rpm -q opensearch >/dev/null 2>&1 || die "opensearch paketi kurulu değil; önce ./hazirlik.sh çalıştırın"
  [ -f "$OS_OVERRIDE" ] || die "$OS_OVERRIDE yok; önce ./hazirlik.sh çalıştırın"
  [ -d "$DATA_DIR" ] && [ -d "$LOG_DIR" ] || die "$DATA_DIR ya da $LOG_DIR yok; önce ./hazirlik.sh çalıştırın"
}

# Şifreyi ortam değişkeninden alır, yoksa sorar. $3=confirm: iki kez sorar, en az 8 karakter ister
ask_password() {
  local var=$1 label=$2 mode=${3:-} p1 p2
  [ -z "${!var:-}" ] || return 0
  [ -t 0 ] || die "$var ortam değişkeni verilmedi ve şifre sorulacak terminal yok"
  while :; do
    read -rsp "    $label: " p1; echo
    if [ "$mode" = confirm ]; then
      if [ ${#p1} -lt 8 ]; then warn "En az 8 karakter olmalı"; continue; fi
      read -rsp "    $label (tekrar): " p2; echo
      if [ "$p1" != "$p2" ]; then warn "Şifreler eşleşmedi"; continue; fi
    fi
    [ -n "$p1" ] && break
  done
  printf -v "$var" '%s' "$p1"
}

# YAML tek tırnaklı değer
yaml_sq() { local q="'"; printf "'%s'" "${1//$q/$q$q}"; }

# =============================================================================
# SELinux ve firewalld
# =============================================================================

selinux_runtime() {
  if command -v getenforce >/dev/null 2>&1; then getenforce; else echo Disabled; fi
}
selinux_config() { sed -n 's/^SELINUX=//p' /etc/selinux/config 2>/dev/null | tr -d '[:space:]' || true; }
selinux_on() { [ "$(selinux_runtime)" != Disabled ]; }

selinux_restore() {
  if selinux_on; then restorecon -R "$@"; fi
}

# $1 dizinine $2 referans dizinle aynı SELinux etiketini verir (kalıcı kural + restorecon)
selinux_label_like() {
  local dir=$1 ref=$2 rules
  if ! command -v semanage >/dev/null 2>&1; then
    info "semanage için policycoreutils-python-utils kuruluyor"
    dnf install -y -q policycoreutils-python-utils || die "policycoreutils-python-utils kurulamadı"
  fi
  rules=$(semanage fcontext -l -C 2>/dev/null || true)
  if grep -qxF "$dir = $ref" <<<"$rules"; then
    info "Etiket kuralı mevcut: $dir = $ref"
  elif semanage fcontext -a -e "$ref" "$dir"; then
    ok "Etiket kuralı eklendi: $dir = $ref"
  else
    warn "Etiket kuralı eklenemedi: $dir = $ref (semanage fcontext -l -C ile kontrol edin)"
  fi
  restorecon -R "$dir"
}

check_avc() {
  selinux_on || return 0
  command -v ausearch >/dev/null 2>&1 || return 0
  local out
  out=$(ausearch -m AVC -ts recent 2>/dev/null | grep -E 'opensearch|java|node|haproxy|keepalived' || true)
  if [ -n "$out" ]; then
    warn "Son dakikalarda SELinux AVC engellemesi var:"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
  else
    ok "SELinux AVC engellemesi yok"
  fi
}

firewalld_on() { systemctl is-active --quiet firewalld; }

# Node IP'sinin bağlı olduğu arayüzün zone'u (FIREWALL_ZONE verilmişse o)
fw_zone() {
  local ifc z=""
  if [ -n "$FIREWALL_ZONE" ]; then printf '%s' "$FIREWALL_ZONE"; return 0; fi
  ifc=$(ip -4 -o addr show | awk -v ip="$1" '{split($4, a, "/")} a[1] == ip {print $2; exit}')
  if [ -n "$ifc" ]; then z=$(firewall-cmd --get-zone-of-interface="$ifc" 2>/dev/null || true); fi
  if [ -z "$z" ]; then z=$(firewall-cmd --get-default-zone); fi
  printf '%s' "$z"
}

# $1 zone, $2 port, $3 kaynak CIDR (boşsa herkese açık). Kalıcı kural; reload ayrıca yapılır
fw_allow() {
  local zone=$1 port=$2 src=${3:-} rule
  if [ -n "$src" ]; then
    rule="rule family=\"ipv4\" source address=\"$src\" port port=\"$port\" protocol=\"tcp\" accept"
    if firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
      info "Kural mevcut: $port/tcp <- $src"
    else
      firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" >/dev/null
      ok "Kural eklendi: $port/tcp <- $src (zone $zone)"
    fi
  else
    if firewall-cmd --permanent --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1; then
      info "Kural mevcut: $port/tcp herkese açık"
    else
      firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp" >/dev/null
      ok "Kural eklendi: $port/tcp herkese açık (zone $zone)"
    fi
  fi
}

# $1 zone, $2 kaynak CIDR. keepalived'ın VRRP trafiği (protokol, port değil)
fw_allow_vrrp() {
  local zone=$1 src=$2 rule
  rule="rule family=\"ipv4\" source address=\"$src\" protocol value=\"vrrp\" accept"
  if firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
    info "Kural mevcut: vrrp <- $src"
  else
    firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" >/dev/null
    ok "Kural eklendi: vrrp <- $src (zone $zone)"
  fi
}

# =============================================================================
# RPM
# =============================================================================

verify_rpm_sig() {
  local rpm=$1 sig="$1.sig" gh out signer
  if [ "$VERIFY_RPM_SIGNATURE" != yes ]; then
    warn "İmza doğrulaması kapalı (VERIFY_RPM_SIGNATURE=no): $(basename "$rpm")"
    return 0
  fi
  [ -s "$sig" ] || die "$sig yok. .sig dosyasını indirin ya da VERIFY_RPM_SIGNATURE=no yapın"
  [ -s "$GPG_KEY_FILE" ] || die "$GPG_KEY_FILE yok (https://artifacts.opensearch.org/publickeys/opensearch-release.pgp)"
  # Root'un anahtarlığı kirlenmesin diye geçici bir GnuPG dizini kullanılır
  gh=$(mktemp -d)
  gpg --homedir "$gh" --batch --quiet --import "$GPG_KEY_FILE" >/dev/null 2>&1 || true
  out=$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$sig" "$rpm" 2>/dev/null || true)
  gpgconf --homedir "$gh" --kill all >/dev/null 2>&1 || true
  rm -rf "$gh"
  grep -q '^\[GNUPG:\] VALIDSIG' <<<"$out" || die "İmza doğrulanamadı: $(basename "$rpm"). Dosyayı yeniden indirin"
  signer=$(sed -n 's/^\[GNUPG:\] GOODSIG [0-9A-F]* //p' <<<"$out" | head -1)
  ok "İmza doğrulandı: $(basename "$rpm") (${signer:-?})"
}

# $1 paket adı, $2 rpm dosyası. Aynı sürüm kuruluysa atlar
install_rpm() {
  local pkg=$1 rpm=$2 cur
  if rpm -q "$pkg" >/dev/null 2>&1; then
    cur=$(rpm -q --qf '%{VERSION}' "$pkg")
    [ "$cur" = "$OS_VERSION" ] || die "$pkg $cur kurulu, beklenen $OS_VERSION. Sürüm yükseltme bu script'lerin kapsamında değil"
    ok "$pkg $cur zaten kurulu"
    return 0
  fi
  [ -s "$rpm" ] || die "$rpm bulunamadı"
  verify_rpm_sig "$rpm"
  # Yerel dosyada dnf GPG kontrolü yapmaz; doğrulama yukarıdaki .sig ile yapıldı.
  # DISABLE_INSTALL_DEMO_CONFIG: demo sertifika, kullanıcı ve rolleri oluşturmaz.
  # skip_if_unavailable: erişilemeyen repo (internetsiz sunucu) kurulumu durdurmaz
  DISABLE_INSTALL_DEMO_CONFIG=true dnf install -y --setopt=skip_if_unavailable=True "$rpm"
  ok "$pkg $OS_VERSION kuruldu"
}

# =============================================================================
# HTTP yardımcıları
# =============================================================================

json_str() { grep -o "\"$1\":\"[^\"]*\"" <<<"$2" | head -1 | cut -d'"' -f4 || true; }
json_num() { grep -o "\"$1\":[0-9]*" <<<"$2" | head -1 | cut -d: -f2 || true; }

# curl'e kullanıcı/şifreyi stdin'den verir; şifre komut satırında (ps çıktısında) görünmez
curl_auth_cfg() { local p=${2//\\/\\\\}; p=${p//\"/\\\"}; printf 'user = "%s:%s"\n' "$1" "$p"; }

curl_as() {  # $1 kullanıcı, $2 şifre, $3 URL -> gövde
  curl_auth_cfg "$1" "$2" | curl -sS --max-time 10 --cacert "$OS_CA_FILE" -K - "$3" 2>/dev/null || true
}

http_code_as() {  # $1 kullanıcı, $2 şifre, $3 URL -> HTTP kodu (bağlantı hatasında 000)
  curl_auth_cfg "$1" "$2" \
    | curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$OS_CA_FILE" -K - "$3" 2>/dev/null || true
}

# =============================================================================
# OpenSearch node yapılandırması (5 node'da ortak)
# =============================================================================

# openssl'i çalıştırır; hata olursa openssl'in kendi mesajıyla durur
run_openssl() {
  local log
  log=$(mktemp)
  if openssl "$@" >/dev/null 2>"$log"; then rm -f "$log"; return 0; fi
  die "openssl $1 başarısız: $(cat "$log"; rm -f "$log")"
}

cert_pub_hash() { openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl sha256 || true; }
key_pub_hash()  { openssl pkey -in "$1" -pubout "${@:2}" 2>/dev/null | openssl sha256 || true; }

# Script açıklamasını (ilk yorum bloğu) yazdırır
usage() { awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; }

# $1 node no, $2 sertifikaların bulunduğu dizin
install_node_certs() {
  local n=$1 src=$2 name f
  name=$(node_name "$n")
  for f in root-ca.pem "$name.pem" "$name-key.pem"; do
    [ -s "$src/$f" ] || die "$src/$f yok"
  done
  install -o opensearch -g opensearch -m 600 "$src/root-ca.pem" "$src/$name.pem" "$src/$name-key.pem" "$OS_CONF/"
  if [ "$n" = 1 ]; then
    install -o opensearch -g opensearch -m 600 "$src/admin.pem" "$src/admin-key.pem" "$OS_CONF/"
  fi

  openssl verify -CAfile "$OS_CONF/root-ca.pem" "$OS_CONF/$name.pem" >/dev/null \
    || die "$name.pem root CA ile doğrulanamadı"
  [ "$(cert_pub_hash "$OS_CONF/$name.pem")" = "$(key_pub_hash "$OS_CONF/$name-key.pem")" ] \
    || die "$name.pem ile $name-key.pem eşleşmiyor"
  selinux_restore "$OS_CONF"
  ok "Sertifikalar $OS_CONF altına kondu ($name.pem, root CA SHA256 $(openssl x509 -in "$OS_CONF/root-ca.pem" -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)...)"

  if [ "$ADD_CA_TO_SYSTEM_TRUST" = yes ]; then
    cp "$OS_CONF/root-ca.pem" /etc/pki/ca-trust/source/anchors/opensearch-root-ca.pem
    update-ca-trust
    ok "Root CA sistem güvenine eklendi"
  fi
}

install_internal_users() {
  [ -s "$1" ] || die "$1 yok"
  [ -f "$OS_SEC_DIR/internal_users.yml.orig" ] || cp -p "$OS_SEC_DIR/internal_users.yml" "$OS_SEC_DIR/internal_users.yml.orig"
  install -o opensearch -g opensearch -m 600 "$1" "$OS_SEC_DIR/internal_users.yml"
  selinux_restore "$OS_SEC_DIR"
  ok "internal_users.yml kondu (admin, kibanaserver)"
}

# $1 node no, $2 admin_dn.txt ve nodes_dn.txt dizini (node1'de sertifikalardan üretilir)
write_opensearch_yml() {
  local n=$1 dndir=$2 name ip dn
  name=$(node_name "$n"); ip=$(node_ip "$n")
  [ -s "$dndir/admin_dn.txt" ] && [ -s "$dndir/nodes_dn.txt" ] || die "$dndir içinde admin_dn.txt / nodes_dn.txt yok"
  [ -f "$OS_CONF/opensearch.yml.orig" ] || cp -p "$OS_CONF/opensearch.yml" "$OS_CONF/opensearch.yml.orig"

  {
    cat <<EOF
# Kurulum script'leri tarafından üretildi: $(date '+%F %T')
cluster.name: ${CLUSTER_NAME}
node.name: ${name}
node.roles: [ ${NODE_ROLES} ]

path.data: ${DATA_DIR}
path.logs: ${LOG_DIR}

network.host: 0.0.0.0
network.publish_host: ${ip}
http.port: 9200
transport.port: 9300

discovery.seed_hosts: [$(node_list)]
# Yalnızca ilk kurulumda gerekir; node cluster'a katılınca script yorum satırı yapar
cluster.initial_cluster_manager_nodes: [$(node_list)]

# --- TLS: node'lar arası (9300) ---
plugins.security.ssl.transport.pemcert_filepath: ${name}.pem
plugins.security.ssl.transport.pemkey_filepath: ${name}-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: root-ca.pem
plugins.security.ssl.transport.enforce_hostname_verification: false

# --- TLS: REST (9200) ---
plugins.security.ssl.http.enabled: true
plugins.security.ssl.http.pemcert_filepath: ${name}.pem
plugins.security.ssl.http.pemkey_filepath: ${name}-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: root-ca.pem

# --- Security ---
# DN'ler node1'de üretilen sertifikalardan okunarak yazıldı
plugins.security.authcz.admin_dn:
EOF
    while IFS= read -r dn; do [ -z "$dn" ] || printf '  - %s\n' "$(yaml_sq "$dn")"; done < "$dndir/admin_dn.txt"
    echo "plugins.security.nodes_dn:"
    while IFS= read -r dn; do [ -z "$dn" ] || printf '  - %s\n' "$(yaml_sq "$dn")"; done < "$dndir/nodes_dn.txt"
    cat <<'EOF'
plugins.security.allow_default_init_securityindex: true
plugins.security.audit.type: internal_opensearch
plugins.security.enable_snapshot_restore_privilege: true
plugins.security.check_snapshot_restore_write_privileges: true
plugins.security.restapi.roles_enabled: ["all_access", "security_rest_api_access"]
plugins.security.system_indices.enabled: true
EOF
  } > "$OS_CONF/opensearch.yml.new"

  mv "$OS_CONF/opensearch.yml.new" "$OS_CONF/opensearch.yml"
  chown opensearch:opensearch "$OS_CONF/opensearch.yml"
  chmod 640 "$OS_CONF/opensearch.yml"
  selinux_restore "$OS_CONF/opensearch.yml"
  ok "opensearch.yml yazıldı (node.name=$name, publish_host=$ip)"
}

configure_jvm() {
  local heap=$HEAP_SIZE mem_mb h jvm=$OS_CONF/jvm.options
  if [ "$heap" = auto ]; then
    mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    h=$(( mem_mb / 2 / 1024 ))
    if [ "$h" -lt 1 ]; then h=1; fi
    if [ "$h" -gt 31 ]; then h=31; fi
    heap="${h}g"
    info "RAM ${mem_mb} MB, heap $heap olarak hesaplandı"
  fi

  # Her çalıştırmada orijinal dosyadan başlanır
  if [ -f "$jvm.orig" ]; then cp -p "$jvm.orig" "$jvm"; else cp -p "$jvm" "$jvm.orig"; fi
  sed -i -E 's/^(-Xm[sx].*)/## heap jvm.options.d\/heap.options içinde: \1/' "$jvm"
  # GC log, heap dump ve JVM crash log yolları /data altına
  sed -i "s|/var/lib/opensearch|$DATA_DIR|g; s|/var/log/opensearch|$LOG_DIR|g" "$jvm"

  install -d -o opensearch -g opensearch -m 750 "$OS_CONF/jvm.options.d"
  printf -- '-Xms%s\n-Xmx%s\n' "$heap" "$heap" > "$OS_CONF/jvm.options.d/heap.options"
  chown opensearch:opensearch "$OS_CONF/jvm.options.d/heap.options" "$jvm"
  selinux_restore "$OS_CONF/jvm.options" "$OS_CONF/jvm.options.d"

  grep -qE "HeapDumpPath=$DATA_DIR" "$jvm" || warn "jvm.options içinde HeapDumpPath $DATA_DIR göstermiyor"
  ok "Heap $heap (jvm.options.d/heap.options); GC/dump/crash log yolları $DATA_DIR ve $LOG_DIR"
}

start_opensearch() {
  local t=0
  systemctl daemon-reload
  systemctl enable opensearch >/dev/null 2>&1 || true
  if ! systemctl restart opensearch; then
    journalctl -u opensearch -n 40 --no-pager || true
    tail -n 40 "$OS_LOG_FILE" 2>/dev/null || true
    die "OpenSearch başlatılamadı (yukarıdaki loglara bakın)"
  fi
  until port_listening 9200; do
    systemctl is-active --quiet opensearch || { tail -n 40 "$OS_LOG_FILE" 2>/dev/null || true; die "OpenSearch servisi durdu"; }
    [ "$t" -lt 180 ] || die "9200 portu 180 saniyede açılmadı ($OS_LOG_FILE)"
    sleep 3; t=$((t + 3))
  done
  ok "OpenSearch çalışıyor, 9200 dinleniyor (log: $OS_LOG_FILE)"
  check_avc
}

disable_bootstrap_setting() {
  if grep -q '^cluster.initial_cluster_manager_nodes' "$OS_CONF/opensearch.yml"; then
    sed -i 's/^cluster.initial_cluster_manager_nodes/#&/' "$OS_CONF/opensearch.yml"
    ok "cluster.initial_cluster_manager_nodes yorum satırı yapıldı (restart gerekmez)"
  fi
}

# Cluster oluşmuyorsa olası sebepleri gösterir
show_cluster_diag() {
  local i ip
  info "--- Teşhis ($(date +%T)) ---"
  if [ -r "$OS_LOG_FILE" ]; then
    grep -E 'cluster-manager not discovered' "$OS_LOG_FILE" | tail -1 | cut -c1-400 | sed 's/^/      /' || true
    grep -iE 'ssl|handshake|certificate|unknown_ca|PKIX|nodes_dn' "$OS_LOG_FILE" | grep -E 'WARN|ERROR' \
      | tail -3 | cut -c1-400 | sed 's/^/      /' || true
  fi
  for i in $NODE_IDS; do
    ip=$(node_ip "$i")
    if timeout 3 bash -c "</dev/tcp/$ip/9300" 2>/dev/null; then
      info "$(node_name "$i") $ip:9300 açık"
    else
      info "$(node_name "$i") $ip:9300 erişilemiyor (servis henüz başlamadı ya da firewall)"
    fi
  done
}

# Güvenlik index'i hazır olana kadar REST, kimlik doğrulamasız isteğe 503 döner; hazır olunca 401.
# 5 initial cluster manager'dan en az 3'ü bir araya gelmeden cluster oluşmadığı için 401,
# node'un cluster'a katıldığını gösterir.
wait_security_ready() {
  local n=$1 url code msg end next_diag last=""
  url="https://$(node_name "$n"):9200/"
  end=$((SECONDS + CLUSTER_WAIT_TIMEOUT)); next_diag=$((SECONDS + 120))
  while :; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$OS_CONF/root-ca.pem" "$url" 2>/dev/null || true)
    case "$code" in
      401|200) ok "Node cluster'a katıldı, güvenlik modülü hazır (HTTP $code)"; return 0 ;;
      503)     msg="cluster henüz oluşmadı (diğer node'lar bekleniyor)" ;;
      *)       msg="REST yanıtı: HTTP ${code:-000}" ;;
    esac
    if ! systemctl is-active --quiet opensearch; then
      tail -n 40 "$OS_LOG_FILE" 2>/dev/null || true
      die "OpenSearch servisi durdu (log: $OS_LOG_FILE)"
    fi
    if [ "$msg" != "$last" ]; then info "$(date +%T) $msg"; last=$msg; fi
    if [ $SECONDS -ge "$next_diag" ]; then show_cluster_diag; next_diag=$((SECONDS + 120)); fi
    if [ $SECONDS -ge "$end" ]; then show_cluster_diag; die "Node $CLUSTER_WAIT_TIMEOUT saniyede cluster'a katılmadı (README: Sorun giderme)"; fi
    sleep 10
  done
}

# node1'in ürettiği paketi BUNDLE_TMP'ye açar; SHA256'yı ve config.env'nin aynı olduğunu doğrular
open_bundle() {
  local bundle=$1
  step "node1'den gelen paket: $bundle"
  [ -s "$bundle" ] || die "$bundle yok. node1'de './node1.sh certs' çalıştırıp paketi bu sunucuya kopyalayın"
  BUNDLE_TMP=$(mktemp -d)
  trap 'rm -rf "$BUNDLE_TMP"' EXIT
  tar -xzf "$bundle" -C "$BUNDLE_TMP"
  (cd "$BUNDLE_TMP" && sha256sum -c --quiet SHA256SUMS) || die "Paket bozuk (SHA256SUMS tutmuyor)"
  if ! cmp -s "$BUNDLE_TMP/config.env" "$SCRIPT_DIR/config.env"; then
    diff -u "$BUNDLE_TMP/config.env" "$SCRIPT_DIR/config.env" | sed 's/^/      /' || true
    die "Bu sunucudaki config.env, node1'dekiyle aynı değil. node1'deki dosyayı buraya kopyalayın"
  fi
  ok "Paket doğrulandı, config.env node1 ile aynı"
}

# node2.sh ... node5.sh'in ortak akışı
run_member_node() {
  local n=$1 bundle=${2:-} name
  require_root
  load_config
  require_node "$n"
  require_prep_done
  require_cmds openssl tar sha256sum curl ss
  name=$(node_name "$n")
  bundle=${bundle:-$BUNDLE_TARGET_DIR/opensearch-bundle-$name.tar.gz}

  open_bundle "$bundle"

  step "Sertifikalar ve güvenlik kullanıcıları"
  install_node_certs "$n" "$BUNDLE_TMP"
  install_internal_users "$BUNDLE_TMP/internal_users.yml"

  step "opensearch.yml ve jvm.options"
  write_opensearch_yml "$n" "$BUNDLE_TMP"
  configure_jvm

  step "OpenSearch başlatılıyor"
  start_opensearch

  step "Cluster'a katılım bekleniyor"
  wait_security_ready "$n"
  disable_bootstrap_setting

  step "$name tamamlandı"
  info "Cluster durumunu node1.sh izliyor; $NODE_COUNT node green olunca kurulumu tamamlar."
  info "Paket private key içerir; kurulum bitince silin: rm -f $bundle"
}

# =============================================================================
# OpenSearch Dashboards (dashboard1, dashboard2)
# =============================================================================

# auto modda kurum sertifikası varsa provided, yoksa self
dash_cert_mode() {
  if [ "$DASHBOARDS_CERT_MODE" != auto ]; then
    printf '%s' "$DASHBOARDS_CERT_MODE"
  elif [ -s "$DASHBOARDS_CERT_SRC/ssl.crt" ] && [ -s "$DASHBOARDS_CERT_SRC/ssl.key" ]; then
    printf provided
  else
    printf self
  fi
}

# $1 SAN metni ("DNS:a, IP Address:1.2.3.4"), $2 host. *.alan.adi joker kaydı da kabul edilir
san_has() {
  local s=", $1," h=$2
  if valid_ip "$h"; then
    [[ $s == *", IP Address:$h,"* ]]
  else
    [[ $s == *", DNS:$h,"* || $s == *", DNS:*.${h#*.},"* ]]
  fi
}

san_of() { openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | sed -n '2p' | sed 's/^ *//' || true; }

# REST'i yanıt veren ilk node'un adresi (https://nodeX:9200); hiçbiri yanıt vermezse boş
first_live_node() {
  local i url code
  for i in $NODE_IDS; do
    url="https://$(node_name "$i"):9200"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$OS_CA_FILE" "$url/" 2>/dev/null || true)
    case "$code" in 200|401) printf '%s' "$url"; return 0 ;; esac
  done
}

# $1 mod (self/provided), $2 bu dashboard sunucusunun adı. Dosyalar BUNDLE_TMP'den alınır
install_dash_certs() {
  local mode=$1 name=$2 src=$DASHBOARDS_CERT_SRC f
  local own=(-o opensearch-dashboards -g opensearch-dashboards)
  install -d "${own[@]}" -m 750 "$OSD_CERT_DIR"
  # Dashboards -> OpenSearch bağlantısı için cluster'ın root CA'sı
  install "${own[@]}" -m 640 "$BUNDLE_TMP/root-ca.pem" "$OSD_CONF/root-ca.pem"

  if [ "$mode" = self ]; then
    for f in "$name.pem" "$name-key.pem"; do
      [ -s "$BUNDLE_TMP/$f" ] || die "Pakette $f yok (node1'de DASHBOARDS_CERT_MODE=provided iken üretilmiş). Kurum sertifikasını $src altına koyun ya da node1'de './node1.sh certs' çalıştırın"
    done
    install "${own[@]}" -m 640 "$BUNDLE_TMP/$name.pem" "$OSD_CERT_DIR/ssl.crt"
    install "${own[@]}" -m 600 "$BUNDLE_TMP/$name-key.pem" "$OSD_CERT_DIR/ssl.key"
    install "${own[@]}" -m 640 "$BUNDLE_TMP/root-ca.pem" "$OSD_CERT_DIR/ca.crt"
    ok "Cluster root CA'sıyla imzalı sertifika kondu ($name.pem)"
  else
    for f in ssl.crt ssl.key ca.crt; do
      [ -s "$src/$f" ] || die "$src/$f yok (DASHBOARDS_CERT_MODE=$DASHBOARDS_CERT_MODE)"
    done
    install "${own[@]}" -m 640 "$src/ssl.crt" "$src/ca.crt" "$OSD_CERT_DIR/"
    install "${own[@]}" -m 600 "$src/ssl.key" "$OSD_CERT_DIR/ssl.key"
    # DER formatındaysa PEM'e çevir
    for f in ssl.crt ca.crt; do
      if ! grep -q -- '-----BEGIN' "$OSD_CERT_DIR/$f"; then
        run_openssl x509 -inform der -in "$OSD_CERT_DIR/$f" -out "$OSD_CERT_DIR/$f.pem"
        mv "$OSD_CERT_DIR/$f.pem" "$OSD_CERT_DIR/$f"
        info "$f DER'den PEM'e çevrildi"
      fi
    done
    if ! grep -q -- '-----BEGIN' "$OSD_CERT_DIR/ssl.key"; then
      run_openssl pkey -inform der -in "$OSD_CERT_DIR/ssl.key" -out "$OSD_CERT_DIR/ssl.key.pem"
      mv "$OSD_CERT_DIR/ssl.key.pem" "$OSD_CERT_DIR/ssl.key"
      info "ssl.key DER'den PEM'e çevrildi"
    fi
    chown opensearch-dashboards:opensearch-dashboards "$OSD_CERT_DIR"/*
    chmod 640 "$OSD_CERT_DIR/ssl.crt" "$OSD_CERT_DIR/ca.crt"
    chmod 600 "$OSD_CERT_DIR/ssl.key"
    ok "Kurum sertifikaları kondu ($src)"
  fi
  selinux_restore "$OSD_CONF"

  if [ "$ADD_CA_TO_SYSTEM_TRUST" = yes ]; then
    cp "$OSD_CONF/root-ca.pem" /etc/pki/ca-trust/source/anchors/opensearch-root-ca.pem
    update-ca-trust
    ok "Root CA sistem güvenine eklendi"
  fi
}

check_dash_certs() {
  local d=$OSD_CERT_DIR passin=() san
  if grep -q ENCRYPTED "$d/ssl.key"; then
    ask_password DASHBOARDS_KEY_PASSPHRASE "ssl.key şifreli; key şifresi"
    export DASHBOARDS_KEY_PASSPHRASE
    passin=(-passin env:DASHBOARDS_KEY_PASSPHRASE)
  fi
  openssl verify -CAfile "$d/ca.crt" -untrusted "$d/ssl.crt" "$d/ssl.crt" >/dev/null 2>&1 \
    || die "ssl.crt, ca.crt ile doğrulanamadı. Ara CA varsa ssl.crt önce sunucu, sonra ara CA sertifikasını içermeli"
  ok "ssl.crt, ca.crt ile doğrulandı"
  [ "$(cert_pub_hash "$d/ssl.crt")" = "$(key_pub_hash "$d/ssl.key" ${passin[@]+"${passin[@]}"})" ] \
    || die "ssl.key, ssl.crt ile eşleşmiyor (ya da key şifresi yanlış)"
  ok "ssl.key ile ssl.crt eşleşiyor"
  openssl x509 -in "$d/ssl.crt" -noout -checkend 0 >/dev/null || die "ssl.crt'nin süresi dolmuş"
  openssl x509 -in "$d/ssl.crt" -noout -checkend $((30 * 86400)) >/dev/null || warn "ssl.crt 30 gün içinde sona eriyor"
  san=$(san_of "$d/ssl.crt")
  info "SAN: ${san:-yok}"
  info "Bitiş: $(openssl x509 -in "$d/ssl.crt" -noout -enddate | cut -d= -f2)"
  san_has "$san" "$DASH_HOST" \
    || die "Sertifika SAN'ı ortak adres '$DASH_HOST' (DASHBOARDS_FQDN) içermiyor; iki sunucuya da bu adı içeren sertifika gerekir"
  ok "SAN ortak adresi içeriyor: $DASH_HOST"
}

# $1 bu dashboard sunucusunun adı, $2 ortak oturum anahtarı dosyası
write_dashboards_yml() {
  local name=$1 cookie f=$OSD_CONF/opensearch_dashboards.yml old hosts="" i
  cookie=$(cat "$2")
  [ ${#cookie} -ge 32 ] || die "$2 içindeki oturum anahtarı 32 karakterden kısa"
  for i in $NODE_IDS; do hosts+="${hosts:+, }\"https://$(node_name "$i"):9200\""; done
  [ -f "$f.orig" ] || cp -p "$f" "$f.orig"
  old=$(umask); umask 077
  {
    cat <<EOT
# Kurulum script'leri tarafından üretildi: $(date '+%F %T')
server.host: 0.0.0.0
server.port: 5601
server.name: $(yaml_sq "$name")

# --- Tarayıcı <-> Dashboards TLS ---
server.ssl.enabled: true
server.ssl.certificate: $OSD_CERT_DIR/ssl.crt
server.ssl.key: $OSD_CERT_DIR/ssl.key
server.ssl.certificateAuthorities: ["$OSD_CERT_DIR/ca.crt"]
EOT
    if [ -n "${DASHBOARDS_KEY_PASSPHRASE:-}" ]; then
      echo "server.ssl.keyPassphrase: $(yaml_sq "$DASHBOARDS_KEY_PASSPHRASE")"
    fi
    cat <<EOT

# --- Dashboards <-> OpenSearch TLS ---
# Tüm node'lar listelenir; bir node düşerse Dashboards diğerlerine bağlanır
opensearch.hosts: [$hosts]
opensearch.ssl.verificationMode: full
opensearch.ssl.certificateAuthorities: ["$OSD_CONF/root-ca.pem"]
opensearch.username: kibanaserver
opensearch.password: $(yaml_sq "$KIBANASERVER_PASSWORD")
opensearch.requestHeadersAllowlist: [authorization, securitytenant]

# --- Security plugin ---
opensearch_security.multitenancy.enabled: true
opensearch_security.multitenancy.tenants.preferred: [Private, Global]
opensearch_security.readonly_mode.roles: [kibana_read_only]
opensearch_security.cookie.secure: true
# İki Dashboards sunucusunda aynıdır (node1 üretir): HAProxy isteği diğer
# sunucuya yönlendirse de kullanıcının oturumu geçerli kalır
opensearch_security.cookie.password: $(yaml_sq "$cookie")
EOT
  } > "$f.new"
  umask "$old"
  mv "$f.new" "$f"
  chown opensearch-dashboards:opensearch-dashboards "$f"
  chmod 600 "$f"
  selinux_restore "$f"
  ok "$f yazıldı (kibanaserver şifresini ve oturum anahtarını içerir, izin 600)"
}

# Kullanıcının gireceği adla (DASH_HOST) yerelden bağlanıp sertifikayı da doğrular
wait_dashboards() {
  local url="https://$DASH_HOST:5601/api/status" end=$((SECONDS + 300)) out code rc
  while :; do
    out=$(curl -sS -o /dev/null -w '%{http_code} %{exitcode}' --max-time 5 --resolve "$DASH_HOST:5601:127.0.0.1" \
            --cacert "$OSD_CERT_DIR/ca.crt" "$url" 2>/dev/null || true)
    code=${out%% *}; rc=${out##* }
    if [ "$rc" = 0 ]; then
      case "$code" in
        401|200|302) ok "Dashboards HTTPS ile yanıt veriyor (HTTP $code; 401 = giriş zorunlu, beklenen)"; return 0 ;;
      esac
    elif [ "$rc" = 60 ] || [ "$rc" = 51 ]; then
      die "TLS doğrulaması başarısız (curl $rc): ssl.crt SAN'ı '$DASH_HOST' içermiyor ya da ca.crt zinciri eksik"
    fi
    if ! systemctl is-active --quiet opensearch-dashboards; then
      journalctl -u opensearch-dashboards -n 40 --no-pager || true
      die "opensearch-dashboards servisi durdu (yukarıdaki log)"
    fi
    if [ $SECONDS -ge "$end" ]; then
      journalctl -u opensearch-dashboards -n 40 --no-pager || true
      die "Dashboards 300 saniyede hazır olmadı (son yanıt: HTTP ${code:-000}, curl çıkış kodu $rc)"
    fi
    sleep 5
  done
}

# Test için iki CA tek dosyada: cluster root CA'sı ve Dashboards sertifikasının CA'sı
build_ca_bundle() {
  cat "$OSD_CONF/root-ca.pem" > "$CA_BUNDLE"
  if ! cmp -s "$OSD_CERT_DIR/ca.crt" "$OSD_CONF/root-ca.pem"; then cat "$OSD_CERT_DIR/ca.crt" >> "$CA_BUNDLE"; fi
  chmod 644 "$CA_BUNDLE"
}

# =============================================================================
# HAProxy ve keepalived (dashboard1, dashboard2)
# =============================================================================

# Dışarıya gösterilen sertifika, bu sunucunun Dashboards sertifikasıdır: aynı CA'dan, ortak adı
# içerir, yalnızca serverAuth. Node sertifikası kopyalanmaz; nodes_dn listesindeki bir sertifikanın
# key'i, kendini cluster node'u gibi tanıtmaya yarar. HAProxy şifreli key okuyamaz, açılmış yazılır.
install_haproxy_certs() {
  local passin=() old
  install -d -m 750 "$HAPROXY_CERT_DIR"
  if [ -n "${DASHBOARDS_KEY_PASSPHRASE:-}" ]; then passin=(-passin env:DASHBOARDS_KEY_PASSPHRASE); fi
  old=$(umask); umask 077
  {
    cat "$OSD_CERT_DIR/ssl.crt"
    echo
    openssl pkey -in "$OSD_CERT_DIR/ssl.key" ${passin[@]+"${passin[@]}"}
  } > "$HAPROXY_CERT_DIR/site.pem"
  umask "$old"
  install -m 640 "$OSD_CERT_DIR/ca.crt" "$HAPROXY_CERT_DIR/dashboards-ca.pem"
  install -m 640 "$OSD_CONF/root-ca.pem" "$HAPROXY_CERT_DIR/opensearch-ca.pem"
  selinux_restore "$HAPROXY_CERT_DIR"
  ok "HAProxy sertifikası kondu ($HAPROXY_CERT_DIR/site.pem, izin 600)"
}

# TLS HAProxy'de sonlanır; arka uçlara yeniden TLS ile, sertifika doğrulanarak bağlanılır.
# Sunucular IP ile yazılır; açılışta isim çözümlemesine bağlı kalınmaz.
write_haproxy_cfg() {
  local i vh=""
  # IP adresi verifyhost ile doğrulanamaz; ortak ad IP ise yalnızca zincir doğrulanır
  if ! valid_ip "$DASHBOARDS_FQDN"; then vh=" verifyhost $DASHBOARDS_FQDN"; fi
  [ -f "$HAPROXY_CONF.orig" ] || cp -p "$HAPROXY_CONF" "$HAPROXY_CONF.orig"
  {
    cat <<EOF
# Kurulum script'leri tarafından üretildi: $(date '+%F %T')
global
    log stderr format short local0 notice
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    maxconn 20000
    ssl-default-bind-options ssl-min-ver TLSv1.2

defaults
    log global
    mode http
    option forwardfor
    option redispatch 1
    retries 3
    timeout http-request 10s
    timeout connect 2s
    timeout check 2s
    timeout client 5m
    timeout server 5m
    default-server inter 2s fall 2 rise 2 check

frontend fe_dashboards
    bind *:$HAPROXY_DASHBOARDS_PORT ssl crt $HAPROXY_CERT_DIR/site.pem alpn h2,http/1.1
    http-request set-header X-Forwarded-Proto https
    default_backend be_dashboards

frontend fe_opensearch
    bind *:$HAPROXY_OPENSEARCH_PORT ssl crt $HAPROXY_CERT_DIR/site.pem
    http-request set-header X-Forwarded-Proto https
    default_backend be_opensearch

# Sticky session gerekmez: iki Dashboards aynı oturum anahtarını kullanır
backend be_dashboards
    balance roundrobin
    option httpchk GET /api/status
    http-check expect rstatus ^(200|401)\$
EOF
    for i in $DASH_IDS; do
      echo "    server $(dash_name "$i") $(dash_ip "$i"):5601 ssl verify required ca-file $HAPROXY_CERT_DIR/dashboards-ca.pem$vh"
    done
    cat <<'EOF'

# 401: kimlik doğrulama istiyor ama çalışıyor; 503: güvenlik modülü hazır değil
backend be_opensearch
    balance leastconn
    option httpchk GET /
    http-check expect rstatus ^(200|401)$
EOF
    for i in $NODE_IDS; do
      echo "    server $(node_name "$i") $(node_ip "$i"):9200 ssl verify required ca-file $HAPROXY_CERT_DIR/opensearch-ca.pem verifyhost $(node_name "$i")"
    done
  } > "$HAPROXY_CONF.new"
  haproxy -c -q -f "$HAPROXY_CONF.new" || die "Üretilen HAProxy ayarı geçersiz: $HAPROXY_CONF.new"
  mv "$HAPROXY_CONF.new" "$HAPROXY_CONF"
  chmod 640 "$HAPROXY_CONF"
  selinux_restore "$HAPROXY_CONF"
  ok "$HAPROXY_CONF yazıldı (:$HAPROXY_DASHBOARDS_PORT -> Dashboards, :$HAPROXY_OPENSEARCH_PORT -> OpenSearch)"
}

# $1 dashboard no. İkisi de BACKUP + nopreempt: sanal IP, düzelen sunucuya geri dönüp
# bağlantıları ikinci kez kesmez. Bazı ağlar multicast taşımadığı için VRRP unicast'tir.
write_keepalived_cfg() {
  local d=$1 name peer_ip ip ifc prefix old
  name=$(dash_name "$d"); ip=$(dash_ip "$d"); peer_ip=$(dash_ip "$((3 - d))")
  read -r ifc prefix < <(ip -4 -o addr show | awk -v ip="$ip" '{split($4, a, "/")} a[1] == ip {print $2, a[2]; exit}')
  [ -n "${ifc:-}" ] || die "$ip adresinin arayüzü bulunamadı"
  [ -f "$KEEPALIVED_CONF.orig" ] || cp -p "$KEEPALIVED_CONF" "$KEEPALIVED_CONF.orig"
  install -d -m 755 "$(dirname "$HAPROXY_CHECK")"
  printf '#!/bin/sh\nexec /usr/bin/systemctl is-active --quiet haproxy\n' > "$HAPROXY_CHECK"
  chmod 700 "$HAPROXY_CHECK"
  old=$(umask); umask 077
  cat > "$KEEPALIVED_CONF.new" <<EOF
# Kurulum script'leri tarafından üretildi: $(date '+%F %T')
global_defs {
    router_id $name
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "$HAPROXY_CHECK"
    interval 2
    fall 2
    rise 2
}

vrrp_instance haproxy_vip {
    state BACKUP
    nopreempt
    interface $ifc
    virtual_router_id $HAPROXY_VRID
    priority $((120 - 10 * d))
    advert_int 1
    unicast_src_ip $ip
    unicast_peer {
        $peer_ip
    }
    virtual_ipaddress {
        $HAPROXY_VIP/$prefix dev $ifc
    }
    track_script {
        chk_haproxy
    }
}
EOF
  umask "$old"
  mv "$KEEPALIVED_CONF.new" "$KEEPALIVED_CONF"
  selinux_restore "$KEEPALIVED_CONF" "$(dirname "$HAPROXY_CHECK")"
  ok "$KEEPALIVED_CONF yazıldı (VIP $HAPROXY_VIP/$prefix, arayüz $ifc, VRID $HAPROXY_VRID)"
}

restart_service() {
  systemctl enable "$1" >/dev/null 2>&1
  if ! systemctl restart "$1"; then
    journalctl -u "$1" -n 40 --no-pager || true
    die "$1 başlatılamadı (yukarıdaki log)"
  fi
  ok "$1 çalışıyor (log: journalctl -u $1)"
}

# Sanal IP, keepalived açıldıktan birkaç saniye sonra sunuculardan birine atanır
wait_vip() {
  local t=0
  until timeout 3 bash -c "</dev/tcp/$HAPROXY_VIP/$HAPROXY_DASHBOARDS_PORT" 2>/dev/null; do
    if [ "$t" -ge 30 ]; then
      journalctl -u keepalived -n 30 --no-pager || true
      die "$HAPROXY_VIP:$HAPROXY_DASHBOARDS_PORT 30 saniyede açılmadı. IP aynı subnet'te ve boş mu, ağ VRRP'ye izin veriyor mu?"
    fi
    sleep 2; t=$((t + 2))
  done
  if ip -4 -o addr show | grep -qF " $HAPROXY_VIP/"; then
    ok "Sanal IP $HAPROXY_VIP bu sunucuda"
  else
    ok "Sanal IP $HAPROXY_VIP diğer sunucuda, buradan erişilebilir"
  fi
}

# $1 dashboard no. Yerel Dashboards'u test eder; diğer dashboard sunucusu çalışıyorsa
# burada açılan oturumun orada da geçerli olduğunu (ortak oturum anahtarı) doğrular
dash_test() {
  local d=$1 vh os_url peer peer_host peer_ip peer_url="" dp=$HAPROXY_DASHBOARDS_PORT op=$HAPROXY_OPENSEARCH_PORT
  [ -s "$OSD_CERT_DIR/ca.crt" ] || die "Dashboards kurulmamış; önce './dashboard$d.sh' çalıştırın"
  step "TLS el sıkışması (https://$DASH_HOST:5601)"
  build_ca_bundle
  if valid_ip "$DASH_HOST"; then vh=-verify_ip; else vh=-verify_hostname; fi
  openssl s_client -connect 127.0.0.1:5601 -servername "$DASH_HOST" "$vh" "$DASH_HOST" \
      -CAfile "$OSD_CERT_DIR/ca.crt" </dev/null 2>/dev/null \
    | grep -E '^(subject|issuer)=|Verify return code' | sed 's/^/      /' || true

  step "Uçtan uca test"
  os_url=$(first_live_node)
  [ -n "$os_url" ] || die "Hiçbir OpenSearch node'unun REST'ine (9200) ulaşılamadı"
  # Diğer dashboard sunucusu (1 <-> 2); LB'den geçmeden IP'sine, ortak adla (sertifika doğrulanarak) bağlanılır
  peer=$((3 - d)); peer_ip=$(dash_ip "$peer"); peer_host=$DASHBOARDS_FQDN
  if timeout 3 bash -c "</dev/tcp/$peer_ip/5601" 2>/dev/null; then
    peer_url="https://$peer_host:5601"
  else
    info "$(dash_name "$peer") ($peer_ip:5601) yanıt vermiyor; çapraz oturum testi atlanacak."
    info "$(dash_name "$peer") kurulunca './dashboard$peer.sh' sonunda bu test yapılır."
  fi
  ask_password ADMIN_PASSWORD "admin şifresi"
  if ADMIN_PASS="$ADMIN_PASSWORD" KS_PASS="${KIBANASERVER_PASSWORD:-}" CA_FILE="$CA_BUNDLE" \
       DASH_URL="https://$DASH_HOST:5601" DASH_RESOLVE="$DASH_HOST:5601:127.0.0.1" OS_URL="$os_url" \
       PEER_DASH_URL="$peer_url" PEER_RESOLVE="$peer_host:5601:$peer_ip" \
       LB_DASH_URL="https://$DASH_HOST:$dp" LB_DASH_RESOLVE="$DASH_HOST:$dp:$HAPROXY_VIP" \
       LB_OS_URL="https://$DASH_HOST:$op" LB_OS_RESOLVE="$DASH_HOST:$op:$HAPROXY_VIP" \
       bash "$SCRIPT_DIR/opensearch-dashboard-test.sh"; then
    ok "Tüm testler başarılı"
  else
    die "Testlerde hata var (yukarıdaki [FAIL] satırları)"
  fi
}

# dashboard1.sh ve dashboard2.sh'in ortak akışı. $2: paket yolu ya da "test"
run_dashboard_node() {
  local d=$1 arg=${2:-} name bundle mode os_url code
  require_root
  load_config
  require_dashboard "$d"
  require_cmds openssl tar sha256sum curl ss timeout
  name=$(dash_name "$d")
  DASH_HOST=$DASHBOARDS_FQDN
  OS_CA_FILE=$OSD_CONF/root-ca.pem
  if [ "$arg" = test ]; then dash_test "$d"; return 0; fi
  bundle=${arg:-$BUNDLE_TARGET_DIR/opensearch-bundle-$name.tar.gz}
  rpm -q opensearch-dashboards haproxy keepalived >/dev/null 2>&1 \
    || die "opensearch-dashboards, haproxy ya da keepalived paketi kurulu değil; önce ./hazirlik.sh çalıştırın"

  open_bundle "$bundle"
  [ -s "$BUNDLE_TMP/$DASH_COOKIE_FILE" ] || die "Pakette $DASH_COOKIE_FILE yok; node1'de './node1.sh certs' ile paketi yeniden üretin"

  mode=$(dash_cert_mode)
  step "Dashboards sertifikaları (mod: $mode)"
  install_dash_certs "$mode" "$name"
  check_dash_certs

  step "Cluster ve kibanaserver kontrolü"
  os_url=$(first_live_node)
  [ -n "$os_url" ] || die "Hiçbir OpenSearch node'unun REST'ine (9200) ulaşılamadı; cluster kurulu mu, node'larda firewall bu sunucuya açık mı?"
  info "OpenSearch: $os_url"
  ask_password KIBANASERVER_PASSWORD "kibanaserver şifresi"
  code=$(http_code_as kibanaserver "$KIBANASERVER_PASSWORD" "$os_url/_plugins/_security/authinfo")
  case "$code" in
    200) ok "kibanaserver OpenSearch'e giriş yapabiliyor" ;;
    401) die "kibanaserver şifresi yanlış (HTTP 401)" ;;
    *)   die "OpenSearch'e ulaşılamadı (HTTP $code); önce node1'de cluster'ı kurun" ;;
  esac

  step "opensearch_dashboards.yml"
  write_dashboards_yml "$name" "$BUNDLE_TMP/$DASH_COOKIE_FILE"

  step "Dashboards başlatılıyor"
  systemctl daemon-reload
  systemctl enable opensearch-dashboards >/dev/null 2>&1
  systemctl restart opensearch-dashboards
  wait_dashboards

  step "HAProxy ve keepalived"
  install_haproxy_certs
  write_haproxy_cfg
  write_keepalived_cfg "$d"
  restart_service haproxy
  restart_service keepalived
  wait_vip
  check_avc

  dash_test "$d"

  step "$name tamamlandı"
  info "Dashboards: https://$DASHBOARDS_FQDN:$HAPROXY_DASHBOARDS_PORT (kullanıcı: admin)"
  info "OpenSearch: https://$DASHBOARDS_FQDN:$HAPROXY_OPENSEARCH_PORT"
  info "DNS: $DASHBOARDS_FQDN -> $HAPROXY_VIP"
  info "DNS hazır olmadan denemek için istemcinin hosts dosyasına: $HAPROXY_VIP $DASHBOARDS_FQDN"
  if [ "$mode" = self ]; then
    info "Sertifika cluster'ın root CA'sıyla imzalandı. Tarayıcı uyarısı olmaması için"
    info "node1'deki $CERT_WORKDIR/root-ca.pem dosyasını istemcilere güvenilir kök sertifika olarak dağıtın."
  fi
  info "Paket private key ve oturum anahtarı içerir; silin: rm -f $bundle"
}
