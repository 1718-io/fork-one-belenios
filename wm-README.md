# Deploy Belenios to Heroku's free tier

## Challenges

You might wish to deploy Belenios to Heroku's free tier for testing purposes.  This repository provides solutions to the following challenges:

| Challenge       |   Solution     |
|-----------------|----------------| 
|Heroku does not have an Ocaml build-pack |Deploy to a docker container|
|Heroku free dynos sleep when idle and all data is lost |Catch the process signal and save data to a Postgresql database |
|Belenios sends emails to voters |Include Exim mailer to send emails to Gmail SMTP relay service|
|Heroku substitutes its own user |Provide variable substitution for ocsigenserver, exim and pgocaml configurations|


## Changes to belenios source files

I have kept changes to original belenios source files to a minimum. `wm-CHANGES_TO_FILES.md` contains details.

All additional code is in files with `wm-` prefix.

## Docker images

This deployment requires three Docker images for a staged build.  The third image imports the other two stages. Only deploy the third image to Heroku. 

|Image            | Build by running   | Image size | What it does       |
|-----------------|--------------------|------------|-------------------|
|belenios-stage-1 |wm-1-build.sh       |3.4 GB      |Installs a full Ocaml development environment and compiles belenios|
|belenios-stage-2 |wm-2-build.sh       |347 MB      |Compiles exim      |
|belenios-stage-3 |wm-3-build.sh       |516 MB      |Uses first two stages to build image for deployment to Heroku|

## Credentials

The deployment requires secret credentials for:

- PGOCaml's database access
- Exim's access to Gmail's SMTP relay service 
- Belenios logon authentication in ocsigenserver.conf

You must create the following files which contain your credentials

- `wm-1-secrets` which must contain the following

```shell
# For PGOCaml database access
export DB_HOST=
export DB_PORT=
export DB_USER=
export DB_PASSWORD=
export DB_DATABASE=

# For ocsigenserver.conf - Google authentication
export CLIENT_ID=
export CLIENT_SECRET=
```
- `wm-3-secrets`: copy `wm-1-secrets`
- `wm-3-secrets-gmail`:

```shell
# For Exim - which is configured to use Gmail
address=
password=
```
See 'Notes' below for further details.

## Flow

A basic work flow is as follows.

- create credential files
- create local postgresql database
- in the local database create a table `belenios_data` (PGOCaml requires compile-time access to a database for its ppx, so this is a requirement for building stage 1)

```shell
psql
CREATE TABLE belenios_data (path varchar(200), txt varchar(10000));
```
- create heroku app with the Heroku Postgres add-on

```shell
# Create Heroku app (once only)
heroku container:login
heroku create [app name]

# Go to Heroku dashboard and add the Heroku Postgres add-on to your app then:

heroku pg:psql --app [app name]
CREATE TABLE belenios_data (path varchar(200), txt varchar(10000));
```
- build images and deploy to Heroku

```shell
# Build images
./wm-1-build.sh
./wm-2-build.sh
./wm-3-build.sh

# Deploy to Heroku
docker tag belenios-stage-3 registry.heroku.com/[app name]/web
docker push registry.heroku.com/[app name]/web 
heroku container:release web --app [app name]
heroku open --app [app name]
```

## Notes

### Google Oauth authentication

To provide for your app to use Google Oauth authentication of users, go to [Google Cloud Platform](https://console.cloud.google.com), create a new project (drop-down at top) then go to "API's and Services" then "Credentials" then "Create credentials" then "OAuth client ID".

- Application type is "Web application".
- Provide an appropriate name.
- Authorised redirect URI's should include:

```shell
http://localhost:8080/auth/oidc
https://[app name].herokuapp.com/auth/oidc
http://[app name].herokuapp.com/auth/oidc
```

When created you will be provided a "Client ID" and "Client secret" for using in `wm-1-secrets` (and `wm-3-secrets`).

### Gmail SMTP relay

To use your personal Gmail account for relaying email messages, go to your Google account settings then "Security" then "Signing into Google" then "App passwords".  This provides for creating a 16 digit password for giving an app access to your full Google account.  In wm-3-secrets-gmail:

```shell
address: [your gmail address]
password: [the 16-digit password]
```
### PGOCaml

PGOCaml requires access to a database at both compile-time and run-time.  At compile-time, the database will be on your local machine but PGOCaml will be trying to access it from inside an intermediate build container.  I found that using `host.docker.internal` worked for the PGHOST setting.

When building stage 3 for deployment to Heroku, ensure `HEROKU=true` is set in `wm-3-entrypoint.sh`
 
### Staged builds

Having separate staged builds means it is possible to run each stage locally in a container for testing purposes.  For the stage 3 build, if being built for runnning in a local container, ensure `HEROKU=false` is set in `wm-3-entrypoint.sh`


