#!/bin/bash


export PORT=8080
export USER=belenios
export GROUP=belenios

# Substitute $PORT, $USER, $GROUP and database variables in ocsigen.conf.template and write to ocsigen.conf
envsubst < /home/belenios/src/ocsigenserver.conf.template > /home/belenios/src/ocsigenserver.conf


exec "$@"