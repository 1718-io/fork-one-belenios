#!/bin/bash

# Environment variables

HEROKU=true


if [ "$HEROKU" = "true" ]
then
    export USER="$(whoami)"
    export GROUP=dyno
    export PORT=${PORT}
    sed -i "s/exim_user = mail/exim_user = "$(whoami)"/" /etc/exim4/exim4.conf 
    sed -i "s/# exim_group = mail/exim_group = dyno/" /etc/exim4/exim4.conf 

    # Database variables
    # extract the protocol and remove it
    proto="$(echo $DATABASE_URL | sed -e's,^\(.*://\).*,\1,g')"
    url="$(echo ${DATABASE_URL/$proto/})"
    # extract the user
    userpass="$(echo $url | grep @ | cut -d@ -f1)"
    pass="$(echo $userpass | grep : | cut -d: -f2)"
    user="$(echo $userpass | grep : | cut -d: -f1)"
    # extract the host with port
    hostport="$(echo ${url/$user:$pass@/} | cut -d/ -f1)"
    # extract the port
    port="$(echo $hostport | sed -e 's,^.*:,:,g' -e 's,.*:\([0-9]*\).*,\1,g' -e 's,[^0-9],,g')"
    # extract the host
    host="$(echo ${hostport/$port} | cut -d: -f1)"
    # extract the path (if any)
    path="$(echo $url | grep / | cut -d/ -f2-)"

    source secrets
    export PGHOST=$host
    export PGPORT=$port
    export PGUSER=$user
    export PGPASSWORD=$pass
    export PGDATABASE=$path
    export CLIENT_ID=$CLIENT_ID
    export CLIENT_SECRET=$CLIENT_SECRET
else
    source secrets
    export PORT=8080
    export USER=belenios
    export GROUP=belenios
    export PGHOST=$DB_HOST
    export PGPORT=$DB_PORT
    export PGUSER=$DB_USER
    export PGPASSWORD=$DB_PASSWORD
    export PGNAME=$DB_NAME
    export CLIENT_ID=$CLIENT_ID
    export CLIENT_SECRET=$CLIENT_SECRET
fi

# Substitute $PORT, $USER, $GROUP and database variables in ocsigen.conf.template and write to ocsigen.conf
envsubst < /home/belenios/src/ocsigenserver.conf.template > /home/belenios/src/ocsigenserver.conf

export PATH=/usr/exim:$PATH


exec "$@"