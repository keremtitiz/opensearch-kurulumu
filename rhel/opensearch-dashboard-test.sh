#!/usr/bin/env bash
# OpenSearch Dashboards uçtan uca test
#
# dashboard1.sh / dashboard2.sh'in sonunda otomatik çalışır. Elle çalıştırmak için
# dashboard sunucusunda (root) './dashboard1.sh test' ya da './dashboard2.sh test' kullanın;
# adresleri ve diğer Dashboards'u kendisi bulur. Doğrudan da çalıştırılabilir:
#   bash opensearch-dashboard-test.sh                          # admin şifresini sorar
#   KS_PASS='<kibanaserver şifresi>' bash opensearch-dashboard-test.sh
#
# Varsayılanlar aynı dizindeki config.env'den alınır. Ortam değişkenleriyle değiştirilebilir:
#   DASH_URL       Dashboards adresi      (varsayılan: https://<DASHBOARDS_FQDN>:<HAPROXY_DASHBOARDS_PORT>)
#   DASH_RESOLVE   DASH_URL için curl --resolve değeri, ör. "dash.sirket.local:5601:127.0.0.1"
#   OS_URL         OpenSearch adresi      (varsayılan: https://<NODE1_NAME>:9200)
#   CA_FILE        CA dosyası             (varsayılan: /root/opensearch-ca-bundle.pem)
#   ADMIN_USER     Admin kullanıcı adı    (varsayılan: admin)
#   ADMIN_PASS     Admin şifresi          (verilmezse sorulur)
#   KS_PASS        kibanaserver şifresi   (verilirse ayrıca test edilir)
#   PEER_DASH_URL  Diğer Dashboards adresi; verilirse DASH_URL'de açılan oturumun orada da
#                  geçerli olduğu test edilir (iki sunucuda ortak oturum anahtarı)
#   PEER_RESOLVE   PEER_DASH_URL için curl --resolve değeri
#   LB_DASH_URL    HAProxy'nin Dashboards adresi; verilirse sanal IP üzerinden erişim test edilir
#   LB_DASH_RESOLVE LB_DASH_URL için curl --resolve değeri
#   LB_OS_URL      HAProxy'nin OpenSearch adresi
#   LB_OS_RESOLVE  LB_OS_URL için curl --resolve değeri
#
# Bir test başarısız olursa sıfırdan farklı bir çıkış koduyla döner; izleme ya da cron
# içinde de kullanılabilir.

set -u

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -r "$_dir/config.env" ]; then
  # shellcheck source=config.env
  . "$_dir/config.env"
fi
DASH_URL="${DASH_URL:-https://${DASHBOARDS_FQDN:-localhost}:${HAPROXY_DASHBOARDS_PORT:-443}}"
DASH_RESOLVE="${DASH_RESOLVE:-}"
OS_URL="${OS_URL:-https://${NODE1_NAME:-localhost}:9200}"
CA_FILE="${CA_FILE:-/root/opensearch-ca-bundle.pem}"
ADMIN_USER="${ADMIN_USER:-admin}"
KS_PASS="${KS_PASS:-}"
PEER_DASH_URL="${PEER_DASH_URL:-}"
PEER_RESOLVE="${PEER_RESOLVE:-}"
LB_DASH_URL="${LB_DASH_URL:-}"
LB_DASH_RESOLVE="${LB_DASH_RESOLVE:-}"
LB_OS_URL="${LB_OS_URL:-}"
LB_OS_RESOLVE="${LB_OS_RESOLVE:-}"

if [ -z "${ADMIN_PASS:-}" ]; then
  read -rsp "${ADMIN_USER} şifresi: " ADMIN_PASS
  echo
fi

PASSED=0
FAILED=0
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
info() { printf '         %s\n' "$1"; }

CURL=(curl -sS --max-time 10)
if [ -r "$CA_FILE" ]; then
  CURL+=(--cacert "$CA_FILE")
else
  echo "Uyarı: $CA_FILE okunamadı, TLS doğrulaması kapatılıyor (-k)."
  CURL+=(-k)
