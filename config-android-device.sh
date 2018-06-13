#!/bin/bash

set -e
tput civis # hides the cursor 
trap 'tput cnorm' EXIT # unhides the cursor on exit

VERSION="1.1.0"
INFO="ANDROID EMULATOR CONFIG SCRIPT ${VERSION}"

function printUsage() {
    echo ""
    echo "Usage:"
    echo "======"
    echo "   config-android-device.sh [-h] [-v] [<android device name>|<emulator serial>] [-r] [-w] [-p <port>] [--certificate <certificate>] [--host [<ip>] <domain>]"
    echo ""
    echo "Device options:"
    echo "   <android device name>      : The Android Device name as it is specified in the lists of available AVDs."
    echo "                                If the device is not running, it will be started. The <wipe> and <port> options will be used when starting the device!"
    echo "                                Run the following command to see the list of available devices: <Path to Android SDK>/emulator/emulator -list-avds"
    echo "   <emulator serial>          : Specify which running emulator to use given the emulator serial number."
    echo "                                Run the following command to see the list of running emulators: adb devices"
    echo ""
    echo "   Note: If neither <android device name> nor <emulator serial> is provided, it is expected that there is a single emulator running and it will then be used."
    echo ""
    echo "Additional options"
    echo "   -h | --help                : Print this menu"
    echo "   -v | --version             : Print the version number of the script"
    echo "        --certificate         : Install a root PEM certificate from the given path"
    echo "        --host                : Adds domain and ip to emulator's known hosts file. Leave the <ip> empty to use the machine's ip"
    echo "   -r | --restart             : Restart the given emulator if it is running"
    echo "   -w | --wipe                : When (re-)starting, wipe the data on the emulator"
    echo "   -p | --port                : When (re-)starting, the given port will be used for the emulator."
}

function doFail() {
	echo -e >&2 '\n'"❌ $1"
	exit -1
}

function doFailWithUsage() {
	echo -e >&2 '\n'"❌ $1"
  printUsage
	exit -1
}

function isIP() {
  [[ "$1" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]] | true
  echo ${PIPESTATUS[0]}
}

