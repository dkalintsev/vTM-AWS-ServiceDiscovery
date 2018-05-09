#!/bin/bash
#
# This is a sample plugin for Pulse Virtual Traffic Manager (vTM) Flexible
# Service Discovery.
#
# This script is designed to query AWS API to find EC2 instances matching an
# AWC CLI filter expression, along with the specified TCP/UDP port number.
#
# = Input parameters =
# This script accepts the following input parameters:
#
# - `-f "<AWS CLI EC2 filter list>"` : a filer list conforming to AWS CLI EC2
# +        `describe-instances` [--filters] syntax
# - `-n <number>` : port number to return alongside the discovered IP addresses
# - `[-i <number>]` : optional Network Interface Device Index, `0` by default
# - `[-p]` : optional parameter telling plugin to return `Public` IP addresses
# +        of matching instances instead of default `Private`
# - `[-g]` : optional parameter telling Plugin to download and install its
# +        dependencies, `jq` and `aws`
#
# = Outputs =
# The script will return its output in accordance with Pulse vTM flexible Service
# Discovery mechanism spec. See https://www.pulsesecure.net/download/techpubs/current/1261/Pulse-vADC-Solutions/Pulse-Virtual-Traffic-Manager/18.1/ps-vtm-18.1-userguide.pdf for more details.
#
# Misc info
#
# logMsg uses "nnn: <message>" format, where "nnn" is sequential. If you end up
# adding or removing logMsg calls in this script, run the following command to re-apply
# the sequence (replace "_" with space after logMsg):
#
# perl -i -000pe 's/(logMsg_")(...)/$1 . sprintf("%03d", ++$n)/ge' K8s-get-nodeport-ips.sh
#

# Parameters and defaults
filterString=""         # AWS CLI filter to match
deviceIndex="0"         # Device Index to look at, default = 0
returnPublicIP="No"     # By default, return primary Private IP
getDeps="No"            # Whether to try downloading jq + kubectl

if [[ ! ${ZEUSHOME} && ${ZEUSHOME-_} ]]; then
    # $ZEUSHOME is unset! Let's make an unsafe assumption we're *not* on a VA. :)
    # export ZEUSHOME="/opt/zeus"       # VA default
    export ZEUSHOME="/usr/local/zeus"   # Docker image default
fi

workDir="${ZEUSHOME}/zxtm/internal/servicediscovery"
extrasDir="${ZEUSHOME}/zxtm/conf/extra"

# We'll upload jq and kubectl into Extras; this is the directory where they
# will end up. Let's add it to $PATH
#
export PATH=$PATH:${extrasDir}

# Variables involved in generating the output
outVersion="1"  # version
outCode="0"     # code
outError=""     # error
outIPs=( )      # array of IPs for nodes
outPort=""      # TCP/UDP port number to return with discovered IPs

missingTools=""                 # List of missing prerequisites
lockFile=""                     # File name of our lock file
lockDir="/tmp"                  # Where to create a lock file
scriptName=$(basename $0)       # Used for logging and lock file naming
tmpDir="/tmp"                   # Where to keep our temp files
outFile="${tmpDir}/outfile.$$"  # To keep command outputs in
errFile="${tmpDir}/errfile.$$"  # To keep command errors in

# Not strictly necessary, but.. :)
if [[ -d "${workDir}" ]]; then
    cd "${workDir}"
fi

logFile="/var/log/${scriptName}.log"
#logFile="./${scriptName}.log"

# Called on any "exit"
cleanup  () {
    if [[ "${lockFile}" != "" ]]; then
        rm -f "${lockFile}"
    fi
    rm -f "${outFile}" "${errFile}"
}

trap cleanup EXIT

# Parse flags
while getopts "f:n:i:pg" opt; do
    case "$opt" in
        f)  filterString="Name=instance-state-name,Values=running ${OPTARG}"
            ;;
        n)  outPort=${OPTARG}
            ;;
        i)  deviceIndex=${OPTARG}
            ;;
        p)  returnPublicIP="Yes"
            ;;
        g)  getDeps="Yes"
            ;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

# Logging sub
logMsg () {
    ts=$(date -u +%FT%TZ)
    echo "$ts ${scriptName}[$$]: $*" >> $logFile
}

