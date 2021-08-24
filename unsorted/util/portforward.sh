echo "
rdr pass inet proto tcp from any to any port 25565 -> 127.0.0.1 port $1
" | sudo pfctl -ef -
