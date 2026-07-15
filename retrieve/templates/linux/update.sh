set -e
#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  download_new_version
#   DESCRIPTION:  Download the client tarball for $TAG/$TARGET_VERSION
#                 (resolved in update()) and unpack the binary to a
#                 temp folder. Prints the path of the new binary.
#----------------------------------------------------------------------------------------------------------------------
download_new_version() {
    TEMP=$(mktemp -d)
    ASSET="proxiport_${TARGET_VERSION}_linux_$(goreleaser_arch).tar.gz"
    URL="https://github.com/proximile/proxiport/releases/download/${TAG}/${ASSET}"
    curl -fLs "${URL}" -o "${TEMP}/proxiport.tar.gz"

    # Verify the download against the release's published SHA-256 before using it.
    curl -fLs "https://github.com/proximile/proxiport/releases/download/${TAG}/checksums.txt" -o "${TEMP}/checksums.txt" \
      || { echo "could not fetch checksums.txt; refusing to update" >&2; exit 1; }
    EXPECTED=$(grep " ${ASSET}\$" "${TEMP}/checksums.txt" | awk '{print $1}')
    ACTUAL=$(sha256sum "${TEMP}/proxiport.tar.gz" | awk '{print $1}')
    if [ -z "${EXPECTED}" ] || [ "${EXPECTED}" != "${ACTUAL}" ]; then
        echo "checksum mismatch for ${ASSET} (expected '${EXPECTED}', got '${ACTUAL}'); refusing to update" >&2
        exit 1
    fi

    tar xzf "$TEMP/proxiport.tar.gz" -C "$TEMP" proxiport
    rm -f "$TEMP/proxiport.tar.gz"
    echo "$TEMP/proxiport"
}

# Is the installed proxiport client managed by dpkg / rpm?
# Pairing-script installs use the GitHub tarball (binary in
# /usr/local/bin), but installs from the .deb/.rpm packages must be
# updated through the package manager or the binaries diverge.
is_pkg_managed_deb() {
  is_available dpkg && dpkg -s proxiport >/dev/null 2>&1
}

is_pkg_managed_rpm() {
  is_available rpm && rpm -q proxiport >/dev/null 2>&1
}