function parseOptions() {
    if [[ $# == 0 ]]; then
        echo "${INFO}"
        printUsage
        exit 0
    fi

    if [[ "${1}" != -* ]]; then
      givenDevice=$1
      shift
    fi

    while test $# -gt 0; do
      case $1 in
        -h | --help)
          # Print usage and help
          echo "${INFO}"
          printUsage
          exit 0
          ;;

        -v | --version)
          # Print version info
          echo "$VERSION"
          exit 0
          ;;

        --certificate)
          # Cetificate path
          CERTIFICATE_PATH=$2
          shift
          ;;

        --host)
          # host and optional ip address
          if [[ $(isIP "$2") == 0 ]]; then
            IP="$2"
            DOMAIN="$3"
            shift
          elif [[ $(isIP "$3") == 0 ]]; then
            IP="$3"
            DOMAIN="$2"
            shift
          else
            DOMAIN="$2"
          fi
          shift
          ;;

        -r | --restart)
          # Device name
          SHOULD_RESTART_DEVICE=true
          ;;

        -w | --wipe)
          # Wipe the data on the emulator
          WIPE=true
          ;;

        -p | --port)
          PORT=$2
          shift
          ;;

        --*)
          # error unknown (long) option $1
          doFailWithUsage "Invalid option: $1"
          ;;

        -*)
          # error unknown (short) option $1
          doFailWithUsage "Invalid option: $1"
          ;;

        *)
          # Done with options
          break
          ;;
      esac

    if [[ $# > 0 ]]; then
      shift
    fi
    done
}

function waitForDevice() {
  # Wait for device to be started
  adb -s ${emulator_serial} wait-for-device

  # Wait for device to be booted
  local boot_status=$(adb -s ${emulator_serial} shell getprop sys.boot_completed | tr -d '\r')
  while [[ "${boot_status}" != "1" ]]; do
    sleep 1
    local boot_status=$(adb -s ${emulator_serial} shell getprop sys.boot_completed | tr -d '\r')
  done
}

function listRunningEmulators() {
  local result=()
  for emulator in "$(adb devices | grep emulator)"; do
    local emulatorSerial="$(echo $emulator | cut -f1 | cut -d ' ' -f1)"
    result+=(${emulatorSerial})
  done
  echo ${result[@]}
}

function getEmulatorNameFromSerial() {
  local serial="$1"
  local emulatorPort=${serial##*"emulator-"}
  echo $(
    echo "avd name" | 
    nc localhost ${emulatorPort} | 
    tr -d '\r' | 
    awk '/OK/{getline; print}' | 
    head -n 1
  )
}

function findDeviceByName() {
  local name="$1"
  for emulator in $(listRunningEmulators); do 
    local foundName=$(getEmulatorNameFromSerial ${emulator})
    if [[ "${foundName}" == "${name}" ]]; then 
      echo ${emulator}
      return
    fi
  done
}

function countRunningEmulators() {
  echo $(adb devices | grep 'emulator' | wc -l)
}

function startEmulator() {
  echo -n "${CURRENT_SPINNER} Starting emulator${start_text}"
  ${emulatorCLI} -writable-system -netdelay none -netspeed full -dns-server 192.168.98.14,8.8.8.8 -avd ${device_name}${wipe_argument} -port ${PORT} &> /dev/null & # TODO: Perhaps pipe log to file?  
  local pid=$!
  # wait 2 seconds for the emulator to begin starting up
  local sleepCounter=0
  while [[ ${sleepCounter} -lt 20 ]]; do
    sleep 0.1
    spinSpinner
    echo -ne '\r'"${CURRENT_SPINNER}"
    ((sleepCounter++))
  done
  # is it starting up?
  local status=1
  while [[ ${status} != 0 ]]; do
    ps -p ${pid} &> /dev/null | true
    status=${PIPESTATUS[0]}
    if [[ ${status} == 1 ]]; then
      doFail "ERROR: Emulator exited while starting up"
    fi
    sleep 0.1
    spinSpinner
    echo -ne '\r'"${CURRENT_SPINNER}"
  done
  waitForDevice
  echo -e '\r'"✅ Started emulator${start_text} "
}

function setDeviceRoot() {
  if [[ -z ${isRoot} ]]; then
    adb -s ${emulator_serial} root &> /dev/null && adb -s ${emulator_serial} remount &> /dev/null
    isRoot=true
  fi
}

function checkDeviceRunningAndReady() {
  local serial="$1"
  local state=$(adb -s ${serial} get-state 2> /dev/null || true)
  if [[ "${state}" == "" ]]; then
    doFail "ERROR: The emulator with serial ${serial} is not running"
  fi

  if [[ "${state}" != "device" ]]; then
    doFail "ERROR: The emulator with serial ${serial} is running, but not in the expected state 'device'. State is ${state}"
  fi
}

function checkDeviceAndSetDeviceName() {
  local serial="$1"  
  checkDeviceRunningAndReady ${serial}
  device_name=$(getEmulatorNameFromSerial ${serial})
  deviceIsRunning=true  
}

# returns 0 if the port is in use, 1 if not.
function isPortInUse() {
  lsof -Pi :"$1" -sTCP:LISTEN -t &> /dev/null | true
  echo ${PIPESTATUS[0]}
}

function getFreePort() {
  local currentPort="$1"
  local status="0"
  while [[ "${status}" == "0" ]]; do
    status=$(isPortInUse ${currentPort})
    if [[ "${status}" == "0" ]]; then
      currentPort=$(($currentPort + 1))
    fi
  done
  echo ${currentPort}
}

function checkDeviceName() {
  for emu in $(${emulatorCLI} -list-avds); do 
    if [[ "${emu}" == "${givenDevice}" ]]; then
      echo 0
      return
    fi
  done
  echo 1
}

function setCurrentSpinner() {
  CURRENT_SPINNER=${SPINNER:$SPINNER_COUNTER:1}
}

function spinSpinner() {
  ((SPINNER_COUNTER++))
  if [[ ${SPINNER_COUNTER} == ${#SPINNER} ]]; then
    SPINNER_COUNTER=0
  fi
  setCurrentSpinner
}

###################################################################
#                           Main part                             #
###################################################################
# Extract the options from the command line
parseOptions $@

echo "${INFO}"

emulatorCLI="${HOME}/Library/Android/sdk/emulator/emulator"

# Check for emulator
if [[ ! -f "${emulatorCLI}" ]]; then
  doFail "ERROR: Could not find Android emulator. Should be located at ${emulatorCLI}"
fi

# Check for adb
command -v adb >/dev/null 2>&1 || { doFail "ERROR: Could not find adb command"; }

# Check for openssl
command -v openssl >/dev/null 2>&1 || { doFail  "ERROR: Could not find openssl command"; }

# Check for netcat
command -v nc >/dev/null 2>&1 || { doFail "ERROR: Could not find nc command"; }

#SPINNER="◷◶◵◴"
#SPINNER="⣄⡤⢤⣠"
#SPINNER="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPINNER="🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛"
SPINNER_COUNTER=0
setCurrentSpinner

if [[ -z "${DOMAIN+x}" || "${DOMAIN}" == "" ]]; then 
  if [[ -n "${IP+x}" ]]; then
    doFail "ERROR: IP found for <host> option, but did not find value for domain."
  fi
fi

# Set the device_name and emulator_serial variables (used to identify the emulator)
if [[ -z "${givenDevice+x}" || "${givenDevice}" == "" ]]; then 
  emulatorCount=$(countRunningEmulators)
  if [[ ${emulatorCount} == 1 ]]; then
    emulator_serial=$(listRunningEmulators)
    # We need the device to be running in order to get the device name - otherwise, we can't restart it or update it 
    checkDeviceAndSetDeviceName ${emulator_serial}
  else
    if [[ ${emulatorCount} == 0 ]]; then
      doFail "ERROR: No device or emulator info given, and no emulators are running. Specify an <android device name> to start a given device."
    else 
      doFail "ERROR: No device or emulator info given, and more than one emulator are running. Specify an <emulator serial> to select which emulator to use. Use 'adb devices' to list running emulators."
    fi
  fi
else
  # is it a Device Name?
  isDeviceName=$(checkDeviceName "${givenDevice}")
  if [[ ${isDeviceName} == 0 ]]; then
    device_name="${givenDevice}"
    emulator_serial=$(findDeviceByName ${device_name})
    # did we find the emulator?
    if [[ -n "${emulator_serial}" ]]; then
      if [[ -z "${SHOULD_RESTART_DEVICE+x}" || "${SHOULD_RESTART_DEVICE}" == "" ]]; then 
        # if the emulator is not set to be restarted, then we need to make sure that it is running
        checkDeviceRunningAndReady ${emulator_serial}
      fi
      deviceIsRunning=true
    fi
  else
    #  is it an emulator serial?
    for emulator in $(listRunningEmulators); do 
      if [[ "${emulator}" == ${givenDevice} ]]; then
        isEmulatorSerial=true
        emulator_serial=${givenDevice}
        # We need the device to be running in order to get the device name - otherwise, we can't restart it or update it 
        checkDeviceAndSetDeviceName ${emulator_serial}
      fi
    done
    if [[ -z "${emulator_serial+x}" || "${emulator_serial}" == "" ]]; then 
      doFail "ERROR: The given device identifier ${givenDevice} is neither a Device Name nor a running emulator serial."
    fi
  fi
fi

if [[ -z "${SHOULD_RESTART_DEVICE+x}" || "${SHOULD_RESTART_DEVICE}" == "" ]]; then 
  if [[ "${deviceIsRunning}" == true ]]; then
    if [[ -n "${PORT}" ]]; then
      echo "⚠️  Warning: Ignoring <port> option. The given emulator is already running, and the <restart> option is not set (see -r option)."
    fi
    if [[ -n "${WIPE}" ]]; then
      echo "⚠️  Warning: Ignoring <wipe> option. The given emulator is already running, and the <restart> option is not set (see -r option)."
    fi
    if [[ -z "${CERTIFICATE_PATH+x}" || "${CERTIFICATE_PATH}" == "" ]]; then 
      if [[ -z "${DOMAIN+x}" || "${DOMAIN}" == "" ]]; then 
        echo "The emulator is already running. Nothing to do."
      fi
    fi
  fi
fi
if [[ -n "${CERTIFICATE_PATH}" ]]; then
  if [[ ! -f "${CERTIFICATE_PATH}" ]]; then
    doFail "ERROR: Could not find file at ${CERTIFICATE_PATH}"
  fi
fi

if [[ -n "${DOMAIN}" ]]; then
  if [[ -z "${IP+x}" || "${IP}" == "" ]]; then
    IP="$(ifconfig en0 | grep "inet " | cut -d\  -f2)"
    echo " - <ip> is not set. Using ${IP}"
  fi
fi

if [[ "${deviceIsRunning}" == true ]]; then
  if [[ "${SHOULD_RESTART_DEVICE}" == true ]]; then
    shouldStartEmulator=true
    echo -n "${CURRENT_SPINNER} Stopping existing emulator"
    adb -s ${emulator_serial} emu kill
    # wait for killing to be done
    adb -s ${emulator_serial} get-state &> /dev/null | true
    while [[ ${PIPESTATUS[0]} == 0 ]]; do
      sleep 0.1
      spinSpinner
      echo -en '\r'"${CURRENT_SPINNER}"
      adb -s ${emulator_serial} get-state &> /dev/null | true
    done
    echo -e '\r'"✅ Stopped existing emulator "
  fi
else
  shouldStartEmulator=true
fi

if [[ "${shouldStartEmulator}" == true ]]; then
  if [[ -n "${PORT}" ]]; then
    if [[ $(isPortInUse ${PORT}) == 0 ]]; then
      doFail "ERROR: The port ${PORT} is already in use!"
    fi
  else
    PORT=$(getFreePort 5554)
  fi

  wipe_argument=""
  if [[ -n ${WIPE} ]]; then
    wipe_argument=" -wipe-data"
    wipe_text="wiping data"
  fi

  if [[ -n "${PORT}" ]]; then
    if [[ $(isPortInUse ${PORT}) == 0 ]]; then
      doFail "ERROR: The port ${PORT} is already in use!"
    fi
  else
    PORT=$(getFreePort 5554)
  fi

  port_text="using port ${PORT}"
  if [[ -n "${wipe_text}" ]]; then
    start_text=" (${wipe_text} and ${port_text})"
  else 
    start_text=" (${port_text})"
  fi

  emulator_serial="emulator-${PORT}"

  # Start emulator
  startEmulator
fi

if [[ -n ${emulator_serial} ]]; then
  adb -s ${emulator_serial} get-state &> /dev/null | true
  if [[ ${PIPESTATUS[0]} == 0 ]]; then
    waitForDevice
  else
    doFail "ERROR: Device is not running."
  fi    
fi

if [[ -n ${CERTIFICATE_PATH} ]]; then
  setDeviceRoot

  echo -n " - Generating certificate for Android"
  hash=$(openssl x509 -inform PEM -subject_hash_old -in "${CERTIFICATE_PATH}" | head -1)

  if [[ "${hash}" == "" ]]; then
    doFail "ERROR: Could not generate certificate hash"
  fi

  echo " (hash: ${hash})"
  filename="$(mktemp ${TMPDIR}XXXXXXXXX)"
  cat "${CERTIFICATE_PATH}" > "${filename}"
  openssl x509 -inform PEM -text -in "${CERTIFICATE_PATH}" -noout >> "${filename}"

  echo -e '\r'"✅ Generated certificate for Android"
  echo -n " - Pushing certificate to emulator"
  adb push "${filename}" "/system/etc/security/cacerts/${hash}.0" &> /dev/null
  echo -e '\r'"✅ Pushed certificate to emulator "

  # Cleanup
  rm -f "{$filename}"
fi

if [[ -n ${DOMAIN} ]] && [[ -n ${IP} ]]; then
  setDeviceRoot

  echo " - Updating hosts file"
  echo "   - pulling existing hosts file"

  filename="$(mktemp ${TMPDIR}XXXXXXXXX)"
  adb -s ${emulator_serial} pull "/system/etc/hosts" ${filename} &> /dev/null

  echo "   - finding existing entry"

  matches_in_hosts="$(grep -n ${DOMAIN} "${filename}" | cut -f1 -d:)"
  host_entry="${IP} ${DOMAIN}"

  if [[ -n "${matches_in_hosts}" ]]; then
    echo "   - updating existing hosts entry"
    # iterate over the line numbers on which matches were found
    while read -r line_number; do
      existing_line="$(sed "${line_number}q;d" ${filename})"
      existing_line_no_leading_space="$(echo -e "${existing_line}" | sed -e 's/^[[:space:]]*//')"
        # replace the text of each line with the desired host entry
        if [[ "${existing_line_no_leading_space}" != '#'* ]]; then
          if [[ "${existing_line_no_leading_space}" != "${host_entry}" ]]; then
            echo "   - replacing '${existing_line}' with '${host_entry}'" 
            sed -i '' "${line_number}s/.*/${host_entry}/" ${filename}
            echo "   - done replacing entry"
          else
            echo "   - the entry '${host_entry}' already exists"
          fi
        fi
    done <<< "$matches_in_hosts"
  else
    echo "   - none found. Adding new entry"
    echo "$host_entry" | tee -a "${filename}" &> /dev/null
    echo "   - done adding entry"
  fi
  echo " - pushing updated hosts file to device"
  adb -s ${emulator_serial} push "${filename}" "/system/etc/hosts" &> /dev/null
  ## Cleanup
  rm -f "${filename}"
  echo "✅ Done updating hosts file"
fi
