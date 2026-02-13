FROM postgres:17

# Install build dependencies and PostgreSQL extensions
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    postgresql-server-dev-17 \
    libmosquitto-dev \
    pkg-config \
    postgresql-17-cron \
    && rm -rf /var/lib/apt/lists/*

# Set up build directory
WORKDIR /build/pg_mqtt_pub

# Copy build files (better layer caching - build config rarely changes)
COPY Makefile pg_mqtt_pub.control ./

# Copy source code
COPY src/ ./src/
COPY sql/ ./sql/

# Build and install the extension
RUN make clean && make && make install

# Copy initialization script to run on container startup
COPY test/init.sql /docker-entrypoint-initdb.d/01-init.sql

# Clean up build directory and return to root
WORKDIR /
RUN rm -rf /build/pg_mqtt_pub
