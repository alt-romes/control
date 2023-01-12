apt update
apt install git -y
apt install iptables -y
apt install screen -y
apt install openjdk-17-jre -y

iptables -I INPUT -p tcp -m tcp --dport 25565 -j ACCEPT
iptables-save

curl -LO https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar
git config --global --unset core.autocrlf
export _JAVA_OPTIONS="-Djavax.net.ssl.trustStorePassword=changeit"
java -jar BuildTools.jar --rev latest

# what are the best params?
java -Xms1G -Xmx2G -XX:+UseG1GC -jar spigot.jar nogui

echo "eula=true" > eula.txt

screen

java -Xms1G -Xmx2G -XX:+UseG1GC -jar spigot.jar nogui

# exit screen using Ctrl+A+D
