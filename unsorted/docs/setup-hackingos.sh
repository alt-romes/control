sudo sed -i 's/archive/old-releases/g' /etc/apt/sources.list
sudo sed -i 's/security/old-releases/g' /etc/apt/sources.list
sudo apt-get update
sudo apt-get install openssh-server
passwd # and change password to reader
