#!/bin/bash

mainColor='\033[34m'
boldColor='\033[01m'
resetColor='\033[0m'

function int_handler() {
    echo
    echo "Goodbye!"
    # show cursor again
    tput cnorm
    exit
}

# trap interrupt (ctrl_c)
trap int_handler INT

# hide cursor
tput civis

while :
do

    clear

    # echo 
    # echo -ne "$mainColor$boldColor romes@romesmacbook.local $resetColor"
    # echo

    echo

    echo -ne "$mainColor$boldColor Deutsch: $resetColor"
    sentences -o -t deutsch
    echo

    echo -ne "$mainColor$boldColor Русский: $resetColor"
    sentences -o -t russian
    echo 
    
    echo -ne "$mainColor$boldColor 日本語: $resetColor"
    sentences -o -t japanese
    echo

    echo
    echo

    echo -ne "$mainColor$boldColor IPv4: $resetColor"
    ifconfig en0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'
    echo

    echo -ne "$mainColor$boldColor iTunes: $resetColor"
    if [ $(itunes status | grep -c "") -eq 1 ]; then echo "Currently paused"; else itunes status | sed 1d; fi
    echo

    echo
    echo

    echo -ne "$mainColor$boldColor Kanji: $resetColor"
    echo "$(sed -n $((RANDOM%241))p $HOME/control/extra/kanji.txt | tr " " "\n" | head -n 3 | sed 1d | tr "\n" " ")"
    echo

    echo -ne "$mainColor$boldColor Kanji: $resetColor"
    echo "$(sed -n $((RANDOM%241))p $HOME/control/extra/kanji.txt | tr " " "\n" | head -n 3 | sed 1d | tr "\n" " ")"

    sleep 600 # Sleep 10min

done
