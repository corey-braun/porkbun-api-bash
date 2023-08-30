#!/usr/bin/env bash
## https://github.com/corey-braun/porkbun-api-bash
## Requires jq 1.6+ for interacting with JSON data

## Set default variable values
VERBOSITY=5
LOGFILE='/tmp/porkbun-api.log'
SILENT=false
A_RECORD_NUM=0
CHECK_CURRENT_CERT=true
certificatechain_name=fullchain
intermediatecertificate_name=intermediate

usage_message="\
Usage: $0 [-hs46] [-v <verbosity>] [-d <domain>] <command> [args]
    -h prints this help message
    -s enables silent mode (no output sent to STDOUT)
    -4 forces using IPv4 to make API calls
    -6 forces using IPv6 to make API calls
    -v sets verbosity to a value 0-7
    -d sets the domain name to take action on
Available commands:
    update-dns: Update the DNS A record for a domain. If multiple A records are present the default is to update the first one.
    retrieve-ssl: Retrieve the porkbun-generated wildcard SSL cert for a domain.
    ping: Make an API call to the ping endpoint. Useful for verifying your credentials and connection.
    custom <endpoint> [data]: Make a custom API call. API endpoint and (optional) JSON data to send can be specified as arguments following the command, or through an interactive dialog if no additional arguments are provided."

## Main function, only executed if script was not sourced in another script
main() {
    source_config
    ## Parse flags
    while getopts ":hsv:46d:" opt; do
        case $opt in
            h)
                echo "$usage_message"; exit 0
                ;;
            s)
                SILENT=true
                ;;
            v)
                [ "${OPTARG: -1}" = '-' ] && usage "Missing required argument for '-v'"
                VERBOSITY="$OPTARG"
                ;;
            d)
                [ "${OPTARG: -1}" = '-' ] && usage "Missing required argument for '-d'"
                DOMAIN="$OPTARG"
                ;;
            4)
                [ "$IP_VERSION_FLAG" ] && usage "Flags '-4' and '-6' are mutually exclusive"
                IP_VERSION_FLAG=true
                IP_VERSION='-4'
                ;;
            6)
                [ "$IP_VERSION_FLAG" ] && usage "Flags '-4' and '-6' are mutually exclusive"
                IP_VERSION_FLAG=true
                IP_VERSION='-6'
                ;;
            *)
                usage "Invalid flag: -$OPTARG"
                ;;
        esac
    done
    shift $(($OPTIND - 1))

    ## Check required variables are correctly set
    vars_set VERBOSITY APIKEY SECRETKEY
    vars_formatting

    ## Execute specified function
    [ $# -eq 0 ] && usage "No command specified"
    case $1 in
        update-dns)
            vars_set DOMAIN A_RECORD_NUM
            update_dns
            ;;
        retrieve-ssl)
            vars_set DOMAIN
            retrieve_ssl
            ;;
        ping)
            log 6 "Making 'ping' API call"
            api_call 'ping'
            echo "API Response:"
            echo "$api_response" | jq .
            SILENT=true
            log_exit "Ping API call successful; API Response: $api_response" 5
            ;;
        custom)
            local endpoint_end api_data
            if [ -z "$2" ]; then
                echo -n "Enter API endpoint: https://porkbun.com/api/json/v3/"
                read endpoint_end
                echo -n "Optionally, enter JSON data to send with the API call: "
                read api_data
            else
                endpoint_end="$2"
                api_data="$3"
            fi
            api_data="${api_data#\{}"
            api_data="${api_data%\}}"
            log 6 "Making custom API call to endpoint '$endpoint_end' with data '$api_data'"
            api_call "$endpoint_end" "$api_data"
            echo "$api_response" | jq .
            SILENT=true
            log_exit "Custom API call to endpoint '$endpoint_end' with data '$api_data' successful; API Response: $api_response" 4
            ;;
        *)
            usage "Unknown command: $1"
            ;;
    esac
}