fi
# Dashboards (DCURL) ve diğer Dashboards (PCURL) istekleri, verilmişse --resolve ile
DCURL=("${CURL[@]}")
if [ -n "$DASH_RESOLVE" ]; then DCURL+=(--resolve "$DASH_RESOLVE"); fi
PCURL=("${CURL[@]}")
if [ -n "$PEER_RESOLVE" ]; then PCURL+=(--resolve "$PEER_RESOLVE"); fi
LDCURL=("${CURL[@]}")
if [ -n "$LB_DASH_RESOLVE" ]; then LDCURL+=(--resolve "$LB_DASH_RESOLVE"); fi
LOCURL=("${CURL[@]}")
if [ -n "$LB_OS_RESOLVE" ]; then LOCURL+=(--resolve "$LB_OS_RESOLVE"); fi

JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

# Kullanıcı/şifreyi curl'e stdin'den verir (curl -K -); şifre ps çıktısında görünmez
auth() { local p=${2//\\/\\\\}; p=${p//\"/\\\"}; printf 'user = "%s:%s"\n' "$1" "$p"; }

# Verilen curl komutunu çalıştırıp HTTP durum kodunu döndürür (bağlantı hatasında 000).
# Ör: code_of "${DCURL[@]}" "$DASH_URL/api/status"
code_of() {
  local c
  c=$("$@" -o /dev/null -w '%{http_code}' 2>/dev/null)
  echo "${c:-000}"
}

# Login gövdesi: {"username": ..., "password": ...}
login_payload() {
  if [ "$HAVE_PY" -eq 1 ]; then
    U="$1" P="$2" python3 -I -c \
      'import json, os; print(json.dumps({"username": os.environ["U"], "password": os.environ["P"]}))'
  else
    printf '{"username":"%s","password":"%s"}' "$1" "$2"
  fi
}

HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1

echo
echo "Dashboards : $DASH_URL${DASH_RESOLVE:+ (--resolve $DASH_RESOLVE)}"
echo "OpenSearch : $OS_URL"
if [ -n "$PEER_DASH_URL" ]; then echo "Diğer      : $PEER_DASH_URL${PEER_RESOLVE:+ (--resolve $PEER_RESOLVE)}"; fi
echo

# ---------------------------------------------------------------------------
echo "== 1. Servis =="
if systemctl cat opensearch-dashboards >/dev/null 2>&1; then
  if systemctl is-active --quiet opensearch-dashboards; then
    ok "opensearch-dashboards servisi çalışıyor"
  else
    fail "opensearch-dashboards servisi çalışmıyor (journalctl -u opensearch-dashboards)"
  fi
else
  info "Bu makinede opensearch-dashboards servisi yok, servis kontrolü atlandı"
fi

# ---------------------------------------------------------------------------
echo "== 2. Erişim ve kimlik doğrulama zorunluluğu =="
c=$(code_of "${DCURL[@]}" "$DASH_URL/api/status")
case "$c" in
  401|302) ok "Dashboards erişilebilir; kimlik doğrulama zorunlu (HTTP $c)" ;;
  200)     ok "Dashboards erişilebilir (HTTP 200)"; info "Not: /api/status kimlik doğrulamasız açık" ;;
  000)     fail "Dashboards'a bağlanılamadı: servisi, 5601 portunu, firewall'u ve sertifikayı kontrol edin" ;;
  *)       fail "Beklenmeyen yanıt: HTTP $c" ;;
esac

