FROM postgres:18

USER root

# Install dependencies including S3 support
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    postgresql-server-dev-18 \
    libcurl4-openssl-dev \
    libssl-dev \
    pkg-config \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pg_mooncake with S3 support
RUN git clone https://github.com/Mooncake-Labs/pg_mooncake.git /tmp/pg_mooncake && \
    cd /tmp/pg_mooncake && \
    make && \
    make install && \
    rm -rf /tmp/pg_mooncake

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
    CREATE EXTENSION IF NOT EXISTS mooncake;
    
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
            PERFORM mooncake.set_config('s3_endpoint', s3_endpoint);
            PERFORM mooncake.set_config('s3_access_key', s3_access_key);
            PERFORM mooncake.set_config('s3_secret_key', s3_secret_key);
            PERFORM mooncake.set_config('s3_bucket', s3_bucket);
            PERFORM mooncake.set_config('s3_region', s3_region);
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
CMD ["postgres", "-c", "shared_preload_libraries=pg_stat_statements", "-c", "max_connections=100"]