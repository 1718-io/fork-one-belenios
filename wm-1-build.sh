#! /bin/bash

# wm-1-secrets contains credentials for accessing the Postgresql database in the form:
# export DB_PORT=xxxx
# export DB_DATABASE=xxxx
# export DB_HOST=xxxx
# export DB_USER=xxxx
# export DB_PASSWORD=xxxx
# export CLIENT_ID=xxxx
# export CLIENT_SECRET=xxxx

source wm-1-secrets

docker build -f wm-1-Dockerfile \
    --build-arg PGHOST=${DB_HOST} \
    --build-arg PGPORT=${DB_PORT} \
    --build-arg PGUSER=${DB_USER} \
    --build-arg PGDATABASE=${DB_DATABASE} \
    --build-arg PGPASSWORD=${DB_PASSWORD} \
    --build-arg CLIENT_ID=${CLIENT_ID} \
    --build-arg CLIENT_SECRET=${CLIENT_SECRET} \
    -t belenios-stage-1 .
