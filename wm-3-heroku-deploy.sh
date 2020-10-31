#!/bin/bash

# heroku create belenios-20201030
docker tag belenios-stage-3 registry.heroku.com/belenios-20201030/web
docker push registry.heroku.com/belenios-20201030/web 
heroku container:release web --app belenios-20201030
heroku open --app belenios-20201030

#
# For reference
#

# To run a bash shell
#
# heroku run bash --app xxx  

# To send an email
#
# exim -C /etc/exim4/exim4.conf -v warwick.mcnaughton@gmail.com
# From: warwick.mcnaughton@gmail.com
# To: wrmac0ton@gmail.com
# Subject: This it the subject
#
# This is the message body.
# Ctl-D

