FROM postgres:18

USER root

# Install base dependencies
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    postgresql-server-dev-18 \
    libcurl4-openssl-dev \
    libssl-dev \
    pkg-config \
    ca-certificates \
    curl \
    cmake \
    && rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install latest cargo-pgrx (0.16.0+ supports PostgreSQL 18)
RUN cargo install --locked cargo-pgrx --version 0.16.0

# Clone pg_mooncake with submodules
RUN git clone --recurse-submodules https://github.com/Mooncake-Labs/pg_mooncake.git /tmp/pg_mooncake

# Initialize pgrx with PostgreSQL 18
WORKDIR /tmp/pg_mooncake
RUN cargo pgrx init --pg17=/usr/lib/postgresql/18/bin/pg_config

# Install pg_duckdb first (required dependency)
RUN make pg_duckdb PG_VERSION=pg17

# Install pg_mooncake
RUN make install PG_VERSION=pg17

# Cleanup
RUN rm -rf /tmp/pg_mooncake /root/.cargo/registry /root/.cargo/git
WORKDIR /

# Configure PostgreSQL
RUN echo "duckdb.allow_community_extensions = true" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "shared_preload_libraries = 'pg_duckdb,pg_mooncake'" >> /usr/share/postgresql/postgresql.conf.sample && \
    echo "wal_level = logical" >> /usr/share/postgresql/postgresql.conf.sample

# Create custom entrypoint to fix permissions
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Ensure PGDATA directory exists and has correct permissions\n\
mkdir -p "$PGDATA"\n\
chown postgres:postgres "$PGDATA"\n\
chmod 700 "$PGDATA"\n\
\n\
# Switch to postgres user and run original entrypoint\n\
exec gosu postgres docker-entrypoint.sh "$@"' > /usr/local/bin/custom-entrypoint.sh && \
    chmod +x /usr/local/bin/custom-entrypoint.sh

# Create init script for mooncake with Railway S3 configuration
RUN mkdir -p /docker-entrypoint-initdb.d && \
    cat > /docker-entrypoint-initdb.d/01-init-mooncake.sh <<'EOF'
#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create mooncake extension
    CREATE EXTENSION IF NOT EXISTS pg_mooncake CASCADE;
    
    -- Configure S3 from Railway bucket environment variables
    DO \$\$
    DECLARE
        s3_endpoint TEXT;
        s3_access_key TEXT;
        s3_secret_key TEXT;
        s3_bucket TEXT;
        s3_region TEXT;
    BEGIN
        -- Read Railway S3 environment variables
        s3_endpoint := current_setting('BUCKET_ENDPOINT', true);
        s3_access_key := current_setting('BUCKET_ACCESS_KEY_ID', true);
        s3_secret_key := current_setting('BUCKET_SECRET_ACCESS_KEY', true);
        s3_bucket := current_setting('BUCKET_NAME', true);
        s3_region := COALESCE(current_setting('BUCKET_REGION', true), 'us-west-1');
        
        -- Configure Mooncake if S3 variables exist
        IF s3_endpoint IS NOT NULL AND s3_access_key IS NOT NULL THEN
            PERFORM mooncake.create_secret('railway_s3', 'S3', s3_access_key, s3_secret_key, 
                format('{"REGION": "%s", "ENDPOINT": "%s"}', s3_region, s3_endpoint)::json);
            PERFORM set_config('mooncake.default_bucket', format('s3://%s', s3_bucket), false);
            RAISE NOTICE 'Mooncake configured with Railway S3 bucket: %', s3_bucket;
        ELSE
            RAISE NOTICE 'No Railway bucket configured - using local disk storage';
        END IF;
    END \$\$;
EOSQL
EOF

RUN chmod +x /docker-entrypoint-initdb.d/01-init-mooncake.sh

# Set default environment variables
ENV POSTGRES_DB=railway
ENV PGDATA=/var/lib/postgresql/data

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
CMD ["postgres"]