# ---------------------------------------------------------------------------
echo "== 3. Durum API'si (admin ile) =="
body=$(auth "$ADMIN_USER" "$ADMIN_PASS" | "${DCURL[@]}" -K - "$DASH_URL/api/status" 2>/dev/null)
if [ "$HAVE_PY" -eq 1 ]; then
  parsed=$(printf '%s' "$body" | python3 -I -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("PARSE_ERROR")
    sys.exit()
st = d.get("status", {})
o = st.get("overall", {})
state = o.get("state") or o.get("level") or "unknown"
ver = d.get("version", {}).get("number", "?")
bad = [str(s.get("id", "?")) + "=" + str(s.get("state"))
       for s in st.get("statuses", []) if s.get("state") not in (None, "green")]
print(state, ver, ";".join(bad))
')
else
  state=$(printf '%s' "$body" | grep -o '"state":"[a-z]*"' | head -1 | cut -d'"' -f4)
  parsed="${state:-unknown} ?"
fi
read -r st ver bad <<<"$parsed"
case "${st:-}" in
  green|available) ok "Genel durum: $st (sürüm $ver)" ;;
  PARSE_ERROR|"")  fail "Durum alınamadı. Yanıt: $(printf '%s' "$body" | head -c 200)" ;;
  *)               fail "Genel durum: $st (sürüm ${ver:-?}); admin şifresini ve Dashboards loglarını kontrol edin" ;;
esac
[ -n "${bad:-}" ] && info "Yeşil olmayan bileşenler: ${bad//;/, }"

# ---------------------------------------------------------------------------
echo "== 4. Login akışı (tarayıcı girişiyle aynı) =="
c=$(login_payload "$ADMIN_USER" "$ADMIN_PASS" \
      | code_of "${DCURL[@]}" -c "$JAR" -X POST "$DASH_URL/auth/login" \
          -H 'osd-xsrf: true' -H 'Content-Type: application/json' --data-binary @-)
if [ "$c" = "200" ] && grep -q 'security_authentication' "$JAR"; then
  ok "Login başarılı, oturum cookie'si alındı"
  c=$(code_of "${DCURL[@]}" -b "$JAR" "$DASH_URL/api/status")
  if [ "$c" = "200" ]; then
    ok "Cookie ile yetkili istek başarılı"
  else
    fail "Cookie ile istek başarısız (HTTP $c)"
  fi
else
  fail "Login başarısız (HTTP $c)"
fi

c=$(login_payload "$ADMIN_USER" "yanlis-sifre-$$" \
      | code_of "${DCURL[@]}" -X POST "$DASH_URL/auth/login" \
          -H 'osd-xsrf: true' -H 'Content-Type: application/json' --data-binary @-)
if [ "$c" = "401" ]; then
  ok "Yanlış şifre reddedildi (HTTP 401)"
else
  fail "Yanlış şifre için beklenmeyen yanıt: HTTP $c"
fi

# ---------------------------------------------------------------------------
echo "== 5. OpenSearch tarafı =="
hbody=$(auth "$ADMIN_USER" "$ADMIN_PASS" | "${CURL[@]}" -K - "$OS_URL/_cluster/health" 2>/dev/null)
health=$(printf '%s' "$hbody" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4)
nodes=$(printf '%s' "$hbody" | grep -o '"number_of_nodes":[0-9]*' | cut -d: -f2)
case "$health" in
  green)  ok "Cluster health: green (${nodes:-?} node)" ;;
  yellow) fail "Cluster health: yellow (atanmamış replica shard var)" ;;
  red)    fail "Cluster health: red (atanmamış primary shard var)" ;;
  *)      fail "Cluster health alınamadı ($OS_URL)" ;;
esac

if [ -n "$KS_PASS" ]; then
  c=$(auth kibanaserver "$KS_PASS" | code_of "${CURL[@]}" -K - "$OS_URL/_plugins/_security/authinfo")
  if [ "$c" = "200" ]; then
    ok "kibanaserver kullanıcısı OpenSearch'e giriş yapabiliyor"
  else
    fail "kibanaserver girişi başarısız (HTTP $c): şifreyi ve internal_users.yml'yi kontrol edin"
  fi
else
  info "KS_PASS verilmedi, kibanaserver testi atlandı"
fi

idx=$(auth "$ADMIN_USER" "$ADMIN_PASS" | "${CURL[@]}" -K - \
        "$OS_URL/_cat/indices/.kibana*?h=index,health&expand_wildcards=all" 2>/dev/null)
