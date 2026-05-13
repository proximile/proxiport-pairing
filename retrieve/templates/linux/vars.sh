#
# Global Variables for installation and update
#
CONF_DIR=/etc/proxiport
CONFIG_FILE=${CONF_DIR}/proxiport.conf
USER=proxiport
ARCH=$(uname -m | sed s/"armv\(6\|7\)l"/'armv\1'/ | sed s/aarch64/arm64/)