## Source variables from config file of the same basename as script and extension '.cfg' or '.conf'
source_config() {
    SCRIPTNAME=${0##*/}
    SCRIPTPATH=${0%/*}
    if [ $0 = $SCRIPTPATH ]; then
        SCRIPTPATH=''
    else
        SCRIPTPATH="$SCRIPTPATH/"
    fi
    CONFIGFILE="${SCRIPTPATH}${SCRIPTNAME%.*}"
    if [ -f "$CONFIGFILE.cfg" ]; then
        CONFIGFILE="$CONFIGFILE.cfg"
    elif [ -f "$CONFIGFILE.conf" ]; then
        CONFIGFILE="$CONFIGFILE.conf"
    else
        echo "Failed to find config file '$CONFIGFILE.conf'" 1>&2
        exit 1
    fi
    if [ -r $CONFIGFILE ]; then
        trap 'echo "Encountered an error while sourcing config file"; exit 1' ERR
        . $CONFIGFILE
        trap - ERR
    else
        echo "$USER does not have permission to read config file" 1>&2
        exit 1
    fi
}

usage() { ## Args: [error message]
    [ -n "$1" ] && echo "Error: $1" 1>&2
    echo "$usage_message" 1>&2
    exit 1
}

## Makes a call to porkbun API and sets 'api_response' to a string containing the API's JSON response
## Endpoint argument should include everything after 'porkbun.com/api/json/v3/' in the endpoint's URL
## JSON data argument should omit leading and trailing braces
api_call() { ## Args: <endpoint> [json data]
    [ -z "$1" ] && log_exit 'No endpoint specified for API call'
    local endpoint curl_data response curl_exit_code http_status api_status
    endpoint="https://porkbun.com/api/json/v3/$1"
    curl_data="{\"apikey\": \"$APIKEY\", \"secretapikey\": \"$SECRETKEY\""
    if [ -z "$2" ]; then
        curl_data="${curl_data}}"
    else
        curl_data="${curl_data}, $2}"
    fi
    response=$(curl \
    --silent \
    --fail-with-body \
    $IP_VERSION \
    --write-out '\n%{http_code}\n' \
    --header "Content-Type: application/json" \
    --request POST \
    --data "$curl_data" \
    "$endpoint")
    curl_exit_code=$?
    http_status=$(echo "$response" | tail -1)
    api_response=$(echo "$response" | sed '$d')
    api_status=$(jq -r .status 2>/dev/null <<< "$api_response")
    if [ $curl_exit_code -ne 0 ] || [ "$api_status" != 'SUCCESS' ]; then
        local exit_string="API Call failed\nHTTP Status Code: $http_status\nAPI Endpoint: $endpoint"
        if [ -n "$2" ]; then
            exit_string="$exit_string\nData Sent to API: $2"
        fi
        if [ "$api_status"  = 'ERROR' ]; then
            exit_string="$exit_string\nAPI Response: $api_response"
        fi
        log_exit "$exit_string"
    fi
}

## Convert top level json key/value pairs to associative array index/values
json_to_assoc_array() { ## Args: <json string>
    unset json_array
    declare -gA json_array
    while IFS='=' read -r -d $'\t' key value; do
        json_array["$key"]="$value"
    done <<< $(jq -r "to_entries|map(\"\(.key)=\(.value)\")|@tsv" <<< "$1")$'\t'
}

update_dns() {
    log 6 "Updating DNS A record for domain $DOMAIN"
    [ "$IP_VERSION" = '-6' ] && log 3 "IPv4 required to get current IP from ping call, overriding IP_VERSION of '-6' to '-4'"
    IP_VERSION='-4'
    log 7 'Getting current public IPv4 address'
    api_call 'ping'
    currentIP=$(jq -re .yourIp 2>/dev/null <<< "$api_response")
    check_exitcode 'Failed to find current IP in API response'
    log 7 "Current public IPv4 address: $currentIP"
    log 7 "Getting current A record for $DOMAIN"
    api_call "dns/retrieveByNameType/$DOMAIN/A"
    Arecord=$(jq -re ".records[$A_RECORD_NUM] | .content,.id,.ttl" 2>/dev/null <<< "$api_response")
    check_exitcode 'Failed to find current A Record in API response'
    read -d ' ' ArecordIP ArecordID ArecordTTL <<< "$Arecord"
    log 7 "Current A record for domain $DOMAIN: $ArecordIP"
    if [ "$currentIP" = "$ArecordIP" ]; then
        log_exit "A Record IP for $DOMAIN already matches public IP of $currentIP" 5
    else
        log 7 "Updating A record for $DOMAIN to current IPv4 address of $currentIP"
        api_call "dns/edit/$DOMAIN/$ArecordID" "\"content\": \"$currentIP\", \"type\": \"A\", \"ttl\": \"$ArecordTTL\""
        log_exit "A record for $DOMAIN updated to $currentIP successfully" 4
    fi
}

retrieve_ssl() {
    [ -z "$SSL_FOLDER" ] && SSL_FOLDER="/ssl/$DOMAIN" ## Set this default here so it will use domain set by flag or config
    log 6 "Retrieving SSL cert bundle for domain $DOMAIN & outputting to folder $SSL_FOLDER/"
    if [ ! -d "$SSL_FOLDER" ]; then
        log 4 "Creating SSL cert output folder '$SSL_FOLDER'"
        mkdir -p "$SSL_FOLDER"
        check_exitcode "Failed to create SSL cert output folder '$SSL_FOLDER'"
    fi
    api_call "ssl/retrieve/$DOMAIN"
    json_to_assoc_array "$api_response" ## Convert to associative array to iterate on SSL cert formats
    local cert_to_check file_name_var file_name cert_file
    if [ "$CHECK_CURRENT_CERT" = true ]; then
        cert_to_check='certificatechain'
        file_name_var="${cert_to_check}_name"
        file_name="${!file_name_var:-$cert_to_check}"
        cert_file="$SSL_FOLDER/$DOMAIN.$file_name.pem"
        if [ -f "$cert_file" ]; then
            log 7 "Checking if SSL certs are already up to date"
            cmp -s "$cert_file" <<< "${json_array[$cert_to_check]}" || log_exit "SSL certs for domain $DOMAIN already up to date" 5
        fi
    fi
    log 7 'Writing SSL cert PEM files'
    for key in "${!json_array[@]}"; do
        [ "$key" = 'status' ] && continue
        file_name_var="${key}_name"
        file_name="${!file_name_var:-$key}"
        echo -ne "${json_array[$key]}" > "$SSL_FOLDER/$DOMAIN.$file_name.pem"
    done
    log 7 'Writing SSL cert PKCS#12 file'
    openssl pkcs12 -passout pass: -export -out "$SSL_FOLDER/$DOMAIN.p12" -inkey <(echo -ne "${json_array[privatekey]}") -in <(echo -ne "${json_array[certificatechain]}")
    check_exitcode "Failed to convert SSL cert for $DOMAIN to PKCS#12 format"
    log_exit "SSL cert files for domain $DOMAIN written to folder $SSL_FOLDER successfully." 4
}

## Logging functions
log() { ## Args: <severity level> <log message>
    if [ "$VERBOSITY" -lt "$1" ]; then
        return 0
    fi
    local logstring="$(date '+%Y-%d-%m %H:%M:%S') $2"
    if ! [ "$SILENT" = true ] || [ "$1" -eq 0 ]; then
        if [ "$1" -eq 0 ]; then
            echo -e "$2" 1>&2
        else
            echo -e "$2"
        fi
    fi
    if [ -n "$LOGFILE" ]; then
        echo -e "$logstring" >> "$LOGFILE"
    fi
}

log_exit() { ## Args: <log message> [severity level] [exit code]
    if [ -z "$2" ]; then
        severity_level=0
    else
        severity_level="$2"
    fi
    if [ -z "$3" ]; then
        if [ "$severity_level" -eq 0 ]; then
            exit_code=1
        else
            exit_code=0
        fi
    else
        exit_code="$3"
    fi
    log "$severity_level" "$1\n"
    exit "$exit_code"
}

check_exitcode() { ## Args: <log message>
    if [ $? -ne 0 ]; then
        log_exit "$1"
    fi
}

## Check variables are set, variables names should be passed as strings without '$'
vars_set() { ## Args: [var1] [var2] [var3] ...
    local vars=("$@")
    for i in "${vars[@]}"; do
        if [ -z "${!i}" ]; then
            log_exit "Required variable '$i' is unset"
        fi
    done
}

## Check or correct variable formatting
vars_formatting() {
    SSL_FOLDER=${SSL_FOLDER%/}
    [ ${#IP_VERSION} -eq 1 ] && IP_VERSION="-$IP_VERSION"
    [ -n "$DOMAIN" ] && grep -vFq '.' <<< "$DOMAIN" && echo "Invalid value for DOMAIN: '$DOMAIN'" 1>&2 && exit 1
    ! [ "$VERBOSITY" -ge 0 -a "$VERBOSITY" -le 7 ] 2>/dev/null && echo 'VERBOSITY must be set to a value between 0 and 7' 1>&2 && exit 1
    ! [ "$A_RECORD_NUM" -ge 0 -a "$A_RECORD_NUM" -le 10 ] 2>/dev/null && echo 'A_RECORD_NUM must be set to a value between 0 and 10' 1>&2 && exit 1
}

## Run main function if this script wasn't sourced in another script.
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
