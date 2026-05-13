#
# Dynamically inserted variables
#
FINGERPRINT="{{ .Fingerprint}}"
CONNECT_URL="{{ .ConnectUrl}}"
CLIENT_ID="{{ .ClientId}}"
PASSWORD="{{ .Password}}"

#
# Global static installer vars
#
TMP_FOLDER=/tmp/proxiport-install
FORCE=1
USE_ALTERNATIVE_MACHINEID=0
LOG_DIR=/var/log/proxiport
LOG_FILE=${LOG_DIR}/proxiport.log