-- PostgreSQL initialization script for pg_mqtt_pub Docker environment

-- Create pg_mqtt_pub database
CREATE DATABASE pg_mqtt_pub;

-- Setup testdb
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_mqtt_pub;

-- Setup pg_mqtt_pub database
\c pg_mqtt_pub
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_mqtt_pub;
