# OpenSearch 5 Node Cluster + Yedekli Dashboards ve HAProxy Kurulum Script'leri (RHEL 10.1)

Bu script'ler 5 node'lu bir OpenSearch 3.9 cluster'ını ve ayrı iki sunucuda (dashboard1, dashboard2) yedekli OpenSearch Dashboards ile HAProxy'yi kurar. Demo güvenlik ayarları kullanılmaz; sertifikalar kurulum sırasında üretilen kendi CA'mızla imzalanır.

- Node'lar arası (9300) ve REST (9200) trafiği TLS'lidir. Dışarıdan gelen TLS HAProxy'de sonlanır, HAProxy arka uçlara yeniden TLS ile bağlanır.
- Dışarıdan tek adres vardır: `https://<DASHBOARDS_FQDN>` Dashboards'a (443), `https://<DASHBOARDS_FQDN>:9200` OpenSearch node'larına gider (bkz. [HAProxy ve sanal IP](#haproxy-ve-sanal-ip)).
- Dashboards HTTPS ile (5601) hizmet verir; kurum sertifikası ya da script'in ürettiği sertifika kullanılabilir.
- İki Dashboards sunucusu aktif-aktif çalışır, birbirinin yerine geçebilir (bkz. [Dashboards yedekliliği](#dashboards-yedekliliği)).
- Data `/data/opensearch`, loglar `/data/logs` altındadır (ana log: `/data/logs/<CLUSTER_NAME>.log`).
- SELinux ve firewalld durumu kontrol edilir; ilgili adımlar yalnızca bileşen açıksa uygulanır.

Script'ler sıfırdan kurulum içindir. Çalışan bir cluster'a node eklemek ya da Dashboards'u başka sunucuya taşımak bu script'lerin kapsamında değildir.

## Dosyalar

| Dosya | Çalıştığı yer | Görevi |
| --- | --- | --- |
| `config.env` | 7 sunucu (aynı içerik) | Tüm ayarlar: IP'ler, cluster adı, dizinler, sertifika ve firewall tercihleri |
| `lib.sh` | (doğrudan çalıştırılmaz) | Ortak fonksiyonlar |
| `hazirlik.sh` | 7 sunucu | Ortak hazırlık. Node'larda: `/etc/hosts`, swap, kernel ayarı, OpenSearch RPM, dizinler, 9200/9300 kuralları. Dashboard sunucularında: `/etc/hosts`, Dashboards RPM, HAProxy ve keepalived, port ve VRRP kuralları |
| `node1.sh` | node1 | Sertifikalar, şifreler, Dashboards oturum anahtarı, diğer 6 sunucunun paketleri, node1 OpenSearch |
| `node2.sh` ... `node5.sh` | node2 ... node5 | node1'in hazırladığı paketle node'u kurar ve cluster'a katar |
| `dashboard1.sh`, `dashboard2.sh` | dashboard1, dashboard2 | node1'in hazırladığı paketle Dashboards'u kurar, HTTPS ile başlatır; HAProxy ve keepalived'ı yapılandırır, test eder |
| `opensearch-dashboard-test.sh` | dashboard1, dashboard2 | Uçtan uca test; `dashboardN.sh` sonunda kendiliğinden çalışır |

| Sunucu | Roller | Portlar |
| --- | --- | --- |
| node1 ... node5 | cluster_manager, data, ingest | 9200, 9300 |
| dashboard1, dashboard2 | OpenSearch Dashboards, HAProxy, keepalived | 5601, 443, 9200, VRRP |

5 node da cluster manager adayıdır. Cluster'ın çalışması için en az 3'ünün ayakta olması gerekir; aynı anda 2 node kaybı tolere edilir.

Sunucu adları (`node1` ... `node5`, `dashboard1`, `dashboard2`) 7 sunucuda da `/etc/hosts`'a yazılır; `node.name`, `server.name` ve sertifika CN'si olarak kullanılır. Sunucuların kendi hostname'i değiştirilmez (`SET_HOSTNAME=yes` ile değiştirilebilir).

## Kurulumdan önce

1. **`config.env`'yi düzenleyin.** `NODE1_IP` ... `NODE5_IP`, `DASHBOARD1_IP`, `DASHBOARD2_IP`, `DASHBOARDS_FQDN` ve `HAPROXY_VIP` girilmeli; `CHANGE_ME` kalırsa script'ler çalışmaz. Gerekirse `CLUSTER_NAME` ve `CERT_SUBJECT` (`O=Sirket`) değerlerini de değiştirin. `CERT_SUBJECT` içinde Türkçe karakter kullanmayın; DN eşleşmesini bozar.
2. **`DASHBOARDS_FQDN` dışarıdan kullanılan tek adrestir** (ör. `opensearch.sirket.local`). DNS kaydı `HAPROXY_VIP`'i göstermelidir; HAProxy'nin dışarıya gösterdiği sertifika da bu adla doğrulanır. Ad, sunucu adlarından farklı olmalıdır.
   **`HAPROXY_VIP`, dashboard sunucularıyla aynı subnet'te boş bir IP olmalıdır** ve ağda iki sunucu arasında VRRP'ye izin verilmelidir (bkz. [HAProxy ve sanal IP](#haproxy-ve-sanal-ip)).
3. **Script dizinini 7 sunucuya kopyalayın** (ör. `/root/opensearch-kurulum`). `config.env` 7 sunucuda aynı olmalı; node ve dashboard script'leri bunu kontrol eder.
4. **RPM'leri indirip her sunucuda `/root/opensearch-rpm` altına koyun:**

   | Dosya | Sunucu |
   | --- | --- |
   | [opensearch-3.9.0-linux-x64.rpm](https://artifacts.opensearch.org/releases/bundle/opensearch/3.9.0/opensearch-3.9.0-linux-x64.rpm) ve [.sig](https://artifacts.opensearch.org/releases/bundle/opensearch/3.9.0/opensearch-3.9.0-linux-x64.rpm.sig) | node1 ... node5 |
   | [opensearch-dashboards-3.9.0-linux-x64.rpm](https://artifacts.opensearch.org/releases/bundle/opensearch-dashboards/3.9.0/opensearch-dashboards-3.9.0-linux-x64.rpm) ve [.sig](https://artifacts.opensearch.org/releases/bundle/opensearch-dashboards/3.9.0/opensearch-dashboards-3.9.0-linux-x64.rpm.sig) | dashboard1, dashboard2 |
   | [opensearch-release.pgp](https://artifacts.opensearch.org/publickeys/opensearch-release.pgp) | 7 sunucu |

   `haproxy` ve `keepalived` RHEL AppStream deposundan `dnf` ile kurulur; dashboard sunucularının bu depoya (ya da Satellite'a) erişimi olmalıdır. RPM'ler kurulmadan önce `.sig` ile doğrulanır. `rpm --import` RHEL 10'un SHA-1 politikası nedeniyle hata verebilir; buna gerek yoktur, kripto politikasını LEGACY'ye çekmeyin. aarch64 sunucularda dosya adlarında `x64` yerine `arm64` kullanılır; script'ler mimariyi kendisi algılar.
5. **Dashboards için kurum sertifikası kullanılacaksa** her dashboard sunucusunda `/root/dashboards-certs/` altına `ssl.crt`, `ssl.key` ve `ca.crt` koyun. Konmazsa cluster'ın root CA'sıyla imzalı sertifika kullanılır (bkz. [Dashboards sertifikası](#dashboards-sertifikası)).

## Kurulum

```bash
# 1) 7 sunucuda (sıra fark etmez)
cd /root/opensearch-kurulum
./hazirlik.sh --check      # yalnızca kontrol, değişiklik yapmaz
./hazirlik.sh

# 2) node1'de
./node1.sh                 # admin ve kibanaserver şifrelerini sorar

# 3) node1 "Cluster'ın oluşması bekleniyor" dediğinde (sıra fark etmez)
./node2.sh                 # node2'de
./node3.sh                 # node3'te
./node4.sh                 # node4'te
./node5.sh                 # node5'te

# 4) node1.sh 5 node green olunca biter

# 5) Dashboards: sırayla, önce dashboard1 bitsin
./dashboard1.sh            # dashboard1'de; kibanaserver ve admin şifrelerini sorar
./dashboard2.sh            # dashboard2'de
```

`node1.sh` paketleri `root@<sunucu>`'ya scp ile göndermeyi dener. SSH erişimi yoksa ekrana yazdığı komutla elle kopyalayın:

```bash
scp /root/opensearch-bundle/opensearch-bundle-node2.tar.gz root@node2:/root/
# ... node3, node4, node5
scp /root/opensearch-bundle/opensearch-bundle-dashboard1.tar.gz root@dashboard1:/root/
scp /root/opensearch-bundle/opensearch-bundle-dashboard2.tar.gz root@dashboard2:/root/
```

Dashboards'u sırayla kurun: ilk açılışta `.kibana` index'i oluşturulur; iki instance aynı anda ilk kez başlatılırsa biri diğerinin migration'ını bekler, yarıda kalan bir migration elle temizlik gerektirebilir.

Kurulumun sonunda:

- `dashboard1.sh` testi `Sonuç: 12 başarılı, 0 başarısız` yazmalı. dashboard2 henüz kurulmadığı için çapraz oturum testi atlanır.
- `dashboard2.sh` testi `Sonuç: 14 başarılı, 0 başarısız` yazmalı. Ek 2 test, dashboard1'e erişimi ve dashboard2'de açılan oturumun dashboard1'de de geçerli olduğunu doğrular.
- DNS kaydı hazır olunca `https://<DASHBOARDS_FQDN>` adresi `admin` kullanıcısıyla açılmalı; `https://<DASHBOARDS_FQDN>:9200` OpenSearch'e gitmeli.

Testler DNS'i beklemez: her dashboard sunucusu ortak adla (`DASHBOARDS_FQDN`), ama doğrudan IP'ye bağlanır (`curl --resolve`): kendi Dashboards'una, diğerine ve sanal IP üzerinden HAProxy'ye. Böylece HAProxy sertifikasının ortak adı içerdiği de doğrulanır. DNS hazır olmadan tarayıcıdan denemek için istemcinin hosts dosyasına `<HAPROXY_VIP> <DASHBOARDS_FQDN>` satırı eklenebilir.

### node1.sh aşamaları

`./node1.sh` parametresiz çalışınca tüm aşamaları sırayla yapar. Bir aşama yarıda kalırsa sorunu düzeltip yalnızca o aşamadan devam edebilirsiniz:

| Aşama | Ne yapar |
| --- | --- |
| `./node1.sh certs` | Root CA; admin, 5 node ve 2 Dashboards sertifikası; şifre hash'leri (`internal_users.yml`); Dashboards ortak oturum anahtarı; 6 paket ve dağıtım |
| `./node1.sh opensearch` | node1'de OpenSearch'ü yapılandırır, başlatır; 5 node'un katılıp cluster'ın green olmasını bekler |

### dashboardN.sh

| Komut | Ne yapar |
| --- | --- |
| `./dashboard1.sh` | Kurulum ve test (paket: `/root/opensearch-bundle-dashboard1.tar.gz`) |
| `./dashboard1.sh <paket>` | Paket başka bir yerdeyse |
| `./dashboard1.sh test` | Yalnızca test. Diğer dashboard çalışıyorsa çapraz oturum testi de yapılır |

### Şifreler

`admin` ve `kibanaserver` şifreleri node1'de sorulur (en az 8 karakter, iki kez). Dashboard script'leri `kibanaserver` şifresini (Dashboards'un OpenSearch'e bağlanması için) ve `admin` şifresini (test için) tekrar sorar. Otomasyon için `ADMIN_PASSWORD` ve `KIBANASERVER_PASSWORD` ortam değişkenleriyle de verilebilir. Şifreler komut satırına yazılmaz, curl'e stdin'den verilir (`ps` çıktısında görünmez). Diske düştükleri yerler:

- `internal_users.yml`: yalnızca bcrypt hash'leri
- dashboard1/2'de `/etc/opensearch-dashboards/opensearch_dashboards.yml`: kibanaserver şifresi ve oturum anahtarı (izin 600)
- dashboard1/2'de `/etc/haproxy/certs/site.pem`: HAProxy için Dashboards sertifikası ve şifresiz key'i (izin 600)

Demo kullanıcılar (`kibanaro`, `logstash`, `readall` vb.) tanımlanmaz.

## Script'ler ne yapar

**hazirlik.sh (7 sunucu).** Sunucunun hangi node ya da dashboard sunucusu olduğunu IP'sinden bulur.

Tüm sunucularda:

- RHEL sürümünü, mimariyi ve RPM dosyalarını kontrol eder.
- SELinux ve firewalld'nin şu anki ve reboot sonrası durumunu raporlar.
- `/etc/hosts`'a 7 sunucunun bulunduğu yönetilen bir blok yazar; tekrar çalıştırıldığında bloğu günceller ve isimlerin doğru IP'ye çözüldüğünü doğrular.
- Saat senkronunu kontrol eder.

OpenSearch node'larında ayrıca:

- Swap'ı kapatır, `vm.max_map_count` 262144'ten düşükse yükseltir; `/data` mount'unu kontrol eder.
- OpenSearch RPM'ini imza doğrulamasıyla, demo ayarları olmadan kurar. Servis bu aşamada enable edilmez ve başlatılmaz.
- Data ve log dizinlerini, SELinux etiketlerini ve systemd override'ını (`RequiresMountsFor=/data`) hazırlar.
- `/tmp` noexec bağlıysa (CIS sıkılaştırması) OpenSearch'ün geçici dizinini `/var/lib/opensearch/tmp` yapar; aksi halde OpenSearch açılmaz.
- firewalld çalışıyorsa 9200 ve 9300 kurallarını ekler.

Dashboard sunucularında ayrıca:

- OpenSearch Dashboards RPM'ini imza doğrulamasıyla kurar; servis başlatılmaz.
- HAProxy ve keepalived'ı `dnf` deposundan kurar; SELinux açıksa `haproxy_connect_any` ayarını açar.
- firewalld çalışıyorsa 5601, HAProxy portları ve VRRP kurallarını ekler.

**node1.sh.** Tüm sertifikaları node1'de, tek CA ile bir kez üretir. `opensearch.yml`'deki `nodes_dn` ve `admin_dn` değerleri elle yazılmaz, üretilen sertifikalardan okunur; böylece DN uyuşmazlığı oluşmaz. İki Dashboards'un ortak kullanacağı oturum anahtarını üretir. node1'i başlatır, diğer 4 node'un katılmasını ve cluster'ın green olmasını bekler, ardından `cluster.initial_cluster_manager_nodes` satırını yorum satırı yapar. node1'e Dashboards kurulmaz.

**node2.sh ... node5.sh.** Paketi SHA256 ile doğrular ve `config.env`'nin node1'dekiyle aynı olduğunu kontrol eder. Sertifikaları ve `internal_users.yml`'yi yerleştirir, OpenSearch'ü başlatır. Node cluster'a katılınca bootstrap ayarını kapatır. 5 cluster manager adayından 3'ü bir araya gelene kadar cluster oluşmaz; ilk başlatılan node'lar bu sırada bekler.

**dashboard1.sh / dashboard2.sh.** Paketi doğrular; root CA'yı ve Dashboards sertifikasını yerleştirip kontrol eder. Yanıt veren ilk node üzerinden `kibanaserver` girişini doğrular. `opensearch_dashboards.yml`'yi 5 node'un tamamı ve ortak oturum anahtarıyla yazar, Dashboards'u başlatır. HAProxy ve keepalived'ı yapılandırıp başlatır, sanal IP'nin yanıt vermesini bekler ve testi çalıştırır.

Her script yanlış sunucuda çalıştırılırsa durur (ör. `node2.sh` node3'te, `dashboard1.sh` dashboard2'de çalışmaz).

## Dashboards yedekliliği

İki Dashboards sunucusu bağımsız çalışır ve aynı veriyi gösterir:

- **Ortak veri.** Kayıtlı nesneler (dashboard, visualization, index pattern) ve tenant'lar cluster'daki `.kibana` index'lerinde tutulur. Bir sunucuda yapılan değişiklik diğerinde de görünür.
- **Ortak oturum anahtarı.** `opensearch_security.cookie.password` iki sunucuda aynıdır (node1 üretir, paketlerle dağıtılır). Bir sunucuda açılan oturum diğerinde de geçerlidir. HAProxy isteği diğer sunucuya yönlendirdiğinde kullanıcının oturumu düşmez; sticky session gerekmez.
- **Cluster bağlantısı.** `opensearch.hosts` 5 node'u da içerir; bir node düşerse Dashboards diğerlerine bağlanır.
- **Ortak adres.** İki sunucu da aynı adla (`DASHBOARDS_FQDN`) hizmet verir ve bu adı içeren sertifika sunar. Kullanıcı hangi sunucuya düşerse düşsün tarayıcı aynı adı ve geçerli bir sertifika görür.

## HAProxy ve sanal IP

dashboard1 ve dashboard2'de HAProxy ve keepalived çalışır. DNS kaydı script'lerin kapsamında değildir; `DASHBOARDS_FQDN` -> `HAPROXY_VIP` kaydı ayrıca açılır.

```text
İstemci -> DASHBOARDS_FQDN -> HAPROXY_VIP (keepalived: dashboard1 ya da dashboard2)
             :443  -> HAProxy -> dashboard1:5601, dashboard2:5601
             :9200 -> HAProxy -> node1:9200 ... node5:9200
```

| Ayar | Değer |
| --- | --- |
| Portlar | `HAPROXY_DASHBOARDS_PORT` (443), `HAPROXY_OPENSEARCH_PORT` (9200) |
| TLS | Dışarıya karşı HAProxy'de sonlanır; `/etc/haproxy/certs/site.pem`, sunucunun Dashboards sertifikasıdır (bkz. [Dashboards sertifikası](#dashboards-sertifikası)). Arka uçlara yeniden TLS ile bağlanılır ve sertifikaları doğrulanır: Dashboards için `DASHBOARDS_FQDN`, node'lar için node adı |
| İstemci sertifikası | `admin.pem` ile giriş HAProxy üzerinden çalışmaz, çünkü TLS orada sonlanır. Admin sertifikası gereken işlemler (`securityadmin.sh`, admin API) doğrudan bir node'a (`https://node1:9200`) yapılır |
| Dağıtım | Dashboards: roundrobin. OpenSearch: leastconn |
| Sağlık kontrolü | HTTPS `GET /api/status` (Dashboards), `GET /` (OpenSearch); 200 ya da 401 sağlıklı, 503 ve bağlantı hatası sağlıksız. 2 saniyede bir, 2 başarısızlıkta devre dışı |
| Sanal IP | keepalived, unicast VRRP. Aktif sunucu ya da HAProxy'si düşerse IP birkaç saniyede diğerine geçer; sunucu düzelince IP geri dönmez (`nopreempt`) |
| `HAPROXY_VRID` | VRRP küme numarası (1-255, varsayılan 51). Aynı ağdaki başka keepalived kümeleriyle çakışmamalıdır |

İki HAProxy de 5 node'a ve 2 Dashboards'a bağlanır; sanal IP'nin hangi sunucuda olduğu arka uçların kullanımını değiştirmez. Node'lar ve Dashboards bağlantıyı HAProxy sunucusunun IP'sinden görür; istemcinin IP'si `X-Forwarded-For` başlığında iletilir. VMware'de port grubunun, bulutta ağ politikasının sanal IP'ye ve VRRP'ye izin vermesi gerekir.

## SELinux ve firewalld

| Durum | Davranış |
| --- | --- |
| SELinux `Disabled` | Etiketleme adımları atlanır |
| SELinux `Enforcing` / `Permissive` | Node'larda `/data/opensearch` ve `/data/logs`, RPM'in kendi dizinleriyle aynı etiketi alır (`semanage fcontext -e`, `restorecon`). Sertifikalar ve config dosyaları (node ve dashboard) yeniden etiketlenir. Servis başladıktan sonra AVC kayıtları kontrol edilir. `semanage` yoksa `policycoreutils-python-utils` dnf ile kurulur (repo erişimi gerekir). |
| SELinux şu an kapalı, reboot sonrası açık | Uyarı verilir; reboot'tan sonra `./hazirlik.sh` tekrar çalıştırılmalıdır |
| firewalld çalışıyor | Node'larda: 9300 yalnızca 5 node IP'sine; 9200 5 node'a, 2 dashboard sunucusuna ve `HTTP_ALLOWED_SOURCES`'a açılır. Dashboard sunucularında: 5601 yalnızca iki dashboard IP'sine; 443 `DASHBOARDS_ALLOWED_SOURCES`'a, 9200 `OPENSEARCH_LB_ALLOWED_SOURCES`'a açılır (boşsa herkese; doluysa iki dashboard IP'si de eklenir); VRRP karşı sunucuya açılır. Kurallar sunucu IP'sinin bağlı olduğu arayüzün zone'una eklenir (`FIREWALL_ZONE` ile değiştirilebilir). |
| firewalld kapalı ama açılışta başlayacak | Uyarı verilir, kural eklenmez; firewalld başlatıldıktan sonra `./hazirlik.sh` tekrar çalıştırılır |
| firewalld kapalı | Kural eklenmez |

firewalld kapalı olsa bile aradaki ağ firewall'larında şu erişimlerin açık olduğunu ağ ekibiyle teyit edin:

| Kaynak | Hedef | Port |
| --- | --- | --- |
| node1 ... node5 | node1 ... node5 | 9200, 9300 |
| dashboard1, dashboard2 | node1 ... node5 | 9200 |
| dashboard1, dashboard2 | dashboard1, dashboard2 | 5601 (HAProxy, çapraz oturum testi), IP protokol 112 (VRRP) |
| Kullanıcılar | `HAPROXY_VIP` | 443, 9200 |
| node1 | diğer 6 sunucu | 22 (paket dağıtımı, scp kullanılacaksa) |

Uygulama sunucuları 9200'e erişecekse subnet'lerini `HTTP_ALLOWED_SOURCES`'a ekleyip node'larda `./hazirlik.sh`'i tekrar çalıştırın.

## Dashboards sertifikası

`DASHBOARDS_CERT_MODE` ile seçilir. Karar her dashboard sunucusunda ayrı verilir:

| Mod | Davranış |
| --- | --- |
| `auto` (varsayılan) | Dashboard sunucusunda `DASHBOARDS_CERT_SRC` (`/root/dashboards-certs`) içinde `ssl.crt` ve `ssl.key` varsa onları kullanır, yoksa node1'in ürettiği sertifikayı kullanır |
| `provided` | Kurum sertifikası zorunludur: `ssl.crt`, `ssl.key`, `ca.crt`. node1 Dashboards sertifikası üretmez |
| `self` | Cluster'ın root CA'sıyla imzalı sertifika kullanılır. node1 her dashboard sunucusuna ayrı key ile sertifika üretir; ikisinde de ortak ad bulunur. SAN: `DASHBOARDS_FQDN`, `HAPROXY_VIP`, sunucunun adı ve IP'si (+ `DASHBOARDS_EXTRA_SAN`) |

Kurum sertifikası için:

- Sertifika ortak adı (`DASHBOARDS_FQDN`) SAN'da içermelidir; içermiyorsa script durur. Genellikle bu ad için alınan tek sertifika iki sunucuya da konur; her birine ayrı sertifika da olur.
- Sertifika bir ara CA ile imzalandıysa `ssl.crt` önce sunucu, sonra ara CA sertifikasını içermelidir (fullchain).
- DER formatındaki dosyalar PEM'e kendiliğinden çevrilir.
- Key şifreliyse şifresi sorulur (ya da `DASHBOARDS_KEY_PASSPHRASE` ortam değişkeniyle verilir).
- Zincir, key eşleşmesi, geçerlilik süresi ve SAN'ın `DASHBOARDS_FQDN`'i içerip içermediği kontrol edilir.

`self` modda tarayıcı uyarısı olmaması için node1'deki `/root/opensearch-certs/root-ca.pem` dosyasını istemcilere güvenilir kök sertifika olarak dağıtın.

HAProxy dışarıya bu sertifikayı gösterir, `dashboardN.sh` onu `/etc/haproxy/certs/site.pem` olarak (key ile birlikte, izin 600, şifresiz) kopyalar. Sertifika yenilenince `./dashboardN.sh` tekrar çalıştırılır. Node sertifikaları bilinçli olarak kullanılmaz: `nodes_dn` listesindeki bir sertifikanın key'i, sahibini cluster node'u gibi gösterir.

## Tekrar çalıştırma

- Tüm script'ler tekrar çalıştırılabilir; yapılmış adımları atlar. Hata alırsanız sebebi düzeltip aynı script'i yeniden çalıştırın.
- Mevcut root CA, sertifikalar, `internal_users.yml` ve oturum anahtarı yeniden kullanılır. `config.env`'de bir sunucunun IP'si, `DASHBOARDS_FQDN`, `HAPROXY_VIP` ya da `CERT_SUBJECT` değişirse ilgili sertifika yeniden üretilir; bu durumda `./node1.sh certs` sonrası paketleri yeniden dağıtıp ilgili script'leri tekrar çalıştırın.
- `internal_users.yml` yalnızca cluster ilk kez oluşurken okunur. Cluster kurulduktan sonra şifre değişikliği Dashboards'tan (Security > Internal users) ya da aşağıdaki `securityadmin.sh` adımlarıyla yapılır. `kibanaserver` şifresi değişirse iki dashboard sunucusunda da `./dashboardN.sh` tekrar çalıştırılmalıdır.

## Kurulumdan sonra

- `/root/opensearch-certs` dizini root CA key'ini içerir. Güvenli bir yere yedekleyip node1'den kaldırın; yeni sertifika üretmek için bu key gerekir. Dizin yokken `./node1.sh certs` çalıştırılırsa yeni bir root CA üretilir ve paketler çalışan cluster'la uyumsuz olur; önce yedekten geri koyun.
- Paketler private key ve oturum anahtarı içerir; silin: node1'de `/root/opensearch-bundle/`, diğer sunucularda `/root/opensearch-bundle-*.tar.gz`.
- Node, admin ve Dashboards sertifikaları `CERT_DAYS` (730) gün geçerlidir. Bitiş tarihini takvime ekleyin: `openssl x509 -enddate -noout -in /etc/opensearch/node1.pem` (dashboard sunucularında `/etc/opensearch-dashboards/certs/ssl.crt`; aynı sertifikayı HAProxy de kullanır).

Güvenlik dosyalarında (`/etc/opensearch/opensearch-security/`) yapılan değişiklikler node1'de `securityadmin.sh` ile uygulanır. Bu komut dizindeki tüm dosyaları yükler ve Dashboards ya da REST API ile yapılmış değişikliklerin üzerine yazar; önce yedek alın:

```bash
SA=/usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh
CERTS="-cacert /etc/opensearch/root-ca.pem -cert /etc/opensearch/admin.pem -key /etc/opensearch/admin-key.pem"

# Yedek
OPENSEARCH_JAVA_HOME=/usr/share/opensearch/jdk $SA -backup /root/security-backup-$(date +%F) $CERTS -icl -nhnv
# Değişiklikleri uygula
OPENSEARCH_JAVA_HOME=/usr/share/opensearch/jdk $SA -cd /etc/opensearch/opensearch-security/ $CERTS -icl -nhnv
```

## Docker'da deneme

`docker/` dizini, script'leri gerçek sunucu olmadan RHEL 10 + systemd konteynerlerinde çalıştırır. Script'ler değiştirilmez; `docker/config.env`, ana `config.env`'den üretilir (node başına 512 MB heap, ortak paket volume'ü). Yerel deneme içindir: en az 8 GB bellek ayrılmış Docker gerekir.

```bash
cd docker
./up.sh                  # RPM'leri indirir, kurar ya da kaldığı yerden başlatır
docker compose stop      # durdurur, veri korunur
docker compose down -v   # kurulumu ve veriyi siler
```

| Adres | Hedef |
| --- | --- |
| `https://localhost:8443` | Dashboards (`admin`, şifre: `docker/.env`) |
| `https://localhost:9200` | OpenSearch |

Sertifika `docker/root-ca.pem` ile doğrulanır. Bir Mac'te host portu 443 TLS el sıkışmasında bağlantıyı sıfırladığı için localhost tarafında 8443 kullanılır; konteynerlerde HAProxy yine 443'ü dinler. SELinux, firewalld, `scp` dağıtımı ve gerçek ağdaki VRRP bu ortamda devreye girmez.

## Sorun giderme

| Belirti | Olası sebep | Ne yapılmalı |
| --- | --- | --- |
| node1.sh `cluster henüz oluşmadı` diyerek bekliyor | 5 node'dan 3'ü bir araya gelmedi: diğer node'lar başlatılmadı ya da 9300'e erişemiyor | node2-5 script'lerini çalıştırın. Script 2 dakikada bir teşhis basar: 9300 erişimi ve TLS hataları. |
| node1.sh `cluster: 4/5 node` diyerek bekliyor | Bir node katılmadı | O node'da script'i çalıştırın; logunda TLS/`nodes_dn` hatasına bakın |
| Logda `nodes_dn` ile ilgili hata | Sertifika DN'leri `opensearch.yml`'deki listeyle eşleşmiyor | `./node1.sh certs` ile paketleri yeniden üretip dağıtın, node script'lerini tekrar çalıştırın |
| `unknown_ca` / `PKIX path building failed` | Node'lar farklı CA'larla imzalanmış sertifika kullanıyor | Sertifikaları yalnızca node1 üretmeli; paketleri yeniden dağıtın |
| Bir script `config.env ... aynı değil` diyor | Sunuculardaki `config.env` farklı | node1'deki `config.env`'yi kopyalayın |
| OpenSearch açılmıyor, logda `jna ... failed to map segment` | `/tmp` noexec | `./hazirlik.sh`'i tekrar çalıştırın (`OPENSEARCH_TMPDIR` ayarlanır) |
| Bir node ayrı cluster gibi davranıyor (`cluster UUID` uyumsuzluğu) | Node yanlış ayarla tek başına bootstrap olmuş | Yalnızca yeni kurulumda: `systemctl stop opensearch`, `rm -rf /data/opensearch/*`, node script'ini tekrar çalıştırın |
| Servis `permission denied` ile düşüyor | Dosya sahipliği ya da SELinux etiketi | `ausearch -m AVC -ts recent`, ardından `./hazirlik.sh` |
| dashboardN.sh `Hiçbir OpenSearch node'unun REST'ine ulaşılamadı` | Cluster kurulmadı, ya da node'larda 9200 dashboard sunucusuna kapalı | node1.sh'in bittiğini kontrol edin; node'larda `./hazirlik.sh`'i tekrar çalıştırın (dashboard IP'leri 9200'e eklenir), ağ firewall'unu kontrol edin |
| dashboardN.sh `<VIP>:443 30 saniyede açılmadı` | VIP subnet dışında ya da kullanımda, ya da ağ VRRP'yi engelliyor | `journalctl -u keepalived`, `ip -4 addr`; iki sunucu da kendini MASTER sanıyorsa VRRP ulaşmıyordur (firewall, VMware port grubu, bulut politikası) |
| HAProxy üzerinden OpenSearch testi başarısız, node'lara doğrudan erişim çalışıyor | HAProxy node sertifikasını doğrulayamıyor ya da node'lara ulaşamıyor | `journalctl -u haproxy`; `/etc/haproxy/certs/opensearch-ca.pem` node'lardaki root CA ile aynı olmalı |
| `curl` ile `admin.pem` kullanınca HAProxy üzerinden 401 | TLS HAProxy'de sonlandığı için istemci sertifikası node'a ulaşmaz | Admin sertifikasıyla doğrudan node'a bağlanın: `https://node1:9200` |
| `journalctl -u haproxy` içinde `Server ... is DOWN` | Sağlık kontrolü başarısız: servis kapalı, firewall ya da SELinux | Servisi kontrol edin; SELinux açıksa `getsebool haproxy_connect_any` açık olmalı |
| Dashboards `server is not ready yet` | kibanaserver şifresi, root CA yolu ya da isim çözümleme | `journalctl -u opensearch-dashboards`, `/etc/hosts` |
| Dashboards `Another OpenSearch Dashboards instance appears to be migrating the index` diyerek bekliyor | İki instance aynı anda ilk kez başlatıldı ve migration yarıda kaldı | Diğer instance'ın açılmasını bekleyin. Açılmıyorsa: iki Dashboards'u durdurun, yarım kalan `.kibana_N` index'ini silin, önce dashboard1'i başlatın |
| Çapraz oturum testi `Oturum diğer Dashboards'ta geçersiz` | İki sunucuda `opensearch_security.cookie.password` farklı | Aynı `node1.sh certs` çıktısının paketleriyle iki sunucuda da `./dashboardN.sh` çalıştırın |
| HAProxy üzerinden girişte arada bir oturum düşüyor | Sunuculardan biri eski paketle kurulmuş (farklı oturum anahtarı) | Yukarıdaki gibi; ardından `./dashboard1.sh test` ve `./dashboard2.sh test` |
| Tarayıcı sertifika uyarısı veriyor | Tarayıcıya `DASHBOARDS_FQDN` dışında bir ad yazıldı ya da CA istemcide güvenilir değil | Ortak adı kullanın, CA'yı istemcilere dağıtın |
| `https://<DASHBOARDS_FQDN>` açılmıyor ama `./dashboardN.sh test` başarılı | DNS kaydı hazır değil ya da istemciden sanal IP'ye erişim kapalı | `getent hosts <DASHBOARDS_FQDN>` `HAPROXY_VIP`'i vermeli; ağ firewall'unda 443 ve 9200'ü kontrol edin |

Teşhis komutları:

```bash
# Cluster neden oluşmuyor
grep -E "cluster-manager not discovered" /data/logs/<CLUSTER_NAME>.log | tail -2

# TLS hataları
grep -iE "ssl|handshake|certificate|unknown_ca|PKIX" /data/logs/<CLUSTER_NAME>.log | grep -E "WARN|ERROR" | tail -5

# Cluster durumu (node1, admin sertifikasıyla, şifre gerekmez)
curl --cert /etc/opensearch/admin.pem --key /etc/opensearch/admin-key.pem \
  "https://node1:9200/_cat/nodes?v"

# Sertifika tutarlılığı: fingerprint 7 sunucuda aynı olmalı
openssl x509 -noout -fingerprint -sha256 -in /etc/opensearch/root-ca.pem               # node'lar
openssl x509 -noout -fingerprint -sha256 -in /etc/opensearch-dashboards/root-ca.pem    # dashboard'lar

# Oturum anahtarı iki dashboard sunucusunda aynı mı (çıktılar aynı olmalı)
grep cookie.password /etc/opensearch-dashboards/opensearch_dashboards.yml | sha256sum
```
