#!/bin/bash
## Retrieve Porkbun generated SSL Bundle using Porkbun API
## JSON responses parsed using jq 1.6

## Get values from files
APIKEY=$(cat /porkbun/apikey)
SECRETKEY=$(cat /porkbun/secretapikey)
DOMAIN=$(cat /porkbun/domainname)
LOG=/tmp/porkbunssl.log
OUTFOLDER=/porkbun/ssl-bundle

## Create OUTFOLDER if it doesn't already exist.
[ ! -d "$OUTFOLDER" ] && mkdir "$OUTFOLDER"

## Request SSL Bundle
JSONResponse=$(curl -s \
--header "Content-Type: application/json" \
--request POST \
--data '{
"apikey" : "'"$APIKEY"'",
"secretapikey" : "'"$SECRETKEY"'"
}' \
https://porkbun.com/api/json/v3/ssl/retrieve/"$DOMAIN")

## Ensure Retrieval Success
RetrievalStatus=$(jq -r '.status' <<<"$JSONResponse")
echo "Retrieval Status: $RetrievalStatus"
if [[ "$RetrievalStatus" != 'SUCCESS' ]]; then
	echo -e "`date '+%Y-%d-%m %H:%M:%S'`\nSSL Retrieval Failed\nResponse:\n$JSONResponse" >>"$LOG"
	exit 1
fi

## Write certificates to files
intermediatecertificate=$(jq -r '.intermediatecertificate' <<<"$JSONResponse")
certificatechain=$(jq -r '.certificatechain' <<<"$JSONResponse")
privatekey=$(jq -r '.privatekey' <<<"$JSONResponse")
publickey=$(jq -r '.publickey' <<<"$JSONResponse")

echo -e "$intermediatecertificate" > "$OUTFOLDER/$DOMAIN.intermediate.pem"
echo -e "$certificatechain" > "$OUTFOLDER/$DOMAIN.fullchain.pem"
echo -e "$privatekey" > "$OUTFOLDER/$DOMAIN.privatekey.pem"
echo -e "$publickey" > "$OUTFOLDER/$DOMAIN.publickey.pem"

## Convert cert to pkcs12 format
openssl pkcs12 -passout pass: -export -out "$OUTFOLDER/$DOMAIN.p12" -inkey "$OUTFOLDER/$DOMAIN.privatekey.pem" -in "$OUTFOLDER/$DOMAIN.fullchain.pem"

echo -e "`date '+%Y-%d-%m %H:%M:%S'`\nSSL Certs Updated" >>"$LOG"