# Generate the response in JSON
# Yah, this is kinda ugly. :)
#
printOut() {
    myJSON="{}"

    # Base parameters - version and code
    #
    myJSON=$(jq \
        --arg key0 'version' \
        --arg value0 ${outVersion} \
        --arg key1 'code' \
        --arg value1 "${outCode}" \
        '. | .[$key0]=($value0|tonumber) | .[$key1]=($value1|tonumber)' \
        <<<"${myJSON}" \
    )

    # Add Error Message, if we have it.
    #
    if [[ "${outError}" != "" ]]; then
        myJSON=$(jq \
            --arg key0 'error' \
            --arg value0 "${outError}" \
            '. | .[$key0]=$value0' \
            <<<${myJSON} \
        )
    fi

    # Add nodes, if we have them
    #
    jqArgs=( )
    jqQuery=""
    # Only return nodes if outCode is set to success = 200
    if [[ ${#outIPs[*]} != "0" && "${outCode}" == "200" ]]; then
        for idx in "${!outIPs[@]}"; do
            jqArgs+=( --arg "value_a$idx" "${outIPs[$idx]}" )
            jqArgs+=( --arg "value_b$idx" "${outPort}" )
            jqQuery+=" ( .ip=\$value_a${idx}"
            jqQuery+=" | .port=(\$value_b${idx}|tonumber) ) "
            if (( $idx != ${#outIPs[*]}-1 )); then
                jqQuery+=","
            fi
        done
        myJSON=$(jq \
            "${jqArgs[@]}" \
            ". + ( {} | .nodes=[ $jqQuery ] )" \
            <<<"${myJSON}" \
        )
    fi
    echo ${myJSON}
}

# Check prerequisites
#
checkPrerequisites () {
    # Check for curl
    #
    which curl > /dev/null
    if [[ $? != 0 ]]; then
        missingTools+=" curl"
    fi
    # We need curl to download jq/AWS CLI
    #
    if [[ "${missingTools}" != "" && "${getDeps}" = "Yes" ]]; then
        apt-get update > /dev/null 2>&1 \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl > /dev/null 2>&1 \
        && apt-get autoremove --purge > /dev/null 2>&1
        if [[ $? != 0 ]]; then
            echo "{\"version\":1, \"code\":400, \"error\":\"Failed installing curl; please install by hand before retrying.\"}"
            exit 1
        else
            missingTools=""
        fi
    fi

    # Check for jq
    #
    jqExtra="${extrasDir}/jq"

    # If we've uploaded jq via extra and it hasn't +x on
    if [[ -s "${jqExtra}" && ! -x "${jqExtra}" ]]; then
        chmod +x "${jqExtra}"
    fi

    # Is it in $PATH somewhere, including $extrasDir?
    which jq > /dev/null
    if [[ $? != 0 ]]; then
        # Nope, can't find it.
        #
        # Did we ask to download via parameter?
        if [[ "${getDeps}" = "Yes" ]]; then
            cd /tmp
            curl -s -LO https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
            if [[ -s jq-linux64 ]]; then
                cat jq-linux64 > "${jqExtra}" && chmod +x "${jqExtra}"
            fi
            rm -f jq-linux64
            cd - > /dev/null 2>&1
        fi
        # Retest - do we now have it?
        which jq > /dev/null
        if [[ $? != 0 ]]; then
            # Nope, something went wrong.
            missingTools+=" jq"
        fi
    fi

    # Check for AWS CLI
    #
    which aws > /dev/null
    if [[ $? != 0 ]]; then
        # Can't find AWS CLI
        #
        # Did we ask to download via parameter?
        if [[ "${getDeps}" = "Yes" ]]; then
            cd /tmp
            curl -s -LO https://s3.amazonaws.com/aws-cli/awscli-bundle.zip
            unzip awscli-bundle.zip > /dev/null 2>&1
            ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws > /dev/null 2>&1
            rm -rf awscli*
            cd - > /dev/null 2>&1
        fi
        # Retest - do we now have it?
        which aws > /dev/null
        if [[ $? != 0 ]]; then
            # Nope, something went wrong.
            missingTools+=" aws"
        fi
    fi

    # Anything missing? Error out ("by hand"), and exit.
    #
    if [[ "${missingTools}" != "" ]]; then
        echo "{\"version\":1, \"code\":400, \"error\":\"Prerequisite tool(s) missing:${missingTools}\"}"
        exit 1
    fi
}

# Check if another copy of this script is already running
#
checkLock() {
    # Compose lock file name. First, base string, so we can check
    # if other instance of this script is already running.
    # We compose instance ID from an MD5 hash of sum of all parameters
    #
    instanceHash=$(echo "${filterString} ${outPort} ${deviceIndex} ${returnPublicIP}" | md5sum | awk '{print $1}')
    lockFile="${lockDir}/${scriptName}-${instanceHash}"
    #
    # Check for a ${lockFile} that's similar to ours - same ${instanceHash}
    # but a different PID at the end
    #
    oldLockF=( $(ls -1 ${lockFile}-* 2>/dev/null) )
    if [[ ${#oldLockF[*]} != "0" ]]; then
        # Found one or more of matching files; bailing.
        outError="Another copy of this script is running: ${oldLockF[@]}"
        outCode="400"
        printOut
        exit 0
    else
        # All clear; create a lock file for ourselves
        lockFile+="-$$"
        touch "${lockFile}"
    fi
}

# Talk to the AWS API using aws CLI command to get the list of IPs we're after
#
getNodes() {
    region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')

    aws ec2 describe-instances --region ${region} \
        --filters ${filterString} --output json \
        > ${outFile} 2>${errFile}

    awsError="$?"

    if [[ "${awsError}" != "0" ]]; then
        outCode="500"
        outError="Failed find instances matching filter: '${filterString}'"
        logMsg "001: aws ec2 describe-instances failed: (${awsError}); $(head -1 ${errFile})"
        printOut
        exit 1
    fi

    instanceIDs=( $(cat ${outFile} | jq -r '.Reservations[].Instances[].InstanceId') )

    if [[ "${returnPublicIP}" == "No" ]]; then
        outIPs=( $(cat "${outFile}" \
                | jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
                    select(.Attachment.DeviceIndex == ${deviceIndex}) | \
                    .PrivateIpAddress") )
    else
        outIPs=( $(cat "${outFile}" \
                | jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
                    select(.Attachment.DeviceIndex == ${deviceIndex}) | \
                    .Association.PublicIp") )
    fi

    # Set the final error code
    if [[ ${#outIPs[@]} != 0 ]]; then
        outCode="200"   # We have the nodes!
    else
        outCode="204"   # No content :)
        outError="Could not find any matching IPs."
    fi
}

checkPrerequisites

# Check if we were given the mandatory parameters
#
if [[ "${filterString}" == "" ]]; then
    outError="Filter String must be specified with '-f \"<AWS CLI EC2 filter list>\"'"
    outCode="400"
    printOut
    exit 1
fi
#
if [[ "${outPort}" == "" ]]; then
    outError="Port must be specified with '-n <number>'"
    outCode="400"
    printOut
    exit 1
fi

checkLock
getNodes
printOut