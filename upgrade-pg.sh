#!/bin/bash

# Stop on failure
set -e

DATE=`date +%Y-%m-%d`
PG_DATA="/var/lib/postgres/data"
TMP_DIR="/var/lib/postgres/tmp-$DATE"
OLD_DATA_DIR_PREFIX="/var/lib/postgres/old_data"

# Script start
PG_VERSION=`cat $PG_DATA/PG_VERSION`
OLD_DATA_DIR="$OLD_DATA_DIR_PREFIX-$PG_VERSION"
echo "Upgrading from Postgres $PG_VERSION..."

# Stopping the database if it's running
if systemctl is-active --quiet postgresql; then
    echo "Stopping the database..."
    systemctl stop postgresql
    # Wait to ensure PostgreSQL has fully stopped
    sleep 5
fi

# Double-check PostgreSQL is not running
if pgrep -x "postgres" > /dev/null; then
    echo "Error: PostgreSQL is still running. Please stop it manually."
    exit 1
fi

# Ensure the directory doesn't exist
if [ -d "$OLD_DATA_DIR" ]; then
    echo "Error: Old data directory $OLD_DATA_DIR already exists."
    exit 1
fi

if [ -d "$TMP_DIR" ]; then
    echo "Error: Tmp data directory $TMP_DIR already exists."
    exit 1
fi

# Move the old data directory
mv $PG_DATA $OLD_DATA_DIR

# Create the new data directory
mkdir $PG_DATA $TMP_DIR

# Set ownership
chown postgres:postgres $PG_DATA $TMP_DIR

# Init DB
echo "Init DB..."
su - postgres -s /bin/bash -c "cd ${TMP_DIR} && initdb -D ${PG_DATA} --locale=en_US.UTF-8 --encoding=UTF8"

# Run pg_upgrade
echo "pg_upgrade..."
su - postgres -s /bin/bash -c "pg_upgrade -b /opt/pgsql-${PG_VERSION}/bin -B /usr/bin -d ${OLD_DATA_DIR} -D ${PG_DATA}"

# Copy configuration
echo "Copying configuration..."
cp $OLD_DATA_DIR/postgresql.conf $PG_DATA
cp $OLD_DATA_DIR/pg_hba.conf $PG_DATA

# Start the database
echo "Starting the database..."
systemctl start postgresql

# Verify database started successfully
if ! systemctl is-active --quiet postgresql; then
    echo "Error: Failed to start PostgreSQL after upgrade."
    echo "Check logs with: journalctl -u postgresql"
    exit 1
fi

echo "Upgrade completed successfully!"
echo "Old data directory preserved at: $OLD_DATA_DIR"

#
# Post processing, some actions might be necessary on some of the databases:
#
# REINDEX DATABASE postgres;
#
# ALTER DATABASE postgres REFRESH COLLATION VERSION;
#