if [ -n "$idx" ] && ! printf '%s' "$idx" | grep -q '"error"'; then
  ok "Dashboards index'leri mevcut:"
  printf '%s\n' "$idx" | sed 's/^/           /'
else
  info "Henüz .kibana index'i yok; ilk tarayıcı girişinden sonra oluşur"
fi

# ---------------------------------------------------------------------------
echo "== 6. Yedek Dashboards (oturum paylaşımı) =="
if [ -z "$PEER_DASH_URL" ]; then
  info "PEER_DASH_URL verilmedi (diğer Dashboards henüz kurulmamış olabilir), atlandı"
else
  c=$(code_of "${PCURL[@]}" "$PEER_DASH_URL/api/status")
  case "$c" in
    401|302|200) ok "Diğer Dashboards erişilebilir (HTTP $c)" ;;
    *)           fail "Diğer Dashboards'a bağlanılamadı (HTTP $c): servisi, 5601'i ve sertifikasını kontrol edin" ;;
  esac
  # Login'de alınan oturum cookie'leri (cookie jar'da HttpOnly satırları '#HttpOnly_' ile başlar)
  cookies=$(awk -F'\t' 'NF >= 7 && $6 ~ /^security_authentication/ {printf "%s%s=%s", sep, $6, $7; sep = "; "}' "$JAR")
  if [ -z "$cookies" ]; then
    fail "Oturum cookie'si yok (login başarısız); çapraz oturum testi yapılamadı"
  else
    c=$(code_of "${PCURL[@]}" -b "$cookies" "$PEER_DASH_URL/api/status")
    if [ "$c" = "200" ]; then
      ok "Bu Dashboards'ta açılan oturum diğerinde de geçerli (ortak oturum anahtarı)"
    else
      fail "Oturum diğer Dashboards'ta geçersiz (HTTP $c): iki sunucuda opensearch_security.cookie.password aynı olmalı"
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo "== 7. HAProxy (sanal IP üzerinden, HAProxy sertifikası ortak adla doğrulanarak) =="
if [ -z "$LB_DASH_URL" ] || [ -z "$LB_OS_URL" ]; then
  info "LB_DASH_URL / LB_OS_URL verilmedi, atlandı"
else
  c=$(code_of "${LDCURL[@]}" "$LB_DASH_URL/api/status")
  case "$c" in
    401|302|200) ok "Dashboards HAProxy üzerinden erişilebilir: $LB_DASH_URL (HTTP $c)" ;;
    *)           fail "Dashboards HAProxy üzerinden yanıt vermedi: HTTP $c (journalctl -u haproxy, sertifika SAN'ı)" ;;
  esac
  c=$(login_payload "$ADMIN_USER" "$ADMIN_PASS" \
        | code_of "${LDCURL[@]}" -X POST "$LB_DASH_URL/auth/login" \
            -H 'osd-xsrf: true' -H 'Content-Type: application/json' --data-binary @-)
  if [ "$c" = "200" ]; then
    ok "HAProxy üzerinden login başarılı"
  else
    fail "HAProxy üzerinden login başarısız (HTTP $c)"
  fi
  hbody=$(auth "$ADMIN_USER" "$ADMIN_PASS" | "${LOCURL[@]}" -K - "$LB_OS_URL/_cluster/health" 2>/dev/null)
  nodes=$(printf '%s' "$hbody" | grep -o '"number_of_nodes":[0-9]*' | cut -d: -f2)
  if [ -n "$nodes" ]; then
    ok "OpenSearch HAProxy üzerinden erişilebilir: $LB_OS_URL ($nodes node)"
  else
    fail "OpenSearch HAProxy üzerinden yanıt vermedi (journalctl -u haproxy; sertifika ortak adı içeriyor mu?)"
  fi
fi

# ---------------------------------------------------------------------------
echo
echo "Sonuç: $PASSED başarılı, $FAILED başarısız"
[ "$FAILED" -eq 0 ]
