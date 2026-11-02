#!/usr/bin/env bash
# Ortak hazırlık: 5 node'da ve 2 dashboard sunucusunda çalıştırılır. Sunucunun hangisi
# olduğunu IP'sinden bulur.
#
# Tüm sunucular:
#   - ufw durum kontrolü, saat senkronu
#   - /etc/hosts (node1-5, dashboard1-2)
# OpenSearch node'ları:
#   - swap, vm.max_map_count, /data kontrolü
#   - OpenSearch DEB kurulumu (imza doğrulamalı, demo güvenlik ayarları olmadan)
#   - /data/opensearch ve /data/logs dizinleri, systemd override
#   - ufw etkinse 9200 ve 9300 kuralları
# Dashboards sunucuları:
#   - OpenSearch Dashboards DEB kurulumu (imza doğrulamalı)
#   - HAProxy ve keepalived kurulumu (apt deposundan)
#   - ufw etkinse 5601, HAProxy portları ve VRRP kuralları
#
# Servisler BAŞLATILMAZ; başlatma nodeN.sh / dashboardN.sh içinde yapılır.
# Tekrar çalıştırılabilir; yapılmış adımları atlar.
#
# Kullanım: ./hazirlik.sh            hazırlık ve kurulum
#           ./hazirlik.sh --check    yalnızca kontrol, değişiklik yapmaz
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

CHECK_ONLY=no
case "${1:-}" in
  "")        ;;
  --check)   CHECK_ONLY=yes ;;
  -h|--help) usage; exit 0 ;;
  *)         die "Bilinmeyen parametre: $1 (--check ya da parametresiz)" ;;
esac

# =============================================================================
# Kontroller (değişiklik yapmaz)
# =============================================================================

check_os() {
  local id ver
  id=$(. /etc/os-release && echo "${ID:-}")
  ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  if [ "$id" = ubuntu ] && [[ $ver == 24.04* ]]; then
    ok "İşletim sistemi: $(. /etc/os-release && echo "${PRETTY_NAME:-Ubuntu $ver}")"
  else
    warn "İşletim sistemi Ubuntu 24.04 değil ($id $ver); script'ler Ubuntu 24.04 için yazıldı"
  fi
  [ -n "$DEB_ARCH" ] || die "Desteklenmeyen mimari: $(uname -m) (x86_64 ya da aarch64 olmalı)"
}

check_pkg_files() {
  local pkg=opensearch deb=$OS_DEB
  if [ "$ROLE" = dashboard ]; then pkg=opensearch-dashboards; deb=$OSD_DEB; fi
  if pkg_installed "$pkg"; then
    ok "$pkg paketi kurulu ($(dpkg-query -W -f='${Version}' "$pkg"))"
  elif [ -s "$deb" ]; then
    ok "DEB mevcut: $deb"
    if [ "$VERIFY_DEB_SIGNATURE" = yes ]; then
      [ -s "$deb.sig" ] || die "$deb.sig yok (ya da config.env'de VERIFY_DEB_SIGNATURE=no)"
      [ -s "$GPG_KEY_FILE" ] || die "$GPG_KEY_FILE yok"
    fi
  else
    die "$deb bulunamadı"
  fi
}

report_firewall() {
  if ufw_on; then
    info "ufw etkin: $FW_PORTS kuralları eklenecek"
  elif command -v ufw >/dev/null 2>&1; then
    info "ufw etkin değil: port kuralı eklenmeyecek. Sonradan etkinleştirilirse önce ./hazirlik.sh tekrar çalıştırılmalı"
  else
    info "ufw kurulu değil: port kuralı eklenmeyecek"
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null || systemctl is-active --quiet nftables 2>/dev/null; then
    warn "firewalld ya da nftables servisi aktif; $FW_PORTS için kendi kurallarınızı kontrol edin"
  fi
  info "Aradaki ağ firewall'larında 9200/9300 (node'lar arası), 9200 (dashboard -> node), 5601 ve VRRP (dashboard'lar arası) ve kullanıcılardan sanal IP'ye HAProxy portları açık olmalı."
}

