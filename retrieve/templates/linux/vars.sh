#
# Global Variables for installation, update and uninstall
#
CONF_DIR=/etc/proxiport
CONFIG_FILE=${CONF_DIR}/proxiport.conf

# The account the agent runs as, and the directories that belong to it.
#
# Deliberately NOT `proxiport`: that is the ProxiPort SERVER's account. The
# agent runs operator-supplied commands as its own uid, so sharing one account
# puts the agent inside the server's trust boundary on any host that carries
# both -- that uid could read /etc/proxiport/proxiportd.conf, which holds
# jwt_secret and key_seed, and read and write every database, the vault and the
# ACME key cache under /var/lib/proxiport.
#
# resolve_account() in functions.sh may replace these before anything uses
# them: an existing agent install keeps whatever account it already has, and
# `-a <user>` still wins over both.
USER=proxiport-agent
DATA_DIR=/var/lib/${USER}
LOG_DIR=/var/log/${USER}
LOG_FILE=${LOG_DIR}/proxiport.log

ARCH=$(uname -m | sed s/"armv\(6\|7\)l"/'armv\1'/ | sed s/aarch64/arm64/)
