# OpenSearch Kurulum Script'leri

5 node'lu OpenSearch 3.9 cluster'ı, iki sunucuda yedekli OpenSearch Dashboards ve HAProxy + keepalived kurulumu. İşletim sistemine göre ilgili dizini kullanın; her dizin tek başına çalışır ve sunuculara yalnızca o dizin kopyalanır.

| Dizin | İşletim sistemi | Paket | Firewall | Doküman |
| --- | --- | --- | --- | --- |
| [rhel/](rhel/) | RHEL 10.1 | RPM, `dnf` | firewalld, SELinux | [README](rhel/README.md), [Word ve PDF](rhel/dokuman/) |
| [ubuntu/](ubuntu/) | Ubuntu 24.04 | DEB, `apt` | ufw | [README](ubuntu/README.md), [Word ve PDF](ubuntu/dokuman/) |

Mimari, kurulum sırası ve komutlar iki dizinde aynıdır. `node*.sh`, `dashboard*.sh` ve `opensearch-dashboard-test.sh` birebir aynıdır; farklar `hazirlik.sh`, `lib.sh`, `config.env` ve `docker/` içindedir. Bir düzeltme yapılırken iki dizin de güncellenmelidir; farkları görmek için: `diff -r rhel ubuntu`.
