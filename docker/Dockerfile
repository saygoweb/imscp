# i-MSCP development server.
#
# i-MSCP is not an application you can run out of a slim PHP image: it installs
# and drives a whole hosting stack (nginx, apache2, php-fpm, postfix, dovecot or
# courier, proftpd, bind9, mariadb, its own daemon) through systemd. So this
# image is a plain Debian rootfs with systemd as PID 1, exactly like the Vagrant
# boxes under ../Vagrant, and the i-MSCP installer runs *inside* the running
# container rather than at build time — it needs those services up to configure
# them, and nothing can be started while the image is being built.
#
# What the build does, therefore, is only the slow-but-cacheable part:
#   * bring the distribution fully up to date (the installer aborts outright if
#     `apt-get dist-upgrade` still has anything to do — see
#     DebianAdapter::preinstall), and
#   * install the handful of tools the installer expects to find already there.
#
# Drive it with docker/imscp; see docker/README.md.

ARG DEBIAN_SUITE=bookworm
FROM debian:${DEBIAN_SUITE}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    container=docker

# systemd, plus what the i-MSCP installer shells out to. Recommends are off for
# this one layer only: the installer runs apt itself later, and the packages it
# pulls do want their recommends.
RUN apt-get update \
    && apt-get -y --no-install-recommends dist-upgrade \
    && apt-get -y --no-install-recommends install \
        systemd \
        systemd-sysv \
        dbus \
        ca-certificates \
        apt-transport-https \
        apt-utils \
        gnupg \
        wget \
        curl \
        perl \
        procps \
        psmisc \
        iproute2 \
        iputils-ping \
        iptables \
        lsb-release \
        dialog \
        whiptail \
        git \
        rsync \
        make \
        gcc \
        libc6-dev \
        less \
        nano \
        bash-completion \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# The Debian Docker images ship their repositories exclusively as deb822
# (/etc/apt/sources.list.d/debian.sources) and omit /etc/apt/sources.list
# altogether — no other Debian install does that. DebianAdapter reads the
# deb822 files where they exist, but _processAptRepositories still writes the
# sury PHP repository into sources.list and backs the file up first, which
# fails outright when there is no file to back up. An empty one is all it needs.
RUN [ -f /etc/apt/sources.list ] || printf '%s\n' \
        '# Repositories live in /etc/apt/sources.list.d/debian.sources.' \
        '# This file exists because the i-MSCP installer adds its own' \
        '# repositories here; see docker/Dockerfile.' \
        > /etc/apt/sources.list

# The Debian images ship /usr/sbin/policy-rc.d returning 101, which makes
# invoke-rc.d refuse to start anything a package installs. Its own comment
# explains why: "apt-get install only happens during docker build, where
# starting services doesn't work". That premise does not hold here — apt runs at
# run time under a real init — and leaving it in place installs the whole
# hosting stack in a state where every unit is enabled but dead, so the
# installer's first SQL query fails with "Can't connect to local server through
# socket '/run/mysqld/mysqld.sock'".
RUN rm -f /usr/sbin/policy-rc.d

# i-MSCP pulls in resolvconf (bind9 can act as the local resolver). Its postinst
# replaces /etc/resolv.conf with a symlink into /run/resolvconf — and Docker
# bind-mounts /etc/resolv.conf, so that ln fails with EBUSY, the package stays
# unconfigured, and the installer dies with "Sub-process /usr/bin/dpkg returned
# an error code (1)" after downloading half a gigabyte of packages.
#
# The postinst guards the whole linkify step behind a debconf question and a
# marker file, so answer the one and place the other. Docker keeps owning
# /etc/resolv.conf, which is what we want anyway: docker/preseed.pl sets
# LOCAL_DNS_RESOLVER to 'no' precisely so bind9 does not take it over.
RUN echo 'resolvconf resolvconf/linkify-resolvconf boolean false' \
        | debconf-set-selections \
    && mkdir -p /var/lib/resolvconf \
    && : > /var/lib/resolvconf/linkified

# Units that either cannot work in a container or only slow the boot down.
# Without this, systemd sits in "starting" forever waiting on udev.
RUN systemctl mask -- \
        systemd-udevd.service \
        systemd-udevd-control.socket \
        systemd-udevd-kernel.socket \
        systemd-modules-load.service \
        systemd-journald-audit.socket \
        sys-kernel-config.mount \
        sys-kernel-debug.mount \
        sys-kernel-tracing.mount \
        getty.target \
        getty@.service \
        console-getty.service \
    && systemctl set-default multi-user.target

# The scripts that run inside the container. They are copied rather than
# bind-mounted so that `docker/imscp install` works on a container started from
# this image alone.
COPY scripts/ /usr/local/lib/imscp-docker/
RUN chmod +x /usr/local/lib/imscp-docker/*.sh

# systemd shuts down cleanly on SIGRTMIN+3; the default SIGTERM makes it
# re-execute instead, and `docker stop` then falls back to SIGKILL after the
# timeout, leaving MariaDB to recover on the next boot.
STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
