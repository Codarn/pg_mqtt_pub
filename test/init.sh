#!/bin/bash
# Robust initialization script that handles race conditions

echo "Waiting for PostgreSQL to be ready..."
sleep 3

echo "Installing extensions in testdb..."

# Retry loop to handle race condition with background worker
for i in {1..10}; do
    echo "Attempt $i/10..."

    # Drop schema and create extension
    psql -h postgres -U postgres -d testdb -v ON_ERROR_STOP=0 <<-EOSQL 2>&1
        DROP SCHEMA IF EXISTS mqtt_pub CASCADE;
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        CREATE EXTENSION pg_mqtt_pub;
EOSQL

    # Check if extension was actually installed
    INSTALLED=$(psql -h postgres -U postgres -d testdb -tAc "SELECT COUNT(*) FROM pg_extension WHERE extname = 'pg_mqtt_pub'")

    if [ "$INSTALLED" = "1" ]; then
        echo "✓ pg_mqtt_pub extension installed successfully!"
        psql -h postgres -U postgres -d testdb -c "\dx"
        exit 0
    fi

    echo "Extension not yet installed, retrying in 1 second..."
    sleep 1
done

echo "✗ Failed to install pg_mqtt_pub extension after 10 attempts"
exit 1