current_version() {
    if [ -e /usr/bin/proxiport ]; then
        /usr/bin/proxiport --version | awk '{print $2}'
        return 0
    fi
    if [ -e /usr/local/bin/proxiport ]; then
        /usr/local/bin/proxiport --version | awk '{print $2}'
        return 0
    fi
    echo "Failed to get current proxiport version"
    exit 1
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  restart_proxiport()
#   DESCRIPTION:  The restart of ProxiPort must be detached from this process in case the update
#                 is triggered remotely using proxiport. The proxiport client would kill the script otherwise here.
#    PARAMETERS:  none
#       RETURNS:
#----------------------------------------------------------------------------------------------------------------------
restart_proxiport() {
    if [ -e /etc/init.d/proxiport ]; then
        RESTART_CMD='/etc/init.d/proxiport restart'
    else
        RESTART_CMD='systemctl restart proxiport'
    fi
    if [ "$1" = "background" ]; then
        if command -v at >/dev/null 2>&1; then
            echo "$RESTART_CMD" | at now +1 minute
            throw_info "Restart of proxiport scheduled via atd."
        else
            nohup sh -c "sleep 10;$RESTART_CMD" >/dev/null 2>&1 &
            throw_info "Restart of proxiport scheduled via nohup+sleep."
        fi
        return 0
    fi
    throw_info "Restarting proxiport using '$RESTART_CMD'"
    $RESTART_CMD
}
#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  update
#   DESCRIPTION:  update to the latest version or exit if not update available
#----------------------------------------------------------------------------------------------------------------------
update() {
  CURRENT_VERSION=$(current_version)
  check_prerequisites
  cd /tmp

  if [ -n "$PKG_URL" ]; then
      # Update from a user-supplied package URL (-z). No version check.
      abort_on_proxiport_subprocess
      RESTART_IN="foreground"
      case "$PKG_URL" in
        *.deb)
          throw_info "Updating DEB from custom URL. Checking current version skipped."
          install_from_deb_download
          ;;
        *.rpm)
          throw_info "Updating RPM from custom URL. Checking current version skipped."
          install_from_rpm_download
          ;;
        *)
          throw_fatal "Custom package URLs (-z) must point to a .deb or .rpm file."
          ;;
      esac
      TARGET_VERSION=$(current_version)
  else
      # ProxiPort does not publish apt/yum repositories. All updates
      # come from GitHub release assets, matching the install script.
      TAG=$(latest_release_tag)
      TARGET_VERSION=${TAG#v}
      if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
          throw_info "Nothing to do. ProxiPort is on the latest version ${CURRENT_VERSION}."
          exit 0
      fi
      if is_pkg_managed_deb; then
          abort_on_proxiport_subprocess
          RESTART_IN="foreground"
          PKG_URL="https://github.com/proximile/proxiport/releases/download/${TAG}/proxiport_${TARGET_VERSION}_linux_$(goreleaser_arch).deb"
          throw_info "Updating from ${CURRENT_VERSION} to ${TARGET_VERSION} via DEB package."
          install_from_deb_download
      elif is_pkg_managed_rpm; then
          abort_on_proxiport_subprocess
          RESTART_IN="foreground"
          PKG_URL="https://github.com/proximile/proxiport/releases/download/${TAG}/proxiport_${TARGET_VERSION}_linux_$(goreleaser_arch).rpm"
          throw_info "Updating from ${CURRENT_VERSION} to ${TARGET_VERSION} via RPM package."
          install_from_rpm_download
      else
          # Install from tar.gz (how the pairing installer installs)
          NEW_VERSION=$(download_new_version)
          throw_info "Updating from ${CURRENT_VERSION} to ${TARGET_VERSION}"
          mv "$NEW_VERSION" /usr/local/bin/proxiport
          rm -rf "$(dirname "$NEW_VERSION")"
          RESTART_IN="background"
      fi
  fi
  check_scripts
  check_sudo
  create_sudoers_updates
  detect_interpreters
  enable_monitoring
  enable_lan_monitoring
  enable_file_reception
  insert_watchdog

  throw_info "You are now running $(proxiport --version)"

  restart_proxiport $RESTART_IN
  if wait_for_proxiport; then
      finish
      return 0
  fi
  fail
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  ask_yes_no
#   DESCRIPTION:  Ask a question and wait for a confirmation
#    PARAMETERS:  Question to be asked
#----------------------------------------------------------------------------------------------------------------------
ask_yes_no() {
  if [ -z "$1" ]; then
    printf "Do you want to proceed?"
  else
    printf "%s" "$1"
  fi
  echo " (y/n)"
  while read -r INPUT; do
    if echo "$INPUT" | grep -q "^[Yy]"; then
      return 0
    elif echo "$INPUT" | grep -q "^[Nn]"; then
      return 1
    fi
    echo "Type (y/n) or abort with Ctrl-C"
  done
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  insert_scripts
#   DESCRIPTION:  Insert the missing remote scripts block
#----------------------------------------------------------------------------------------------------------------------
insert_scripts() {
  echo "[remote-scripts]
  enabled = ${ENABLE_SCRIPTS}
" >>"$CONFIG_FILE"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  check_scripts
#   DESCRIPTION:  check if scripts can be activated
#----------------------------------------------------------------------------------------------------------------------
check_scripts() {
  if grep -q remote-scripts "$CONFIG_FILE"; then
    return 0
  fi

  if [ "$ENABLE_SCRIPTS" = 'true' ]; then
    if grep -q "\[remote-scripts\]" "$CONFIG_FILE"; then
        insert_scripts
        return 0
      fi

  fi
  if is_terminal; then
    true
  else
    echo 1>&2 "Please use the switches -x/-d to enable or disable script execution."
    help
    # shellcheck disable=SC2317  # Don't warn about unreachable commands in this function
    exit 1
  fi
  if ask_yes_no "Do you want to activate script execution?"; then
    ENABLE_SCRIPTS=true
    insert_scripts
  fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  check_sudo
#   DESCRIPTION:  check if user wants to enable sudo
#----------------------------------------------------------------------------------------------------------------------
check_sudo() {
  if [ -e /etc/sudoers.d/proxiport-all-cmd ]; then
    return 0
  fi
  if [ "$ENABLE_SUDO" -eq 1 ]; then
    create_sudoers_all
    return 0
  fi
  if is_terminal; then
    true
  else
    echo 1>&2 "Please use the switches -s/-n to enable or disable sudo rights."
    help
    # shellcheck disable=SC2317  # Don't warn about unreachable commands in this function
    exit 1
  fi
  if ask_yes_no "Do you want to activate sudo rights for ProxiPort remote script execution?"; then
    create_sudoers_all
  fi
}

clean_up() {
  true
}

enable_monitoring() {
  if [ "$(version_to_int "$TARGET_VERSION")" -lt 5000 ]; then
    # Version does not handle monitoring yet.
    return 0
  fi
  if grep -q "\[monitoring\]" "$CONFIG_FILE"; then
    echo "Monitoring already enabled."
    return 0
  fi
  cat <<EOF >>"$CONFIG_FILE"
[monitoring]
  ## The proxiport client can collect and report performance data of the operating system.
  ## https://docs.proxiport.net/docs/no17-monitoring.html
  ## Monitoring is enabled by default
  enabled = true
  ## How often (seconds) monitoring data should be collected.
  ## A value below 60 seconds will be overwritten by the hard-coded default of 60 seconds.
  # interval = 60
  ## ProxiPort monitors the fill level of almost all volumes or mount points.
  ## Change the below defaults to include or exclude volumes or mount points from the monitoring.
  #fs_type_include = ['ext3','ext4','xfs','jfs','ntfs','btrfs','hfs','apfs','exfat','smbfs','nfs']
  ## List of excluded mount points or device letters
  #fs_path_exclude = []
  ## Example:
  # fs_path_exclude = ['/mnt/*','h:']
  ## Having fs_path_exclude_recurse = false the specified path
  ## must match a mountpoint or it will be ignored
  ## Having fs_path_exclude_recurse = true the specified path
  ## can be any folder and all mountpoints underneath will be excluded
  #fs_path_exclude_recurse = false
  ## To avoid monitoring of so-called mount binds,
  ## mount points are identified by the path and device name.
  ## Mountpoints pointing to the same device are ignored.
  ## What appears first in /proc/self/mountinfo is considered as the original.
  ## Applies only to Linux
  #fs_identify_mountpoints_by_device = true
  ## ProxiPort monitors all running processes
  ## Process monitoring is enabled by default
  pm_enabled = true
  ## Monitor kernel tasks identified by process group 0
  #pm_enable_kerneltask_monitoring = true
  ## The process list is sorted by PID descending. Only the top N processes are monitored.
  #pm_max_number_monitored_processes = 500
  ## Monitor the bandwidth usage of the following maximum two network cards:
  ## 'net_lan' and 'net_wan'.
  ## You must specify the device name and the maximum speed in Megabits.
  ## On Windows use 'Get-Netadapter' to discover adapter names.
  ## Examples:
  ## net_lan = [ 'eth0' , 1000 ]
  ## net_wan = ['Ethernet0', 1000]
  #net_lan = ['', 1000]
  #net_wan = ['', 1000]
EOF
  echo "Monitoring enabled."
}

insert_watchdog() {
  if [ "$(version_to_int "$TARGET_VERSION")" -lt 8007 ]; then
    # Version does not handle watchdog integration yet.
    echo "Version $TARGET_VERSION does not support watchdog_integration yet"
    return 0
  fi
  if grep -q watchdog_integration "$CONFIG_FILE"; then
    # Watchdog integration already present
    return 0
  else
    WATCHDOG_SNIPPET=$(sed ':a $!{N; ba}; s/\n/\\n/g'<<EOF
  ## Write a state file to {data_dir}/state.json that can be evaluated by external watchdog implementations.
  ## On Linux this also enables the systemd watchdog integration using the systemd notify socket.
  ## Requires max_retry_count = -1 and keep_alive > 0
  ## Read more https://docs.proxiport.net/advanced/watchdog-integration/
  ## Disabled by default.
  #watchdog_integration = false
EOF
)
    sed -i "/max_retry_interval/a\\\n${WATCHDOG_SNIPPET}" "$CONFIG_FILE"
  fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  finish
#   DESCRIPTION:  print some information
#----------------------------------------------------------------------------------------------------------------------
finish() {
  echo "
#
#  Update of ProxiPort finished.
#
#  Logs are written to /var/log/proxiport/proxiport.log.
#
#  READ THE DOCS ON https://docs.proxiport.net/
#
# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#  Give us a star on https://github.com/proximile/proxiport
# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#

Thanks for using
   ____                   _____  _____           _
  / __ \                 |  __ \|  __ \         | |
 | |  | |_ __   ___ _ __ | |__) | |__) |__  _ __| |_
 | |  | | '_ \ / _ \ '_ \|  _  /|  ___/ _ \| '__| __|
 | |__| | |_) |  __/ | | | | \ \| |  | (_) | |  | |_
  \____/| .__/ \___|_| |_|_|  \_\_|   \___/|_|   \__|
        | |
        |_|
"
}

fail() {
  systemctl --no-pager status proxiport
  echo "
#
# -------------!!   ERROR  !!-------------
#
# Update of ProxiPort finished with errors.
#

Try the following to investigate:
1) systemctl status proxiport

2) tail /var/log/proxiport/proxiport.log

3) Ask for help on https://github.com/proximile/proxiport/issues
"
  if runs_with_selinux; then
    echo "
