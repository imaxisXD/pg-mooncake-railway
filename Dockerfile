# Use official pre-built pg_mooncake image (PostgreSQL 17 with pg_mooncake pre-installed)
FROM mooncakelabs/pg_mooncake:latest

USER root

# Create init script to configure mooncake with Railway S3 bucket
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
# Use subdirectory to avoid lost+found issue with Railway volume mounts
ENV PGDATA=/var/lib/postgresql/mooncake/data