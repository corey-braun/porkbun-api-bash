#!/usr/bin/env bash
## https://github.com/corey-braun/porkbun-api-bash
## Requires jq 1.6 for json response parsing

## Set default variable values
LOGFILE='/tmp/porkbun-api.log'
VERBOSITY=5
SILENT=false
A_RECORD_NUM=0
declare -A json_array

usage_message="\
Usage: $0 [-hsv46] [-d domain] <command> [args]
    -h prints this help message
    -s enables silent mode (no output sent to STDOUT)
    -v sets verbosity to the max value
    -4 forces using IPv4 to make API calls
    -6 forces using IPv6 to make API calls
    -d sets the domain name to take action on
Available commands:
    update-dns: Update the DNS A record for a domain. If multiple A records are present the default is to update the first one.
    retrieve-ssl: Retrieve the porkbun-generated wildcard SSL cert for a domain.
    ping: Make an API call to the ping endpoint. Useful for verifying your credentials and connection.
    custom: Make a custom API call. An API endpoint and JSON data to send can be specified as arguments following the command, or through an interactive dialog if no additional arguments are provided."

## Main function, only executed if script was not sourced in another script.
main() {
    ## Source variables from config file
    SCRIPTPATH=${0%/*}
    if [ $0 = $SCRIPTPATH ]; then SCRIPTPATH=''; else SCRIPTPATH="$SCRIPTPATH/"; fi
    CONFIGFILE="${SCRIPTPATH}porkbun-api.conf"
    if [ -f $CONFIGFILE ]; then
        . $CONFIGFILE
    else
        echo "Failed to find 'porkbun-api.conf' in same directory as script" 1>&2
        exit 1
    fi

    ## Parse flags
    while getopts ":hsv46d:" opt; do
        case $opt in
            h)
                echo -e "$usage_message"; exit 0
                ;;
            s)
                SILENT=true
                ;;
            v)
                VERBOSITY=7
                ;;
            d)
                [ "${OPTARG: -1}" = '-' ] && usage "Missing required argument for '-d'"
                DOMAIN="$OPTARG"
                ;;
            4)
                [ "$IP_VERSION_FLAG" = true ] && usage "Flags '-4' and '-6' are mutually exclusive"
                IP_VERSION_FLAG=true
                IP_VERSION='-4'
                ;;
            6)
                [ "$IP_VERSION_FLAG" = true ] && usage "Flags '-4' and '-6' are mutually exclusive"
                IP_VERSION_FLAG=true
                IP_VERSION='-6'
                ;;
            *)
                echo "Invalid flag: -$OPTARG" 1>&2; usage
                ;;
        esac
    done
    shift $(($OPTIND - 1))

    ## Check required variables are correctly set
    vars_set VERBOSITY APIKEY SECRETKEY
    vars_valid_formatting

    ## Execute specified function
    [ $# -eq 0 ] && usage "No command specified"
    case $1 in
        "update-dns")
            vars_set DOMAIN A_RECORD_NUM
            update_dns
            ;;
        "retrieve-ssl")
            vars_set DOMAIN SSL_FOLDER
            retrieve_ssl
            ;;
        "ping")
            log 6 "Making 'ping' API call"
            api_call 'ping'
            echo "API Response:"
            echo "$api_response" | jq .
            SILENT=true
            log_exit "Ping API call successful; API Response: $api_response" 5
            ;;
        "custom")
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
            [ "${api_data::1}" = '{' ] && api_data="${api_data:1}"
            [ "${api_data: -1}" = '}' ] && api_data="${api_data:: -1}"
            log 6 "Making custom API call with endpoint: '$endpoint_end' and data: '$api_data'"
            api_call "$endpoint_end" "$api_data"
            echo "API Response:"
            echo "$api_response" | jq .
            SILENT=true
            log_exit "Custom API call successful; API Response: $api_response" 4
            ;;
        *)
            usage "Unknown command: $1"
            ;;
    esac
}

usage() { ## (error message)
    [ -z "$1" ] || echo -e "Error: $1" 1>&2
    echo -e "$usage_message" 1>&2
    exit 1
}

## Make a call to porkbun API, first argument is the API endpoint (everything after 'porkbun.com/api/json/v3/'), second is data to send in the "content" section with the API call (optional)
## Sets global variable 'api_response' to a string containing the API's JSON response.
api_call() { ## (endpoint, data)
    [ -z "$1" ] && log_exit 'No endpoint specified for API call'
    local endpoint curl_data response curl_exit_code http_status api_status
    endpoint="https://porkbun.com/api/json/v3/$1"
    curl_data="{\"apikey\":\"$APIKEY\",\"secretapikey\":\"$SECRETKEY\""
    if [ -z "$2" ]; then
        curl_data="${curl_data}}"
    else
        curl_data="${curl_data},$2}"
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
        if [ ! -z "$2" ]; then
            exit_string="$exit_string\nData Sent to API: $2"
        fi
        if [ "$api_status"  = 'ERROR' ]; then
            exit_string="$exit_string\nAPI Response: $api_response"
        fi
        log_exit "$exit_string"
    fi
}

## Convert top level json key/value pairs to associative array index/values
json_to_assoc_array() { ## (json_string)
    while IFS="=" read -r -d $'\t' key value || [ -n "$value" ]; do
        json_array["$key"]="$value"
    done <<< "$(jq -r "to_entries|map(\"\(.key)=\(.value)\")|@tsv" <<< "$1")$(echo -e '\t')"
}

update_dns() {
    log 6 "Updating DNS A record for domain $DOMAIN"
    [ "$IP_VERSION" = '-6' ] && log 3 "Overriding IP_VERSION setting of '-6'"
    IP_VERSION='-4'
    log 7 'Getting current public IPv4 address'
    api_call 'ping'
    currentIP=$(jq -re .yourIp 2>/dev/null <<< "$api_response")
    check_exitcode 'Failed to find current IP in API response'
    log 7 "Current public IPv4 address: $currentIP"
    log 7 "Getting current A record for $DOMAIN"
    api_call "dns/retrieveByNameType/$DOMAIN/A"
    Arecord=$(jq -re ".records[$A_RECORD_NUM] | .content,.id" 2>/dev/null <<< "$api_response")
    check_exitcode 'Failed to find current A Record in API response'
    read ArecordIP ArecordID < <(echo $Arecord)
    log 7 "Current A record for domain $DOMAIN: $ArecordIP"
    if [ "$currentIP" = "$ArecordIP" ]; then
        log_exit "A Record IP for $DOMAIN already matches public IP of $currentIP" 5
    else
        log 7 "Updating A record for $DOMAIN to current IPv4 address of $currentIP"
        api_call "dns/edit/$DOMAIN/$ArecordID" "\"content\": \"$currentIP\",\"type\": \"A\""
        log_exit "A record for $DOMAIN updated to $currentIP successfully" 4
    fi
}

retrieve_ssl() {
    log 6 "Retrieving SSL cert bundle for domain $DOMAIN & outputting to folder $SSL_FOLDER/"
    if [ ! -d "$SSL_FOLDER" ]; then
        log 6 "Creating SSL cert output folder '$SSL_FOLDER'"
        mkdir -p "$SSL_FOLDER"
        check_exitcode "Failed to create SSL cert output folder '$SSL_FOLDER'"
    fi
    api_call "ssl/retrieve/$DOMAIN"
    json_to_assoc_array "$api_response" ## Convert to associative array to iterate on SSL cert formats
    log 7 'Writing SSL cert PEM files'
    for key in "${!json_array[@]}"; do
        [ "$key" = 'status' ] && continue
        echo -ne "${json_array[$key]}" > "$SSL_FOLDER/$DOMAIN.$key.pem"
    done
    log 7 'Writing SSL cert PKCS#12 file'
    openssl pkcs12 -passout pass: -export -out "$SSL_FOLDER/$DOMAIN.p12" -inkey <(echo -ne "${json_array[privatekey]}") -in <(echo -ne "${json_array[certificatechain]}")
    check_exitcode "Failed to convert SSL cert for $DOMAIN to PKCS#12 format"
    log_exit "SSL cert files for domain $DOMAIN written to folder $SSL_FOLDER successfully." 4
}

## Logging functions
log() { ## (priority level, log message)
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

log_exit() { ## (log message, severity level, exit code)
    if [ -z $2 ]; then
        severity_level=0
    else
        severity_level="$2"
    fi
    if [ -z $3 ]; then
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

check_exitcode() { ## (log message)
    if [ $? -ne 0 ]; then
        log_exit "$1"
    fi
}

## Check variables are set
vars_set() { ## (var1, var2, ...)
    local vars=("$@")
    for i in "${vars[@]}"; do
        if [ -z "${!i}" ]; then
            log_exit "Required variable '$i' is unset"
        fi
    done
}

## Ensure variables are set to values with valid formatting
vars_valid_formatting() {
    [ "${SSL_FOLDER: -1}" = / ] && SSL_FOLDER=${SSL_FOLDER::-1}
    ! [ -z "$IP_VERSION" ] && [ -z "${IP_VERSION:: -1}" ] && IP_VERSION="-$IP_VERSION"
    if [ "$VERBOSITY" -ge 0 ] 2>/dev/null && [ "$VERBOSITY" -le 7 ] 2>/dev/null; then :; else echo 'VERBOSITY must be set to a value between 0 and 7' 1>&2; exit 1; fi
    if grep -vFq '.' <<< "$DOMAIN"; then echo "Invalid value for DOMAIN: '$DOMAIN'" 1>&2; exit 1; fi
    if [ "$A_RECORD_NUM" -ge 0 ] 2>/dev/null && [ "$A_RECORD_NUM" -le 10 ] 2>/dev/null; then :; else echo 'A_RECORD_NUM must be set to a value between 0 and 10' 1>&2; exit 1; fi
}

## Run main function if this script wasn't sourced in another script.
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
