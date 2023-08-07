#!/bin/bash
## Dynamic DNS using Porkbun API

## Get values from files
APIKEY=$(cat /porkbun/apikey)
SECRETKEY=$(cat /porkbun/secretapikey)
DOMAIN=$(cat /porkbun/domainname)
LOG=/tmp/porkbunddns.log

## Get current public IP address
IPv4Status=$(curl -s \
--header "Content-Type: application/json" \
--request POST \
--data '{
"apikey" : "'"$APIKEY"'",
"secretapikey" : "'"$SECRETKEY"'"
}' \
	https://api-ipv4.porkbun.com/api/json/v3/ping)
if [[ "$IPv4Status" != *'SUCCESS'* ]]; then
	echo -e "`date '+%Y-%d-%m %H:%M:%S'`\nFailed to get IPv4 Address\nStatus: $IPv4Status" >>"$LOG"
	exit 1
fi
IPv4=$(echo "$IPv4Status" | grep -oE '((1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])')

## Get current A record for domain
ARecordStatus=$(curl -s \
--header "Content-Type: application/json" \
--request POST \
--data '{
"apikey" : "'"$APIKEY"'",
"secretapikey" : "'"$SECRETKEY"'"
}' \
	https://porkbun.com/api/json/v3/dns/retrieveByNameType/"$DOMAIN"/A)
if [[ "$ARecordStatus" != *'SUCCESS'* ]]; then
        echo -e "`date '+%Y-%d-%m %H:%M:%S'`\nFailed to get current A Record\nStatus: $ARecordStatus" >>"$LOG"
        exit 1
fi
ARecord=$(echo "$ARecordStatus" | grep -oE '((1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])')

## Update A Record if necessary, if an update is attempted log it
if [[ "$IPv4" == "$ARecord" ]]
then
	echo -e "`date '+%Y-%d-%m %H:%M:%S'`\nA Record already matches Public IP of $IPv4"
else
	UpdateStatus=$(curl -s \
	--header "Content-Type: application/json" \
	--request POST \
	--data '{
	"apikey" : "'"$APIKEY"'",
	"secretapikey" : "'"$SECRETKEY"'",
	"content" : "'"$IPv4"'"
	}' \
		https://porkbun.com/api/json/v3/dns/editByNameType/"$DOMAIN"/A)
	if [[ "$UpdateStatus" == *'SUCCESS'* ]]
	then
		echo -e "`date '+%Y-%d-%m %H:%M:%S'`\nA Record for $DOMAIN changed from $ARecord to $IPv4" >>"$LOG"
	else
		echo -e "`date '+%Y-%d-%m %H:%M:%S'`\nA Record Update Failed\nDomain Name: $DOMAIN\nDNS Record Update Status: $UpdateStatus\nCurrent A Record: $ARecord\nCurrent Public IP: $IPv4" >>"$LOG"
	fi
fi
