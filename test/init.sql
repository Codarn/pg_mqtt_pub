-- PostgreSQL initialization script for pg_mqtt_pub Docker environment
-- Runs via init container after PostgreSQL is ready

-- Setup testdb (default database) - create extensions here
\c testdb
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP SCHEMA IF EXISTS mqtt_pub CASCADE;
CREATE EXTENSION pg_mqtt_pub;

\echo 'Extensions installed successfully in testdb!'
