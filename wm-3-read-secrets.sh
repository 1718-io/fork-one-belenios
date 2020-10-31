#!/bin/bash

while read line; 
do
   eval "${line}"
done < secrets-gmail

sed -i "s/client_send = secret/client_send = : "${address}" : "${password}"/" /etc/exim4/exim4.conf
sed -i "s/client_send = secret/client_send = : "${address}" : "${password}"/" /usr/exim/etc/exim4.conf