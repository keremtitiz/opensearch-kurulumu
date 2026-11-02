# Script'lerin hedeflediği RHEL 10 sunucunun karşılığı: systemd ile açılan UBI 10
FROM redhat/ubi10-init:10.1

# Script'lerin beklediği, minimal imajda olmayan komutlar (ip, ss, gpg, python3 ...)
RUN dnf install -y --setopt=install_weak_deps=False \
      iproute gnupg2 openssl tar gzip python3 procps-ng util-linux hostname findutils diffutils \
    && dnf clean all

# Swap, konteynerin değil Docker sanal makinesinin swap'ıdır; hazirlik.sh onu kapatmasın
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/swapoff && chmod +x /usr/local/sbin/swapoff
