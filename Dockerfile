# Copyright (c) 2022-2025, AllWorldIT.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.


FROM registry.conarx.tech/containers/alpine/3.21 as builder

COPY --from=registry.conarx.tech/containers/nodejs/3.21:22.14.0 /opt/nodejs-22.14.0 /opt/nodejs-22.14.0

ENV MATTERMOST_VER=10.5.2



# Install libs we need
RUN set -eux; \
	true "Installing build dependencies"; \
	apk add --no-cache \
		# For NodeJS
		icu \
		libuv \
		# For Build
		build-base \
		autoconf \
		automake \
		libtool \
		intltool \
		pkgconf \
		nasm \
		\
		git \
		jq \
		moreutils \
		curl \
		libpng-dev \
		\
		go


# Download Mattermost
RUN set -eux; \
	mkdir build; \
	cd build; \
	true "Downloading Mattermost"; \
	# Grab Mattermost
	curl -L "https://github.com/mattermost/mattermost/archive/refs/tags/v${MATTERMOST_VER}.tar.gz" \
		-o "mattermost-${MATTERMOST_VER}.tar.gz"

# Prepare Mattermost
RUN set -eux; \
	cd build; \
	# Setup environment
	for i in /opt/*/ld-musl-x86_64.path; do \
		cat "$i" >> /etc/ld-musl-x86_64.path; \
	done; \
	for i in /opt/*/PATH; do \
		export PATH="$(cat "$i"):$PATH"; \
	done; \
	# Extract
	srcdir="$(pwd)"; \
	tar -zxf "mattermost-$MATTERMOST_VER.tar.gz"; \
	cd "mattermost-$MATTERMOST_VER"; \
	# Server
	cd server; \
	go mod vendor -e; \
	go mod tidy -e; \
	# The configuration isn’t available at this time yet, modify the default.
    sed -r -i build/release.mk \
        -e  's!config/config.json!config/default.json!' \
        -e 's/\$\(DIST_PATH\)\/config\/config.json/\$\(DIST_PATH\)\/config\/default.json/'; \
	# Don’t embed a precompiled mmctl
    sed '/@#Download MMCTL/,+2d' -i build/release.mk; \
	# Remove platform specific precompiled plugin downloads
    sed '/# Download prepackaged plugins/,+8d' -i build/release.mk; \
	# Webapp
	cd ../webapp; \
	# Our NPM is too new to pass build time checks.
    # (Upstream isn't even adhering to this in their own CI.)
    jq 'del(.engines)' package.json | sponge package.json; \
	# Modify npm commands to always use srcdir cache
    sed -r -i Makefile \
        -e "/^\tnpm /s!npm!npm --cache '$srcdir/npm-cache' --no-audit --no-fund!"; \
    make -j $(nproc) -l 8 node_modules -W package.json