4) Check your SELinux settings and create a policy for proxiport."
  fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  help
#   DESCRIPTION:  print a help message and exit
#----------------------------------------------------------------------------------------------------------------------
help() {
  cat <<EOF
Usage $0 [OPTION(s)]

Update the current version of ProxiPort to the latest version.

Options:
-h  print this help message
-c  update the proxiport client, default action
-u  uninstall the proxiport client and all configurations and logs
-x  enable script execution in proxiport.conf
-d  disable script execution in proxiport.conf
-s  create sudo rules to grant full root access to the proxiport user
-z  Download the proxiport client deb|rpm from the given URL instead of using GitHub releases.
    See environment variables.
EOF
  exit 0
}

#
# Read the command line options and map to a function call
#
ACTION=update
ENABLE_SUDO=2
ENABLE_SCRIPTS=undef
ENABLE_FILEREC=0
ENABLE_FILEREC_SUDO=0
while getopts "hcuxdsrbz:" opt; do
  case "${opt}" in

  h) ACTION=help ;;
  c) ACTION=update ;;
  u) ACTION=uninstall ;;
  x) ENABLE_SCRIPTS=true ;;
  d) ENABLE_SCRIPTS=false ;;
  s) ENABLE_SUDO=1 ;;
  r) export ENABLE_FILEREC=1 ;;
  b) export ENABLE_FILEREC_SUDO=1 ;;
  z) export PKG_URL="${OPTARG}" ;;

  \?)
    echo "Option does not exist."
    exit 1
    ;;
  esac # --- end of case ---
done
shift $((OPTIND - 1))
$ACTION # Execute the function according to the users decision
