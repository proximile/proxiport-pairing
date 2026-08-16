#======================================================================================================================
# vim: softtabstop=4 shiftwidth=4 expandtab fenc=utf-8 spell spelllang=en cc=120
#======================================================================================================================
#
#      FRAGMENT: uninstall.sh
#   DESCRIPTION: Remove the ProxiPort client from this host. Assembled by the
#                pairing service's /uninstall route after init.sh + vars.sh +
#                functions.sh, so uninstall() (defined in functions.sh) is in
#                scope -- served as `curl <pairing-service>/uninstall | sudo sh`.
#          BUGS: https://github.com/proximile/proxiport/issues
#       LICENSE: see LICENSE in the proxiport-pairing repository.
#======================================================================================================================

echo " Uninstall the ProxiPort client"
uninstall
echo " [ FINISH  ] ProxiPort client removed."
echo ""
echo "#"
echo "# Feedback and bug reports: https://github.com/proximile/proxiport/issues"
echo "# "