# Build Mattermost
RUN set -eux; \
	cd build; \
	cd "mattermost-$MATTERMOST_VER"; \
	# Setup environment
	for i in /opt/*/PATH; do \
		export PATH="$(cat "$i"):$PATH"; \
	done; \
	# Server
    cd server; \
	. /etc/buildflags; \
    export CGO_CPPFLAGS="$CXXFLAGS"; \
    export CGO_CFLAGS="$CFLAGS"; \
    export CGO_CXXFLAGS="$CXXFLAGS"; \
    export CGO_LDFLAGS="$LDFLAGS"; \
    export GOFLAGS="-buildmode=pie -trimpath -mod=readonly -modcacherw"; \
    export _config=github.com/mattermost/mattermost/server/public/model; \
    # https://github.com/mattermost/mattermost/issues/24582
    make -j $(nproc) -l 8 setup-go-work; \
    go build -v \
		-ldflags "-linkmode external \
            -X \"$_config.BuildDate=$(date --utc +"%Y-%m-%d %H:%M:%S")\" \
            -X \"$_config.BuildHash=Conarx Containers - Mattermost ($MATTERMOST_VER)\" \
            -X \"$_config.BuildHashEnterprise=none\" \
            -X \"$_config.BuildEnterpriseReady=false\"" \
		-o bin/ ./...; \
    # Move to the client directory to avoid LDFLAGS pollution of a `make build-client` invocation
    cd ../webapp; \
    npm run build; \
    cd ../server; \
    make -j $(nproc) -l 8 package-prep

# Install Mattermost
RUN set -eux; \
	cd build; \
	cd "mattermost-$MATTERMOST_VER"; \
	pkgdir="/build/mattermost-root"; \
	\
	install -m 0755 -d "$pkgdir/opt/mattermost"; \
	cp -R server/dist/mattermost/* "$pkgdir/opt/mattermost/"; \
	\
	mkdir -p "$pkgdir/opt/mattermost/bin"; \
	install -m 0755 server/bin/mattermost "$pkgdir/opt/mattermost/bin/"; \
	install -m 0755 server/bin/mmctl "$pkgdir/opt/mattermost/bin/"; \
	\
	mkdir -p "$pkgdir/var/logs/mattermost"; \
	rm -rf "$pkgdir/opt/mattermost/logs"; \
	ln -s "/var/logs/mattermost" "$pkgdir/opt/mattermost/logs"; \
	\
	mv "$pkgdir/opt/mattermost/README.md" "$pkgdir/opt/mattermost/"; \
	mv "$pkgdir/opt/mattermost/NOTICE.txt" "$pkgdir/opt/mattermost/"; \
	\
	mkdir -p "$pkgdir/etc/mattermost/config.d"; \
	\
	# Move config to /etc/mattermost
	install -dm0750 "$pkgdir/etc/mattermost/config"; \
	ln -s "/etc/mattermost/config/config.json" "$pkgdir/opt/mattermost/config/config.json"; \
    # Hashtags are needed to escape the Bash escape sequence. jq will consider
    # it as a comment and won't interpret it.
    jq --arg mmVarLib '/var/lib/mattermost' \
            '.ServiceSettings.ListenAddress |= ":8080" |  \
			.FileSettings.Directory |= $mmVarLib + "/files/" |  \
            .ComplianceSettings.Directory |= $mmVarLib + "/compliance/" |  \
            .PluginSettings.Directory |= $mmVarLib + "/plugins/" |  \
            .PluginSettings.ClientDirectory |= $mmVarLib + "/client/plugins/" |  \
			.LogSettings.EnableColor |= true |  \
			.LogSettings.FileJson |= false |  \
            .LogSettings.FileLocation |= "/var/log/mattermost/" |  \
            .NotificationLogSettings.FileLocation |= "/var/log/mattermost/"' \
        "$pkgdir/opt/mattermost/config/default.json" > "$pkgdir/etc/mattermost/config.d/10-defaults.json"; \
	# Set up /var/log/mattermost
	install -dm0750 "$pkgdir/var/log/mattermost"; \
	# Add plugins dir
	ln -s "/var/lib/mattermost/client/plugins" "$pkgdir/opt/mattermost/client/plugins"; \
	# Set up /var/lib/mattermost
	# NK: must stay in sync with init
	install -dm0770 "$pkgdir/var/lib/mattermost/bleve"; \
	install -dm0770 "$pkgdir/var/lib/mattermost/files"; \
	install -dm0770 "$pkgdir/var/lib/mattermost/compliance"; \
	install -dm0770 "$pkgdir/var/lib/mattermost/plugins"; \
	install -dm0770 "$pkgdir/var/lib/mattermost/client/plugins"; \
	# Mattermost needs to modify some files
	cd "$pkgdir/opt/mattermost"; \
	find client -type f -iname 'root.html' -o -iname 'manifest.json' -o -iname '*.css' | \
		while IFS= read -r fileAndPath; do \
			install -Dm0660 "$fileAndPath" "$pkgdir/var/lib/mattermost/$fileAndPath"; \
			mv "$fileAndPath" "$fileAndPath".orig; \
			ln -sv "/var/lib/mattermost/$fileAndPath" "$fileAndPath"; \
		done

# Strip binaries
RUN set -eux; \
	cd build/mattermost-root; \
	scanelf --recursive --nobanner --osabi --etype "ET_DYN,ET_EXEC" .  | awk '{print $3}' | xargs \
		strip \
			--remove-section=.comment \
			--remove-section=.note \
			-R .gnu.lto_* -R .gnu.debuglto_* \
			-N __gnu_lto_slim -N __gnu_lto_v1 \
			--strip-unneeded



FROM registry.conarx.tech/containers/postfix/3.21


ARG VERSION_INFO=

LABEL org.opencontainers.image.authors   = "Nigel Kukard <nkukard@conarx.tech>"
LABEL org.opencontainers.image.version   = "3.21"
LABEL org.opencontainers.image.base.name = "registry.conarx.tech/containers/postfix/3.21"

# Copy in built binaries
COPY --from=builder /build/mattermost-root /

RUN set -eux; \
	true "Utilities"; \
	apk add --no-cache \
		# For Mattermost
		curl \
		jq \
		mariadb-client \
		mariadb-connector-c \
		postgresql-client; \
	true "User setup"; \
	addgroup -S mattermost 2>/dev/null; \
	adduser -S -D -H -h /var/lib/mattermost -s /sbin/nologin -G mattermost -g mattermost mattermost; \
	true "Cleanup"; \
	rm -f /var/cache/apk/*


# Mattermost
COPY etc/mattermost/config.d/20-bleve.json /opt/mattermost/config.d/20-bleve.json
COPY etc/mattermost/config.d/20-enable-rate-limits.json /opt/mattermost/config.d/20-enable-rate-limits.json
COPY etc/mattermost/config.d/20-smtp.json /opt/mattermost/config.d/20-smtp.json
COPY etc/mattermost/config.d/20-no-file-logging.json /opt/mattermost/config.d/20-no-file-logging.json
COPY etc/supervisor/conf.d/mattermost-server.conf /etc/supervisor/conf.d/mattermost-server.conf
COPY etc/supervisor/conf.d/mattermost-jobserver.conf /etc/supervisor/conf.d/mattermost-jobserver.conf
COPY usr/local/share/flexible-docker-containers/healthcheck.d/44-mattermost.sh /usr/local/share/flexible-docker-containers/healthcheck.d
COPY usr/local/share/flexible-docker-containers/init.d/44-mattermost.sh /usr/local/share/flexible-docker-containers/init.d
COPY usr/local/share/flexible-docker-containers/pre-init-tests.d/44-mattermost.sh /usr/local/share/flexible-docker-containers/pre-init-tests.d
COPY usr/local/share/flexible-docker-containers/tests.d/44-mattermost.sh /usr/local/share/flexible-docker-containers/tests.d
COPY usr/local/share/flexible-docker-containers/tests.d/99-mattermost.sh /usr/local/share/flexible-docker-containers/tests.d
COPY usr/local/bin/start-mattermost-server /usr/local/bin/start-mattermost-server
COPY usr/local/bin/start-mattermost-jobserver /usr/local/bin/start-mattermost-jobserver
RUN set -eux; \
	true "Flexible Docker Containers"; \
	if [ -n "$VERSION_INFO" ]; then echo "$VERSION_INFO" >> /.VERSION_INFO; fi; \
	chown root:mattermost \
		/etc/mattermost \
		/etc/mattermost/config \
		/var/lib/mattermost \
		/var/log/mattermost; \
	chown root:root \
		/usr/local/bin/start-mattermost-server \
		/usr/local/bin/start-mattermost-jobserver; \
	chmod 0750 \
		/etc/mattermost \
		/etc/mattermost/config \
		var/lib/mattermost \
		/var/log/mattermost; \
	chmod 0755 \
		/usr/local/bin/start-mattermost-server \
		/usr/local/bin/start-mattermost-jobserver; \
	fdc set-perms


VOLUME ["/etc/mattermost/config"]
VOLUME ["/var/lib/mattermost"]

EXPOSE 8080