# Ubuntu varsayılan olarak systemd-timesyncd kullanır; chrony de olabilir
check_time() {
  if command -v chronyc >/dev/null 2>&1; then
    if grep -q 'Leap status *: Normal' <<<"$(chronyc tracking 2>/dev/null || true)"; then
      ok "Saat senkron (chrony)"
    else
      warn "chrony senkron görünmüyor ('chronyc tracking'); node saatleri aynı olmalı"
    fi
  elif [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" = yes ]; then
    ok "Saat senkron (timedatectl)"
  else
    warn "Saat senkron görünmüyor ('timedatectl status'); node saatleri aynı olmalı"
  fi
}

check_data_mount() {
  local src
  src=$(findmnt -n -o SOURCE /data 2>/dev/null || true)
  if [ -n "$src" ]; then
    ok "/data ayrı mount: $src ($(findmnt -n -o FSTYPE /data))"
    findmnt --fstab /data >/dev/null 2>&1 || warn "/data /etc/fstab'da kayıtlı değil; reboot sonrası takılmayabilir"
  elif [ "$REQUIRE_DATA_MOUNT" = yes ]; then
    die "/data ayrı bir mount değil (REQUIRE_DATA_MOUNT=yes)"
  else
    warn "/data ayrı bir mount değil; veri kök disk üzerinde tutulacak"
  fi
  if [ -d /data ]; then info "Boş alan: $(df -hP /data | awk 'NR==2 {print $4 " / " $2}')"; fi
}

check_kernel() {
  local cur
  cur=$(sysctl -n vm.max_map_count)
  if [ "$cur" -ge 262144 ]; then ok "vm.max_map_count=$cur"; else info "vm.max_map_count=$cur (262144'e yükseltilecek)"; fi
  if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then info "Swap açık (kapatılacak)"; else ok "Swap kapalı"; fi
}

tmp_noexec() {
  local opts
  opts=$(findmnt -n -o OPTIONS --target /tmp 2>/dev/null || true)
  [[ ,$opts, == *,noexec,* ]]
}

check_tmp() {
  if tmp_noexec; then
    info "/tmp noexec bağlı (sıkılaştırma); OpenSearch geçici dizini $OS_TMPDIR yapılacak"
  else
    ok "/tmp noexec değil"
  fi
}

# $1 portları kullanması beklenen servis, $2... portlar
check_ports_free() {
  local p svc=$1
  shift
  for p in "$@"; do
    port_listening "$p" || continue
    if systemctl is-active --quiet "$svc"; then
      warn "$svc servisi zaten çalışıyor (port $p dinleniyor); daha önce kurulmuş olabilir"
      return 0
    fi
    die "Port $p başka bir süreç tarafından kullanılıyor: $(ss -ltnpH "( sport = :$p )" | head -1)"
  done
}

# =============================================================================
# Değişiklik yapan adımlar
# =============================================================================

do_hostname() {
  [ "$SET_HOSTNAME" = yes ] || { info "SET_HOSTNAME=no, hostname değiştirilmedi ($(hostname))"; return 0; }
  if [ "$(hostname)" = "$SERVER_NAME" ]; then ok "hostname zaten $SERVER_NAME"
  else hostnamectl set-hostname "$SERVER_NAME"; ok "hostname $SERVER_NAME yapıldı"; fi
}

do_hosts() {
  local tmp p v name ip r names=""
  tmp=$(mktemp)
  for p in $(server_vars); do v="${p}_NAME"; names+=" ${!v}"; done
  # Ubuntu sunucu adını 127.0.1.1'e yazar. Bu satır kalırsa ad gerçek IP yerine ona çözülür; yorum satırı yapılır
  awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" -v names="$names" '
    BEGIN {n = split(names, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1}
    $0 == b {skip = 1; next}
    $0 == e {skip = 0; next}
    skip {next}
    $1 == "127.0.1.1" {for (i = 2; i <= NF; i++) if ($i in s) {print "# " $0 "  # kurulum script: sunucu adı gerçek IP-ye çözülmeli"; next}}
    {print}' /etc/hosts > "$tmp"
  {
    echo "$HOSTS_BEGIN"
    for p in $(server_vars); do
      v="${p}_IP"; ip=${!v}; v="${p}_NAME"; name=${!v}
      echo "$ip $name"
    done
    echo "$HOSTS_END"
  } >> "$tmp"

  if cmp -s "$tmp" /etc/hosts; then
    info "/etc/hosts güncel"
  else
    cp -p /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    cat "$tmp" > /etc/hosts       # inode korunur (bind mount ve symlink bozulmaz)
    ok "/etc/hosts güncellendi (yedek: /etc/hosts.bak.*)"
  fi
  rm -f "$tmp"
  awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '$0 == b {p = 1} p {print "      " $0} $0 == e {p = 0}' /etc/hosts

  # Dosyada daha önce aynı isme farklı IP veren satır varsa o kazanır; kontrol et
  for p in $(server_vars); do
    v="${p}_IP"; ip=${!v}; v="${p}_NAME"; name=${!v}
    r=$(getent ahostsv4 "$name" | awk 'NR == 1 {print $1}' || true)
    [ "$r" = "$ip" ] || die "$name -> ${r:-çözülemedi} (beklenen $ip); /etc/hosts ya da DNS'te çakışan kaydı düzeltin"
  done
  ok "Node ve dashboard isimleri doğru IP'lere çözülüyor"

  # cloud-init /etc/hosts'u her açılışta yeniden yazarsa node kayıtları silinir ve cluster dağılır
  if grep -qsE '^[[:space:]]*manage_etc_hosts:[[:space:]]*(true|True|localhost)' /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/*.cfg; then
    warn "cloud-init /etc/hosts'u yönetiyor (manage_etc_hosts); reboot'ta node kayıtları silinir."
    warn "Kayıtları /etc/cloud/templates/hosts.debian.tmpl dosyasına ya da DNS'e de ekleyin."
  fi
}

do_swap_sysctl() {
  if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
    swapoff -a
    ok "Swap kapatıldı"
  fi
  if [ -f /etc/fstab ] && grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
    cp -p /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
    ok "/etc/fstab içindeki swap satırı yorum satırı yapıldı"
  fi
  if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then warn "Swap hâlâ açık: $(swapon --show --noheadings | head -1)"; fi

  if [ "$(sysctl -n vm.max_map_count)" -lt 262144 ]; then
    echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf
    sysctl -q --system
    ok "vm.max_map_count=262144 (/etc/sysctl.d/99-opensearch.conf)"
  fi
}

do_install_deb() {
  if [ "$ROLE" = dashboard ]; then
    install_deb opensearch-dashboards "$OSD_DEB"
  else
    install_deb opensearch "$OS_DEB"
  fi
  systemctl daemon-reload
  # Servis yapılandırma bitmeden enable edilmez; arada reboot olursa eksik ayarla başlamasın.
  # nodeN.sh / dashboardN.sh yapılandırmadan sonra enable edip başlatır.
  info "Servis başlatılmadı; ./$SERVER_SCRIPT yapılandırıp başlatacak"
}

do_dirs() {
  local d
  if [ -d /data ]; then chmod o+x /data; fi
  for d in "$DATA_DIR" "$LOG_DIR"; do
    mkdir -p "$d"
    chown -R opensearch:opensearch "$d"
    chmod 750 "$d"
  done
  ok "$DATA_DIR ve $LOG_DIR hazır (opensearch:opensearch, 750)"
  if [ -n "$(ls -A "$DATA_DIR")" ]; then
    warn "$DATA_DIR boş değil. Yeni kurulumsa ve eski bir cluster'a aitse, servisi başlatmadan önce içeriği temizleyin."
  fi
}

do_install_lb_pkgs() {
  if pkg_installed haproxy keepalived; then
    ok "haproxy $(dpkg-query -W -f='${Version}' haproxy), keepalived $(dpkg-query -W -f='${Version}' keepalived) zaten kurulu"
    return 0
  fi
  apt-get update -qq || warn "apt-get update başarısız; mevcut paket listesiyle devam ediliyor"
  apt_install haproxy keepalived \
    || die "haproxy ve keepalived kurulamadı; Ubuntu deposuna (ya da yerel aynaya) erişim gerekir"
  # Paket kurulunca servisler enable olup başlar; dashboardN.sh yapılandırana kadar kapalı kalırlar
  systemctl disable --now haproxy keepalived >/dev/null 2>&1 || true
  ok "haproxy ve keepalived kuruldu; servisler ./$SERVER_SCRIPT ile başlayacak"
}

# /tmp noexec ise OpenSearch JNA kütüphanesini oradan yükleyemez ve açılmaz;
# geçici dizin paketin kendi dizinine alınır (unit dosyasında zaten yazılabilir)
do_tmpdir() {
  local conf=/etc/default/opensearch
  if ! tmp_noexec; then
    info "/tmp noexec değil; OpenSearch varsayılan geçici dizini kullanacak"
    return 0
  fi
  install -d -o opensearch -g opensearch -m 750 "$OS_TMPDIR"
  touch "$conf"
  if grep -q '^OPENSEARCH_TMPDIR=' "$conf"; then
    sed -i "s|^OPENSEARCH_TMPDIR=.*|OPENSEARCH_TMPDIR=$OS_TMPDIR|" "$conf"
  else
    printf '\n# /tmp noexec olduğu için eklendi (hazirlik.sh)\nOPENSEARCH_TMPDIR=%s\n' "$OS_TMPDIR" >> "$conf"
  fi
  ok "/tmp noexec: OPENSEARCH_TMPDIR=$OS_TMPDIR ($conf)"
}

do_systemd_override() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
# Kurulum script'leri tarafından üretildi
[Unit]
# /data takılamadığı bir açılışta OpenSearch kök diske yazmasın
RequiresMountsFor=/data

[Service]
# Unit dosyasında dosya sistemi kısıtlaması varsa yeni dizinleri yazılabilir yapar
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
EOF
  mkdir -p "$(dirname "$OS_OVERRIDE")"
  if cmp -s "$tmp" "$OS_OVERRIDE"; then
    info "systemd override güncel"
  else
    install -m 644 "$tmp" "$OS_OVERRIDE"
    systemctl daemon-reload
    ok "systemd override yazıldı: $OS_OVERRIDE"
  fi
  rm -f "$tmp"
}

# $1 port, $2 boşlukla ayrılmış CIDR'lar (boşsa herkese açık). Kısıtlıysa dashboard'lar
# da eklenir: dashboardN.sh, sanal IP diğer sunucudayken ona kendi IP'sinden bağlanıp test eder
fw_allow_sources() {
  local src i
  if [ -z "$2" ]; then fw_allow "$1" ""; return 0; fi
  for i in $DASH_IDS; do fw_allow "$1" "$(dash_ip "$i")/32"; done
  for src in $2; do fw_allow "$1" "$src"; done
}

do_firewall() {
  local i src
  if ! ufw_on; then
    info "ufw etkin değil, $FW_PORTS kuralı eklenmedi"
    return 0
  fi
  if [ "$ROLE" = dashboard ]; then
    # 5601 yalnızca iki dashboard sunucusuna: HAProxy'ler ve çapraz oturum testi buradan bağlanır
    for i in $DASH_IDS; do fw_allow 5601 "$(dash_ip "$i")/32"; done
    fw_allow_sources "$HAPROXY_DASHBOARDS_PORT" "$DASHBOARDS_ALLOWED_SOURCES"
    fw_allow_sources "$HAPROXY_OPENSEARCH_PORT" "$OPENSEARCH_LB_ALLOWED_SOURCES"
    for i in $DASH_IDS; do
      if [ "$i" != "$SERVER_ID" ]; then fw_allow_vrrp "$(dash_ip "$i")/32"; fi
    done
  else
    # 9300 yalnızca node'lar arası; 9200 node'lar + dashboard sunucuları + HTTP_ALLOWED_SOURCES
    for i in $NODE_IDS; do
      src="$(node_ip "$i")/32"
      fw_allow 9300 "$src"
      fw_allow 9200 "$src"
    done
    for i in $DASH_IDS; do fw_allow 9200 "$(dash_ip "$i")/32"; done
    for src in $HTTP_ALLOWED_SOURCES; do fw_allow 9200 "$src"; done
  fi
  if [ "$ROLE" = node ] && [ -z "$HTTP_ALLOWED_SOURCES" ]; then
    info "Uygulama sunucuları node'lara doğrudan erişecekse config.env'de HTTP_ALLOWED_SOURCES'a ekleyip tekrar çalıştırın"
  fi
}

# =============================================================================

require_root
# Tüm script'lerin her sunucuda kullandığı komutlar. Sunucu tespiti de bunlara ihtiyaç duyar
# (ip gibi); eksikse sonradan yanıltıcı hata vermesin diye en başta kontrol edilir.
require_cmds apt-get awk basename cat chmod chown cmp cp curl cut date diff dirname dpkg-query findmnt \
  getent grep gzip head hostname id install ip journalctl ls mkdir mktemp mv openssl rm sed \
  sha256sum sleep sort ss systemctl tail tar timeout touch tr uname uniq
load_config
# Sunucu rolü: node (OpenSearch) ya da dashboard (OpenSearch Dashboards)
SERVER_ID=$(detect_node_id)
if [ -n "$SERVER_ID" ]; then
  ROLE=node
  SERVER_NAME=$(node_name "$SERVER_ID"); SERVER_IP=$(node_ip "$SERVER_ID")
  SERVER_SCRIPT="node$SERVER_ID.sh"; FW_PORTS="9200/9300"; ROLE_LABEL="OpenSearch node"
else
  SERVER_ID=$(detect_dash_id)
  [ -n "$SERVER_ID" ] || die "Bu sunucunun IP'leri ($(local_ips | tr '\n' ' ')) config.env'deki node / dashboard IP'leriyle eşleşmiyor"
  ROLE=dashboard
  SERVER_NAME=$(dash_name "$SERVER_ID"); SERVER_IP=$(dash_ip "$SERVER_ID")
  SERVER_SCRIPT="dashboard$SERVER_ID.sh"; ROLE_LABEL="Dashboards sunucusu"
  FW_PORTS="5601/$HAPROXY_DASHBOARDS_PORT/$HAPROXY_OPENSEARCH_PORT"
fi

step "Ön kontroller: $SERVER_NAME ($SERVER_IP, $ROLE_LABEL)"
check_os
# Role ve ayarlara göre gereken komutlar. python3 ve chronyc burada yok: yoksa ilgili adım
# başka yolla ya da uyarıyla devam eder.
extra_cmds=()
if [ "$ROLE" = node ]; then extra_cmds+=(df swapoff swapon sysctl); fi
if [ "$SERVER_SCRIPT" = node1.sh ] && [ "$DISTRIBUTE_WITH_SCP" = yes ]; then extra_cmds+=(scp); fi
if [ "$VERIFY_DEB_SIGNATURE" = yes ]; then extra_cmds+=(gpg); fi
if [ "$ADD_CA_TO_SYSTEM_TRUST" = yes ]; then extra_cmds+=(update-ca-certificates); fi
if [ "$SET_HOSTNAME" = yes ]; then extra_cmds+=(hostnamectl); fi
require_cmds ${extra_cmds[@]+"${extra_cmds[@]}"}
check_pkg_files
if [ "$ROLE" = node ]; then
  check_ports_free opensearch 9200 9300
else
  check_ports_free opensearch-dashboards 5601
  check_ports_free haproxy "$HAPROXY_DASHBOARDS_PORT" "$HAPROXY_OPENSEARCH_PORT"
fi

step "Firewall (ufw)"
report_firewall

step "Sistem kontrolleri"
check_time
if [ "$ROLE" = node ]; then
  check_data_mount
  check_kernel
  check_tmp
fi

if [ "$CHECK_ONLY" = yes ]; then
  step "Yalnızca kontrol yapıldı (--check); değişiklik yapılmadı"
  exit 0
fi

step "Hostname ve /etc/hosts"
do_hostname
do_hosts

if [ "$ROLE" = node ]; then
  step "Swap ve kernel ayarı"
  do_swap_sysctl

  step "OpenSearch DEB kurulumu"
  do_install_deb

  step "Data, log ve geçici dizinler"
  do_dirs
  do_tmpdir

  step "systemd override"
  do_systemd_override
else
  step "OpenSearch Dashboards DEB kurulumu"
  do_install_deb

  step "HAProxy ve keepalived kurulumu"
  do_install_lb_pkgs
fi

step "Firewall ($FW_PORTS)"
do_firewall

step "$SERVER_NAME hazırlığı tamamlandı"
case "$SERVER_SCRIPT" in
  node1.sh) info "Sonraki adım (5 node'un hazırlığı bitince): ./node1.sh" ;;
  node*)    info "Sonraki adım: node1.sh paketi gönderdikten sonra ./$SERVER_SCRIPT" ;;
  *)        info "Sonraki adım: node1.sh cluster'ı kurup paketi gönderdikten sonra ./$SERVER_SCRIPT" ;;
esac
