#!/bin/bash

VAR_CERT_TTL=365
VAR_CERT_CHANGE_THRESHOLD=355
VAR_CERT_URGENT_THRESHOLD=30
VAR_CONNECT_TIMEOUT=1
VAR_PORT=443 #default value
VAR_IP_SOURCE_FILE="takehome_ip_addresses.txt"
VAR_STATSD_SERVER="10.10.4.14"
VAR_STATSD_PORT=8125

#logger logs to syslog below, assumes forwarding is in place

if [ ! -f $VAR_IP_SOURCE_FILE ]; then
  logger -s -p local0.warn "WARNING: certificate check script could not find IP source file: ${VAR_IP_SOURCE_FILE}." 
  #notification via slack (could be spammy)
  curl -X POST -H 'Content-type: application/json' --data "
  {
    \"text\": \":warning: *WARNING:* certificate check script could not find IP source file: ${VAR_IP_SOURCE_FILE}.\"
  }" https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
  #add a metric to statsd (metric not specified)
  exit 1
else
  #loop through text file
  while read VAR_HOSTNAME; do
  VAR_SKIP=1

  #determine service group from hostname
  VAR_FIRST_THREE=$(echo $VAR_HOSTNAME | awk -F"." '{ print $1"."$2"."$3 }')
  echo "debug: checking $VAR_FIRST_THREE for group"
  if [ "$VAR_FIRST_THREE" == "10.10.6" ]; then
    echo "debug: europa, 4000"
    VAR_PORT=4000
    VAR_SVC="europa"
  elif [ "$VAR_FIRST_THREE" == "10.10.8" ]; then
    echo "debug: callisto, 8000"
    VAR_PORT=8000
    VAR_SVC="callisto"
  else
    logger -s -p local0.info "INFO: certificate check script, error reading hostname: ${VAR_HOSTNAME}. Cannot identify service from IPv4 address."
    VAR_SKIP=0
    #notification via slack (could be spammy)
    curl -X POST -H 'Content-type: application/json' --data "
    {
      \"text\": \":warning: _INFO_: certificate check script, error reading hostname: ${VAR_HOSTNAME}. Cannot identify service from IPv4 address.\"
    }" https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
    #add a metric to statsd (metric not specified)
  fi

  if [ $VAR_SKIP == 1 ]; then
    #test connectivity
    VAR_CONNECT_TEST=$(nc -z -w $VAR_CONNECT_TIMEOUT $VAR_HOSTNAME $VAR_PORT &> /dev/null && echo 0 || echo 1)
    if [ $VAR_CONNECT_TEST -eq 1 ]; then
      logger -s -p local0.warn "certificate check: connection test failed for ${VAR_HOSTNAME}"
      #notification via slack (could be spammy)
      curl -X POST -H 'Content-type: application/json' --data "
      {
        \"text\": \":warning: *WARNING:* certificate check script could not reach host: ${VAR_HOSTNAME}.\"
      }" https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
      #add a metric to statsd (metric not specified)
    else
      VAR_EXPDATE=$(echo | openssl s_client "${VAR_HOSTNAME}:${VAR_PORT}" 2>/dev/null | openssl x509 -noout -enddate | awk -F"=" '{ print $2 }' | awk -F" " '{ print $1 " " $2 " " $4 }' |  xargs -I {} sh -c 'date -d "{}" +%Y%m%d') 
      VAR_NOW=$(date +%Y%m%d)
      VAR_DELTA=$((VAR_EXPDATE-VAR_NOW))
      echo "debug: expiration date ($VAR_EXPDATE) - now ($VAR_NOW) = days remaining ($VAR_DELTA)"

      #take action
      if [ $VAR_DELTA -le $VAR_CERT_CHANGE_THRESHOLD ]; then
        #warn
        echo "debug: warn"
        logger -s -p local0.warn "WARNING: certificate was not renewed on ${VAR_HOSTNAME}"
        echo "certs.$VAR_SVC.outdated:1|g" | nc -u -w 0 $VAR_STATSD_SERVER $VAR_STATSD_PORT 
        curl -X POST -H 'Content-type: application/json' --data "
        {
          \"text\": \":warning: *WARNING:* certificate was not renewed on *_${VAR_HOSTNAME}_*.\"
        }" https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
    
      elif [ $VAR_DELTA -le $VAR_CERT_URGENT_THRESHOLD ]; then
        #urgent warning
        logger -s -p local0.crit "URGENT: certificate on ${VAR_HOSTNAME} is expiring soon."
        echo "certs.$VAR_SVC.expiring:1|g" | nc -u -w 0 $VAR_STATSD_SERVER $VAR_STATSD_PORT
        curl -X POST -H 'Content-type: application/json' --data "
        {
          \"text\": \":exclamation: *URGENT:* certificate on *_${VAR_HOSTNAME}_* is expiring soon.\"
        }" https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
      
      elif [ $VAR_DELTA -le 0 ]; then
        #expired 
        logger -s -p local0.emer "ACTION REQUIRED NOW: certificate EXPIRED ${VAR_HOSTNAME}."
        echo "certs.$VAR_SVC.expired:1|g" | nc -u -w 0 $VAR_STATSD_SERVER $VAR_STATSD_PORT
        curl -X POST -H 'Content-type: application/json' --data "
        {
          \"text\": \":fire: *ACTION REQUIRED NOW:* certificate EXPIRED *_${VAR_HOSTNAME}_*.\"
        }" https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
      
      else
        #all is good
        logger -s -p local0.info "${VAR_HOSTNAME} certificate ok, ($VAR_DELTA) days remaining."
      fi
    fi
  fi
  done <$VAR_IP_SOURCE_FILE
fi
