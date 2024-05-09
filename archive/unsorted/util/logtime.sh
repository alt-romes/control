#!/usr/bin/env python3

# Log Time:
#   logtime.sh work 1h30m
# This will add an entry to the file in $logfilename of type "work: 1h30m" under the header for the day
# 
# Usage suggestion:
#   Dependencies: termdown @ https://github.com/trehn/termdown
#   Bash Function:
#       worktimer(){
#           if [ "$1" == "" ]; then
#               echo "Usage: worktimer time"
#               return
#           fi
#           termdown -s -f tinker-toy -T work $1 && logtime.sh work $1
#       }
#   Calling `worktimer 1h30m` will display a terminal countdown for 1h30m and when done will add a work entry to the logfile


import sys

if len(sys.argv) == 2 and sys.argv[1] == "-p":
    import os
    os.system("cat /Users/romes/control/docs/time.log");
    exit()

if len(sys.argv) < 3:
    print("Usage:\n\tlogtime.sh [-p] \"log prefix\" \"time elapsed\"")
    print("\n\t-p displays the log file instead of logging a new entry")
    exit()

from datetime import datetime

# Change log file here
logfilename = "/Users/romes/control/docs/time.log"

today = datetime.today().strftime("%B %d, %Y")

logHasToday = False

with open(logfilename, "r") as f:

    for line in f.readlines():

        # TODO: Start reading from the bottom up

        if line.startswith("---") and line.find(today) > 0:

            logHasToday = True
            break

with open(logfilename, "a") as f:

    if not logHasToday:
        f.write("--- " + today + " ---\n")

    f.write(sys.argv[1] + ": " + sys.argv[2] + "\n")
