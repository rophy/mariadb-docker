# vim:set ft=dockerfile:

# Build mariadb-auth-k8s plugin
FROM ubuntu:jammy AS auth-k8s-build
ARG AUTH_K8S_VERSION=0.1
ARG AUTH_K8S_MARIADB_VERSION=10.11.18
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		build-essential cmake pkg-config \
		libmariadb-dev libcurl4-openssl-dev libjson-c-dev \
		ca-certificates wget git; \
	rm -rf /var/lib/apt/lists/*; \
	git clone --depth 1 --branch "mariadb-${AUTH_K8S_MARIADB_VERSION}" \
		https://github.com/MariaDB/server.git /tmp/mariadb-server; \
	mkdir -p /opt/include; \
	cp -r /tmp/mariadb-server/include/* /opt/include/; \
	if [ -f /opt/include/mysql_version.h.in ]; then \
		VERSION_MAJOR=$(echo "${AUTH_K8S_MARIADB_VERSION}" | cut -d. -f1); \
		VERSION_MINOR=$(echo "${AUTH_K8S_MARIADB_VERSION}" | cut -d. -f2); \
		VERSION_PATCH=$(echo "${AUTH_K8S_MARIADB_VERSION}" | cut -d. -f3); \
		sed "s/@MYSQL_VERSION_MAJOR@/${VERSION_MAJOR}/g; \
			s/@MYSQL_VERSION_MINOR@/${VERSION_MINOR}/g; \
			s/@MYSQL_VERSION_PATCH@/${VERSION_PATCH}/g; \
			s/@PROTOCOL_VERSION@/10/g; \
			s/@MARIADB_PACKAGE_VERSION@/\"${AUTH_K8S_MARIADB_VERSION}\"/g; \
			s/@MARIADB_BASE_VERSION@/\"mariadb-${VERSION_MAJOR}.${VERSION_MINOR}\"/g; \
			s/@CMAKE_SYSTEM_NAME@/\"Linux\"/g; \
			s/@MACHINE_TYPE@/\"x86_64\"/g" \
			/opt/include/mysql_version.h.in > /opt/include/mysql_version.h; \
	fi; \
	rm -rf /tmp/mariadb-server; \
	wget -q -O /tmp/mariadb-auth-k8s.tar.gz \
		"https://github.com/rophy/mariadb-auth-k8s/releases/download/${AUTH_K8S_VERSION}/mariadb-auth-k8s-${AUTH_K8S_VERSION}.tar.gz"; \
	mkdir /build && cd /build; \
	tar xzf /tmp/mariadb-auth-k8s.tar.gz --strip-components=1; \
	cmake . && make

FROM ubuntu:jammy

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql --home-dir /var/lib/mysql

# add gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
# gosu key is B42F6819007F00F88E364FD4036A9C25BF357DD4
ENV GOSU_VERSION 1.19

ARG GPG_KEYS=177F4010FE56CA3336300305F1656F24C74CD1D8
# pub   rsa4096 2016-03-30 [SC]
#         177F 4010 FE56 CA33 3630  0305 F165 6F24 C74C D1D8
# uid           [ unknown] MariaDB Signing Key <signing-key@mariadb.org>
# sub   rsa4096 2016-03-30 [E]
# install "libjemalloc2" as it offers better performance in some cases. Use with LD_PRELOAD
# install "libtcmalloc-minimal4" as it may improve performance and fix memory fragmentation issues. Use with LD_PRELOAD
# install "pwgen" for randomizing passwords
# install "tzdata" for /usr/share/zoneinfo/
# install "xz-utils" for .sql.xz docker-entrypoint-initdb.d files
# install "zstd" for .sql.zst docker-entrypoint-initdb.d files
# hadolint ignore=SC2086
RUN set -eux; \
	apt-get update; \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		ca-certificates \
		gpg \
		gpgv \
		libjemalloc2 \
		libtcmalloc-minimal4 \
		pwgen \
		tzdata \
		xz-utils \
		zstd ; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get install -y --no-install-recommends \
		dirmngr \
		gpg-agent \
		wget; \
	rm -rf /var/lib/apt/lists/*; \
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	wget -q -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	wget -q -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	GNUPGHOME="$(mktemp -d)"; \
	export GNUPGHOME; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	for key in $GPG_KEYS; do \
		gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key"; \
	done; \
	gpg --batch --export "$GPG_KEYS" > /etc/apt/trusted.gpg.d/mariadb.gpg; \
	if command -v gpgconf >/dev/null; then \
		gpgconf --kill all; \
	fi; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] ||	apt-mark manual $savedAptMark >/dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d

# Ensure the container exec commands handle range of utf8 characters based of
# default locales in base image (https://github.com/docker-library/docs/blob/135b79cc8093ab02e55debb61fdb079ab2dbce87/ubuntu/README.md#locales)
ENV LANG C.UTF-8

# OCI annotations to image
LABEL org.opencontainers.image.authors="MariaDB Community" \
      org.opencontainers.image.title="MariaDB Database" \
      org.opencontainers.image.description="MariaDB Database for relational SQL" \
      org.opencontainers.image.documentation="https://hub.docker.com/_/mariadb/" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:jammy" \
      org.opencontainers.image.licenses="GPL-2.0" \
      org.opencontainers.image.source="https://github.com/MariaDB/mariadb-docker" \
      org.opencontainers.image.vendor="MariaDB Community" \
      org.opencontainers.image.version="10.11.18" \
      org.opencontainers.image.url="https://github.com/MariaDB/mariadb-docker"

# bashbrew-architectures: amd64 arm64v8 ppc64le s390x
ARG MARIADB_VERSION=1:10.11.18+maria~ubu2204
ENV MARIADB_VERSION $MARIADB_VERSION
# release-status:Stable
# release-support-type:Long Term Support
# (https://downloads.mariadb.org/rest-api/mariadb/)

# Allowing overriding of REPOSITORY, a URL that includes suite and component for testing and Enterprise Versions
ARG REPOSITORY="http://archive.mariadb.org/mariadb-10.11.18/repo/ubuntu/ jammy main main/debug"

RUN set -e;\
	echo "deb ${REPOSITORY}" > /etc/apt/sources.list.d/mariadb.list; \
	{ \
		echo 'Package: *'; \
		echo 'Pin: release o=MariaDB'; \
		echo 'Pin-Priority: 999'; \
	} > /etc/apt/preferences.d/mariadb
# add repository pinning to make sure dependencies from this MariaDB repo are preferred over Debian dependencies
#  libmariadbclient18 : Depends: libmysqlclient18 (= 5.5.42+maria-1~wheezy) but 5.5.43-0+deb7u1 is to be installed

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
# hadolint ignore=DL3015
RUN set -ex; \
	{ \
		echo "mariadb-server" mysql-server/root_password password 'unused'; \
		echo "mariadb-server" mysql-server/root_password_again password 'unused'; \
	} | debconf-set-selections; \
	apt-get update; \
# postinst script creates a datadir, so avoid creating it by faking its existence.
	mkdir -p /var/lib/mysql/mysql ; touch /var/lib/mysql/mysql/user.frm ; \
# mariadb-backup is installed at the same time so that `mysql-common` is only installed once from just mariadb repos
	apt-get install -y --no-install-recommends mariadb-server="$MARIADB_VERSION" mariadb-backup socat \
		libcurl4 libjson-c5 \
	; \
	rm -rf /var/lib/apt/lists/*; \
# purge and re-create /var/lib/mysql with appropriate ownership
	rm -rf /var/lib/mysql /etc/mysql/mariadb.conf.d/50-mysqld_safe.cnf; \
	mkdir -p /var/lib/mysql /run/mysqld; \
	chown -R mysql:mysql /var/lib/mysql /run/mysqld; \
# ensure that /run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	chmod 1777 /run/mysqld; \
# comment out a few problematic configuration values
	find /etc/mysql/ -name '*.cnf' -print0 \
		| xargs -0 grep -lZE '^(bind-address|log|user\s)' \
		| xargs -rt -0 sed -Ei 's/^(bind-address|log|user\s)/#&/'; \
# don't reverse lookup hostnames, they are usually another container
	printf "[mariadb]\nhost-cache-size=0\nskip-name-resolve\n" > /etc/mysql/mariadb.conf.d/05-skipcache.cnf; \
# Issue #327 Correct order of reading directories /etc/mysql/mariadb.conf.d before /etc/mysql/conf.d (mount-point per documentation)
	if [ -L /etc/mysql/my.cnf ]; then \
# 10.5+
		sed -i -e '/includedir/ {N;s/\(.*\)\n\(.*\)/\n\2\n\1/}' /etc/mysql/mariadb.cnf; \
	fi


COPY --from=auth-k8s-build /build/auth_k8s.so /usr/lib/mysql/plugin/auth_k8s.so

VOLUME /var/lib/mysql

COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306
CMD ["mariadbd"]
