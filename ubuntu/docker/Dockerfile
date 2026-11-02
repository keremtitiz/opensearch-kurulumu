# Script'lerin hedeflediği Ubuntu 24.04 sunucunun karşılığı: systemd ile açılan konteyner
FROM ubuntu:24.04

# Sunucu kurulumunda bulunan ama temel imajda olmayan paketler
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         systemd systemd-sysv dbus iproute2 curl ca-certificates openssl gnupg python3 ufw kmod procps \
    && rm -rf /var/lib/apt/lists/*

# Swap, konteynerin değil Docker sanal makinesinin swap'ıdır; hazirlik.sh onu kapatmasın
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/swapoff && chmod +x /usr/local/sbin/swapoff

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
