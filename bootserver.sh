#!/bin/echo 

# this collecion of scripts will set up a boot server
# as a ubuntu container 

# before running this, edit bs-config.sh for your environement

set -xe 
bash bs-create-static-container.sh
bash bs-tftp.sh
bash bs-pxelinux.sh
bash bs-dhcp.sh

