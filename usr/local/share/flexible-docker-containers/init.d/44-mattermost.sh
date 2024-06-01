#!/bin/bash
# Copyright (c) 2022-2024, AllWorldIT.
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
	mariadb|mysql)
		if [ -z "$MYSQL_DATABASE" ]; then
			fdc_error "Environment variable 'MYSQL_DATABASE' is required"
			false
		fi
		# Check for a few things we need
		if [ -z "$MYSQL_HOST" ]; then
			fdc_error "Environment variable 'MYSQL_HOST' is required"
			false
		fi
		if [ -z "$MYSQL_USER" ]; then
			fdc_error "Environment variable 'MYSQL_USER' is required"
			false
		fi
		if [ -z "$MYSQL_PASSWORD" ]; then
			fdc_error "Environment variable 'MYSQL_PASSWORD' is required"
			false
		fi
		database_type=mysql
		database_host="tcp($MYSQL_HOST)"
		database_name=$MYSQL_DATABASE
		database_username=$MYSQL_USER
		database_password=$MYSQL_PASSWORD
		database_params="?charset=utf8mb4,utf8&collation=utf8mb4_general_ci"
		database_datasource="$database_username:$database_password@$database_host/$database_name$database_params"
		;;

	postgresql)
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
cat <<EOF > /etc/mattermost/config.d/10-database.json
{
	"SqlSettings": {
		"DriverName": "$database_type",
		"DataSource": "$database_datasource"
	}
}
EOF
# Set permissions on /etc/mattermost/config.d
find /etc/mattermost/config.d -type f -print0 | xargs -0 chmod 0640
find /etc/mattermost/config.d -type f -print0 | xargs -0 chown root:mattermost
# Merge all config files
# shellcheck disable=SC2094
(
	echo /opt/mattermost/config/default.json
	find /etc/mattermost/config.d -type f -name '*.json'

	if [ -e /etc/mattermost/config/config.json ]; then
		echo /etc/mattermost/config/config.json
	fi
) | xargs jq -s add > /etc/mattermost/config/config.json
# Set permissions
chmod 0660 /etc/mattermost/config/config.json
chown root:mattermost /etc/mattermost/config/config.json

# Set up /var/lib/mattermost
# NK: must stay in sync with Dockerfile
for d in files compliance plugins client/plugins; do
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

elif [ "$database_type" = "mysql" ]; then
	export MYSQL_PWD="$MYSQL_PASSWORD"

	while true; do
		fdc_notice "Mattermost waiting for MySQL server '$MYSQL_HOST'..."
		if mysqladmin ping --host "$MYSQL_HOST" --user "$MYSQL_USER" --silent --connect-timeout=2; then
			fdc_notice "MySQL server is UP, continuing"
			break
		fi
		sleep 1
	done

	unset MYSQL_PWD
fi
