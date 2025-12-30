# Use official pre-built pg_mooncake image (PostgreSQL 17 with pg_mooncake pre-installed)
FROM mooncakelabs/pg_mooncake:latest

USER root

# Create custom entrypoint to handle Railway volume mount with lost+found
RUN cat > /usr/local/bin/railway-entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -e

# Railway mounts volume - use different path to avoid conflict with other DBs
MOUNT_POINT="/var/lib/postgresql/mooncake"
ACTUAL_PGDATA="$MOUNT_POINT/pgdata"

# Create the actual data subdirectory if it doesn't exist
mkdir -p "$ACTUAL_PGDATA"
chown postgres:postgres "$ACTUAL_PGDATA"
chmod 700 "$ACTUAL_PGDATA"

# Override PGDATA to point to the subdirectory
export PGDATA="$ACTUAL_PGDATA"

# Run the original postgres entrypoint
exec docker-entrypoint.sh "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Create init script to configure mooncake with Railway S3 bucket (AWS SDK style variables)
RUN mkdir -p /docker-entrypoint-initdb.d && \
    cat > /docker-entrypoint-initdb.d/01-init-mooncake.sh <<'INITEOF'
#!/bin/bash
set -e

# Create mooncake extension
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS pg_mooncake CASCADE;"

# Configure S3 if bucket variables exist (Railway uses AWS_* style)
if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [ -n "$AWS_S3_BUCKET_NAME" ]; then
    ENDPOINT="${AWS_ENDPOINT_URL:-https://storage.railway.app}"
    REGION="${AWS_DEFAULT_REGION:-auto}"
    
    echo "Configuring mooncake with Railway S3 bucket: $AWS_S3_BUCKET_NAME"
    
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        SELECT mooncake.create_secret(
            'railway_s3',
            'S3',
            '$AWS_ACCESS_KEY_ID',
            '$AWS_SECRET_ACCESS_KEY',
            '{"REGION": "$REGION", "ENDPOINT": "$ENDPOINT"}'
        );
EOSQL
    echo "Mooncake S3 configured successfully!"
else
    echo "No Railway bucket configured - using local disk storage"
fi
INITEOF

RUN chmod +x /docker-entrypoint-initdb.d/01-init-mooncake.sh

# Set default environment variables
ENV POSTGRES_DB=railway

# Use custom entrypoint that handles lost+found issue
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["postgres"]