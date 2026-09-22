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
# LOG_DIR and LOG_FILE are NOT here: they follow the agent's account, so they
# live in vars.sh next to USER and DATA_DIR. Keeping them here also left them
# undefined in the update and uninstall scripts, which do not include this
# file.
TMP_FOLDER=/tmp/proxiport-install
FORCE=1
USE_ALTERNATIVE_MACHINEID=0