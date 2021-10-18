#!/usr/bin/env bash

prompt_reply() {
    echo "Choose, by number, a Virtual Machine to run..."
    read -r -p "> "

    if [[ -z $REPLY ]]
    then
        echo
        continue
    fi

    if ! [[ $REPLY =~ ^[0-9]+$ ]]
    then
        echo "Error: Value is not a number!"
        sleep 1
        continue
    fi

    if (( ${#vms[@]} <= $REPLY ))
    then
        echo "Error: VM number exceeds the available VMs!"
        sleep 1
        continue
    fi
}

while :
do
    cd "$HOME/.qemu/"

    # Get list of VMs
    shopt -s nullglob
    vms=(*/)
    shopt -u nullglob

    printf "\033c"

    counter=0
    for vm in "${vms[@]}"
    do
        echo "$counter) $vm"
        counter=$((counter+1))
    done
    echo

    prompt_reply

    VM=${vms[$REPLY]}
    cd "$VM"
    REQ="$(pwd)/requirements.sh"
    START="$(pwd)/start.sh"

    if [[ -f "$REQ" ]] && ! "$REQ"
    then
        echo "Error: VM requirements are not satisfied!"
        sleep 2
        continue
    fi

    echo "Starting virtual machine..."
    exec "$START"    

done
