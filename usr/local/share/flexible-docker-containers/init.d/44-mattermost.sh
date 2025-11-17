#!/bin/bash
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


fdc_notice "Setting up Mattermost permissions"
# Make sure our data directory perms are correct
chown root:mattermost \
	/etc/mattermost \
	/etc/mattermost/config \
	/var/lib/mattermost \
	/var/log/mattermost
chmod 0770 \
	/var/log/mattermost
chmod 0750 \
	/etc/mattermost \
	/etc/mattermost/config \
	/var/lib/mattermost

fdc_notice "Initializing Mattermost settings"

# Work out database details
case "$MATTERMOST_DATABASE_TYPE" in
	postgres|postgresql)
		# Check for a few things we need
		if [ -z "$POSTGRES_DATABASE" ]; then
			fdc_error "Environment variable 'POSTGRES_DATABASE' is required"
			false
		fi
		if [ -z "$POSTGRES_HOST" ]; then
			fdc_error "Environment variable 'POSTGRES_HOST' is required"
			false
		fi
		if [ -z "$POSTGRES_USER" ]; then
			fdc_error "Environment variable 'POSTGRES_USER' is required"
			false
		fi
		if [ -z "$POSTGRES_PASSWORD" ]; then
			fdc_error "Environment variable 'POSTGRES_PASSWORD' is required"
			false
		fi
		database_type=postgres
		database_host=$POSTGRES_HOST
		database_name=$POSTGRES_DATABASE
		database_username=$POSTGRES_USER
		database_password=$POSTGRES_PASSWORD
		database_params="?sslmode=disable&connect_timeout=10"
		database_datasource="$database_type://$database_username:$database_password@$database_host/$database_name$database_params"
		;;

	*)
		# If we're running in FDC_CI mode, we can just skip the error as we default to 'dev-file'
		if [ -n "$FDC_CI" ]; then
			fdc_warn "Running with database 'dev-file' as 'MATTERMOST_DATABASE_TYPE' is not set"
		else
			fdc_error "Environment variable 'MATTERMOST_DATABASE_TYPE' must be set."
			false
		fi
		;;
esac


# Set up our database settings
cat <<EOF > /etc/mattermost/config.d/50-database.json
{
	"SqlSettings": {
		"DriverName": "$database_type",
		"DataSource": "$database_datasource"
	}
}
EOF
# Copy Bleve config over
cp -f /opt/mattermost/config.d/20-bleve.json /etc/mattermost/config.d/20-bleve.json
cp -f /opt/mattermost/config.d/20-enable-rate-limits.json /etc/mattermost/config.d/20-enable-rate-limits.json
cp -f /opt/mattermost/config.d/20-smtp.json /etc/mattermost/config.d/20-smtp.json
cp -f /opt/mattermost/config.d/20-no-file-logging.json /etc/mattermost/config.d/20-no-file-logging.json
# Set permissions on /etc/mattermost/config.d
find /etc/mattermost/config.d -type f -print0 | xargs -0 chmod 0640
find /etc/mattermost/config.d -type f -print0 | xargs -0 chown root:mattermost
# Merge all config files
# shellcheck disable=SC2094
(
	find /etc/mattermost/config.d -type f -name '*.json' | sort
	if [ -e /etc/mattermost/config/config.json ]; then
		echo /etc/mattermost/config/config.json
	fi
) | xargs jq -s add > /etc/mattermost/config/config.json.new
# Move new config file in place
mv /etc/mattermost/config/config.json.new /etc/mattermost/config/config.json
# Set permissions
chmod 0660 /etc/mattermost/config/config.json
chown root:mattermost /etc/mattermost/config/config.json

# Set up /var/lib/mattermost
# NK: must stay in sync with Dockerfile
for d in bleve files compliance plugins client/plugins; do
	if [ ! -d "/var/lib/mattermost/$d" ]; then
		install -dm0775 -o root -g mattermost "/var/lib/mattermost/$d"
	fi
done
# Mattermost needs to modify some files
find /opt/mattermost/client -type f -iname 'root.html.orig' -o -iname 'manifest.json.orig' -o -iname '*.css.orig' |
	while IFS= read -r fileAndPathOrig; do \
		fileAndPath="${fileAndPathOrig#/opt/mattermost/}"; \
		fileAndPath="${fileAndPath%.orig}"; \
		if [ ! -e "/var/lib/mattermost/$fileAndPath" ]; then
			install -Dm0664 -o root -g mattermost "$fileAndPathOrig" "/var/lib/mattermost/$fileAndPath"; \
		fi; \
	done

#
# Database initialization
#

if [ "$database_type" = "postgres" ]; then
	export PGPASSWORD="$POSTGRES_PASSWORD"

	while true; do
		fdc_notice "Mattermost waiting for PostgreSQL server '$POSTGRES_HOST'..."
		if pg_isready -d "$POSTGRES_DATABASE" -h "$POSTGRES_HOST" -U "$POSTGRES_USER"; then
			fdc_notice "PostgreSQL server is UP, continuing"
			break
		fi
		sleep 1
	done

	unset PGPASSWORD

fi
