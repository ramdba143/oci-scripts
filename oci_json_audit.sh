#!/bin/bash
#************************************************************************
#
#   oci_json_audit.sh - Export all Oracle Cloud Audit metadata
#   information into JSON files.
#
#   Copyright 2019  Rodrigo Jorge <http://www.dbarj.com.br/>
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
#************************************************************************
# Available at: https://github.com/dbarj/oci-scripts
# Created on: Aug/2019 by Rodrigo Jorge
# Version 1.01
#************************************************************************
set -eo pipefail

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_oci="oci"
v_jq="jq"

# Add any desired oci argument exporting OCI_CLI_ARGS. Keep default to avoid oci_cli_rc usage.
[ -n "${OCI_CLI_ARGS}" ] && v_oci_args="${OCI_CLI_ARGS}"
[ -z "${OCI_CLI_ARGS}" ] && v_oci_args="--cli-rc-file /dev/null"

# Don't change it.
v_min_ocicli="2.4.34"

# Timeout for OCI-CLI calls
v_oci_timeout=600 # Seconds

# Default period in days to collect audit info if omitted
v_def_period=7

# Temporary Folder. Used to stage some repetitive jsons and save time. Empty to disable (not recommended).
v_tmpfldr="$(mktemp -d -u -p /tmp/.oci 2>&- || mktemp -d -u)"

# Export DEBUG=1 to see the steps being executed.
[[ "${DEBUG}" == "" ]] && DEBUG=0

# If Shell is executed with "-x", all core functions will set this flag 
printf %s\\n "$-" | grep -q -F 'x' && v_dbgflag='-x' || v_dbgflag='+x'

# Export HIST_ZIP_FILE with the file name where will keep or read for historical audit info to avoid reprocessing.
[[ "${HIST_ZIP_FILE}" == "" ]] && HIST_ZIP_FILE=""

v_hist_folder="audit_history"

function echoError ()
{
   (>&2 echo "$1")
}

function exitError ()
{
   echoError "$1"
   exit 1
}

function echoDebug ()
{
   local v_filename="${v_this_script%.*}.log"
   (( $DEBUG )) && echo "$(date '+%Y%m%d%H%M%S'): $1" >> ${v_filename}
   return 0
}

function funcCheckValueInRange ()
{
  [ "$#" -ne 2 -o -z "$1" -o -z "$2" ] && return 1
  local v_arg1 v_arg2 v_array v_opt
  v_arg1="$1" # Value
  v_arg2="$2" # Range
  v_array=$(tr "," "\n" <<< "${v_arg2}")
  for v_opt in $v_array
  do
    if [ "$v_opt" == "${v_arg1}" ]
    then
      echo "Y"
      return 0
    fi
  done
  echo "N"
}

function funcPrintRange ()
{
  [ "$#" -ne 1 -o -z "$1" ] && return 1
  local v_arg1 v_opt v_array
  v_arg1="$1" # Range
  v_array=$(tr "," "\n" <<< "${v_arg1}")
  for v_opt in $v_array
  do
    echo "- ${v_opt}"
  done
}

v_this_script="$(basename -- "$0")"

v_func_list=$(sed -e '1,/^# BEGIN DYNFUNC/d' -e '/^# END DYNFUNC/,$d' -e 's/^# *//' $0)
v_opt_list=$(echo "${v_func_list}" | cut -d ',' -f 1 | sort | tr "\n" ",")
v_valid_opts="ALL,ALL_REGIONS"
v_valid_opts="${v_valid_opts},${v_opt_list}"

v_param1="$1"
v_param2="$2"
v_param3="$3"

v_check=$(funcCheckValueInRange "$v_param1" "$v_valid_opts") && v_ret=$? || v_ret=$?

if [ "$v_check" == "N" -o $v_ret -ne 0 ]
then
  echoError "Usage: ${v_this_script} <option> [begin_time] [end_time]"
  echoError ""
  echoError "<option> - Execution Scope."
  echoError "[begin_time] (Optional) - Defines start time when exporting Audit Info. (Default is $v_def_period days back) "
  echoError "[end_time]   (Optional) - Defines end time when exporting Audit Info. (Default is today)"
  echoError ""
  echoError "Valid <option> values are:"
  echoError "- ALL         - Execute json export for ALL possible options and compress output in a zip file."
  echoError "- ALL_REGIONS - Same as ALL, but run for all tenancy's subscribed regions."
  echoError "$(funcPrintRange "$v_opt_list")"
  exit 1
fi

if ! $(which ${v_oci} >&- 2>&-)
then
  echoError "Could not find oci-cli binary. Please adapt the path in the script if not in \$PATH."
  echoError "Download page: https://github.com/oracle/oci-cli"
  exit 1
fi

if ! $(which ${v_jq} >&- 2>&-)
then
  echoError "Could not find jq binary. Please adapt the path in the script if not in \$PATH."
  echoError "Download page: https://github.com/stedolan/jq/releases"
  exit 1
fi

if ! $(which zip >&- 2>&-)
then
  if [ "${v_param1}" == "ALL" -o -n "$HIST_ZIP_FILE" ]
  then
    echoError "Could not find zip binary. Please include it in \$PATH."
    echoError "Zip binary is required to put all output json files together."
    exit 1
  fi
fi

v_cur_ocicli=$(${v_oci} -v)

if [ "${v_min_ocicli}" != "`echo -e "${v_min_ocicli}\n${v_cur_ocicli}" | sort -V | head -n1`" ]
then
  echoError "Minimal oci version required is ${v_min_ocicli}. Found: ${v_cur_ocicli}"
  exit 1
fi

[ -z "${v_oci_args}" ] || v_oci="${v_oci} ${v_oci_args}"

v_test=$(${v_oci} iam region-subscription list 2>&1) && v_ret=$? || v_ret=$?
if [ $v_ret -ne 0 ]
then
  echoError "oci-cli not able to run \"${v_oci} iam region-subscription list\". Please check error:"
  echoError "$v_test"
  exit 1
fi

v_start_time="${v_param2}"
v_end_time="${v_param3}"

if [ -z "${v_start_time}" ]
then
  case "$(uname -s)" in
      Linux*)     v_start_time=$(date -d "-${v_def_period} day" +%Y-%m-%d);;
      Darwin*)    v_start_time=$(date -v-${v_def_period}d +%Y-%m-%d);;
      *)          v_start_time=$(date +%Y-%m-%d)
  esac
fi

if [ -z "${v_end_time}" ]
then
  v_end_time=$(date +%Y-%m-%d)
fi

function check_input_format()
{
  local INPUT_DATE="$1"
  local INPUT_FORMAT="%Y-%m-%d"
  local OUTPUT_FORMAT="%Y-%m-%d"
  local UNAME=$(uname)

  if [[ "$UNAME" == "Darwin" ]] # Mac OS X
  then 
    date -j -f "$INPUT_FORMAT" "$INPUT_DATE" +"$OUTPUT_FORMAT" >/dev/null 2>&- || exitError "Date ${INPUT_DATE} in wrong format. Specify YYYY-MM-DD."
  elif [[ "$UNAME" == "Linux" ]] # Linux
  then
    date -d "$INPUT_DATE" +"$OUTPUT_FORMAT" >/dev/null 2>&- || exitError "Date ${INPUT_DATE} in wrong format. Specify YYYY-MM-DD."
  else # Unsupported system
    date -d "$INPUT_DATE" +"$OUTPUT_FORMAT" >/dev/null 2>&- || exitError "Unsupported system"
  fi
  [ ${#INPUT_DATE} -eq 10 ] || exitError "Date ${INPUT_DATE} in wrong format. Specify YYYY-MM-DD."
}

check_input_format "${v_start_time}"
check_input_format "${v_end_time}"

if ! $(which timeout >&- 2>&-)
then
  function timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

## Test if temp folder is writable
if [ -n "${v_tmpfldr}" ]
then
  mkdir -p "${v_tmpfldr}" 2>&- || true
else
  echoError "Temporary folder is DISABLED. Execution will take much longer."
  echoError "Press CTRL+C in next 10 seconds if you want to exit and fix this."
  sleep 10
fi
if [ -n "${v_tmpfldr}" -a ! -w "${v_tmpfldr}" ]
then
  echoError "Temporary folder \"${v_tmpfldr}\" is NOT WRITABLE. Execution will take much longer."
  echoError "Press CTRL+C in next 10 seconds if you want to exit and fix this."
  sleep 10
  v_tmpfldr=""
fi

################################################
############### CUSTOM FUNCTIONS ###############
################################################

function jsonCompartments ()
{
  set -eo pipefail # Exit if error in any call.
  set ${v_dbgflag} # Enable Debug
  local v_fout v_tenancy_id
  v_fout=$(jsonSimple "iam compartment list --all --compartment-id-in-subtree true" ".")
  ## Remove DELETED compartments to avoid query errors
  if [ -n "$v_fout" ]
  then
    v_fout=$(${v_jq} '{data:[.data[] | select(."lifecycle-state" != "DELETED")]}' <<< "${v_fout}")
    v_tenancy_id=$(${v_jq} -r '[.data[]."compartment-id"] | unique | .[] | select(startswith("ocid1.tenancy.oc1."))' <<< "${v_fout}")
    ## Add root:
    v_fout=$(${v_jq} '.data += [{
                                 "compartment-id": "'${v_tenancy_id}'",
                                 "defined-tags": {},
                                 "description": null,
                                 "freeform-tags": {},
                                 "id": "'${v_tenancy_id}'",
                                 "inactive-status": null,
                                 "is-accessible": null,
                                 "lifecycle-state": "ACTIVE",
                                 "name": "ROOT",
                                 "time-created": null
                                }]' <<< "$v_fout")
    echo "${v_fout}"
  fi
}

function jsonAudEvents ()
{
  set -eo pipefail # Exit if error in any call.
  set ${v_dbgflag} # Enable Debug
  [ "$#" -eq 0 ] || { echoError "${FUNCNAME[0]} needs 0 parameter"; return 1; }
  local v_out v_fout v_jq_filter
  local v_start_epoch v_end_epoch v_jump v_next_epoch_start v_next_date_start v_next_epoch_end v_next_date_end
  local v_temp_concatenate v_file_counter

  v_jump=$((3600*24*1)) # Jump 1 days

  v_start_epoch=$(ConvYMDToEpoch ${v_start_time})
  v_end_epoch=$(ConvYMDToEpoch ${v_end_time})

  # If there is a temp folder, keep results to concatenate in 1 shoot
  if [ -n "${v_tmpfldr}" ]
  then
    v_temp_concatenate="${v_tmpfldr}/tempConc"
    rm -rf ${v_temp_concatenate}
    mkdir ${v_temp_concatenate}
  fi

  v_file_counter=1

  v_next_epoch_start=${v_start_epoch}
  v_next_date_start=$(ConvEpochToYMDhms ${v_next_epoch_start})
  v_next_epoch_end=$((${v_next_epoch_start}+${v_jump}))
  [ $v_next_epoch_end -ge ${v_end_epoch} ] && v_next_epoch_end=${v_end_epoch}
  v_next_date_end=$(ConvEpochToYMDhms ${v_next_epoch_end})

  v_jq_filter='{data:[.data[] | select(."request-action" != "GET")]}'

  while true
  do
    # Run
    v_out=$(jsonAllCompart "audit event list --all --start-time "${v_next_date_start}Z" --end-time "${v_next_date_end}Z"" "${v_jq_filter}")
    # If there is a temp folder, keep results to concatenate in 1 shoot
    if [ -n "${v_tmpfldr}" ]
    then
      echo "$v_out" >> "${v_temp_concatenate}/${v_file_counter}.json"
      ((v_file_counter++))
    else
      [ -n "$v_out" ] && v_fout=$(jsonConcatData "$v_fout" "$v_out")
    fi
    # Prepare for next loop
    v_next_epoch_start=${v_next_epoch_end} # Next second = Next day
    [ ${v_next_epoch_start} -ge ${v_end_epoch} ] && break
    v_next_date_start=$(ConvEpochToYMDhms ${v_next_epoch_start})
    v_next_epoch_end=$((${v_next_epoch_start}+${v_jump}))
    [ $v_next_epoch_end -ge ${v_end_epoch} ] && v_next_epoch_end=${v_end_epoch}
    v_next_date_end=$(ConvEpochToYMDhms ${v_next_epoch_end})
  done

  if [ -n "${v_tmpfldr}" ]
  then
    # To avoid: Argument list too long
    find "${v_temp_concatenate}" -name "*.json" -type f -exec cat {} + > "${v_temp_concatenate}"/all_json.concat
    v_fout=$(${v_jq} -c 'reduce inputs as $i (.; .data += $i.data)' "${v_temp_concatenate}"/all_json.concat)
    rm -rf ${v_temp_concatenate}
  fi

  [ -z "$v_fout" ] || ${v_jq} '.' <<< "${v_fout}"
}

function jsonAllCompart ()
{
  set -eo pipefail # Exit if error in any call.
  set ${v_dbgflag} # Enable Debug
  [ "$#" -eq 2 -a "$1" != ""  -a "$2" != "" ] || { echoError "${FUNCNAME[0]} needs 2 parameters"; return 1; }
  local v_arg1 v_arg2 v_out v_fout l_itens v_item
  v_arg1="$1" # Main oci call
  v_arg2="$2" # JQ Filter clause

  l_itens=$(IAM-Comparts | ${v_jq} -r '.data[].id')

  for v_item in $l_itens
  do
    v_out=$(jsonSimple "${v_arg1} --compartment-id $v_item" "${v_arg2}")
    v_fout=$(jsonConcatData "$v_fout" "$v_out")
  done
  [ -z "$v_fout" ] || echo "${v_fout}"
}

function jsonSimple ()
{
  set -eo pipefail # Exit if error in any call.
  set ${v_dbgflag} # Enable Debug
  [ "$#" -eq 2 -a "$1" != ""  -a "$2" != "" ] || { echoError "${FUNCNAME[0]} needs 2 parameters"; return 1; }
  local v_arg1 v_arg2 v_out v_fout v_next_page v_arg1_mod
  v_arg1="$1"
  v_arg2="$2"
  v_arg1_mod="$v_arg1"
  while true
  do
    v_out=$(runOCI "${v_arg1_mod}" "${v_arg2}")
    v_next_page=$(${v_jq} -rc '."opc-next-page" // empty' <<< "${v_out}")
    [ -n "${v_next_page}" ] && v_out=$(${v_jq} -c '.data | {data : .}' <<< "$v_out") # Remove Next-Page Tag if it has one.
    [ -n "${v_next_page}" ] && v_arg1_mod="${v_arg1} --page ${v_next_page}"
    v_fout=$(jsonConcatData "$v_fout" "$v_out")
    [ -z "${v_next_page}" ] && break
  done
  [ -z "$v_fout" ] || echo "${v_fout}"
}

function runOCI ()
{
  set -eo pipefail # Exit if error in any call.
  set ${v_dbgflag} # Enable Debug
  [ "$#" -eq 2 -a "$1" != "" -a "$2" != "" ] || { echoError "${FUNCNAME[0]} needs 2 parameters"; return 1; }
  local v_arg1 v_arg2 v_out v_ret
  v_arg1="$1"
  v_arg2="$2"
  v_out=$(getFromHist "${v_arg1}") && v_ret=$? || v_ret=$?
  if [ $v_ret -ne 0 ]
  then
    echoDebug "${v_oci} ${v_arg1}"
    v_out=$(eval "timeout ${v_oci_timeout} ${v_oci} ${v_arg1}" | ${v_jq} -c "${v_arg2}")
    putOnHist "${v_region} ${v_arg1}" "${v_out}" || true
  else
    echoDebug "Got \"${v_arg1}\" from Zip Hist."      
  fi
  ${v_jq} -e . >/dev/null 2>&1 <<< "${v_out}" && v_ret=$? || v_ret=$?
  echo "${v_out}"
  return ${v_ret}
}

function jsonConcatData ()
{
  set -eo pipefail # Exit if error in any call.
  set ${v_dbgflag} # Enable Debug
  [ "$#" -eq 2 ] || { echoError "${FUNCNAME[0]} needs 2 parameters"; return 1; }
  local v_arg1 v_arg2 v_chk_json
  v_arg1="$1" # Json 1
  v_arg2="$2" # Json 2
  ## Concatenate if both not null.
  [ -z "${v_arg1}" -a -n "${v_arg2}" ] && echo "${v_arg2}" && return 0
  [ -n "${v_arg1}" -a -z "${v_arg2}" ] && echo "${v_arg1}" && return 0
  [ -z "${v_arg1}" -a -z "${v_arg2}" ] && return 0
  ## Check if has ".data"
  v_chk_json=$(${v_jq} -c 'has("data")' <<< "${v_arg1}")
  [ "${v_chk_json}" == "false" ] && return 1
  v_chk_json=$(${v_jq} -c 'has("data")' <<< "${v_arg2}")
  [ "${v_chk_json}" == "false" ] && return 1
  v_chk_json=$(${v_jq} -rc '.data | if type=="array" then "yes" else "no" end' <<< "$v_arg1")
  [ "${v_chk_json}" == "no" ] && v_arg1=$(${v_jq} -c '.data | {"data":[.]}' <<< "$v_arg1")
  v_chk_json=$(${v_jq} -rc '.data | if type=="array" then "yes" else "no" end' <<< "$v_arg2")
  [ "${v_chk_json}" == "no" ] && v_arg2=$(${v_jq} -c '.data | {"data":[.]}' <<< "$v_arg2")
  ${v_jq} -c 'reduce inputs as $i (.; .data += $i.data)' <(echo "$v_arg1") <(echo "$v_arg2")
  return 0
}

function ConvYMDToEpoch ()
{
  local v_in_date
  v_in_date="$1"
  case "$(uname -s)" in
      Linux*)     echo $(date -u '+%s' -d ${v_in_date});;
      Darwin*)    echo $(date -j -u -f '%Y-%m-%d %T' "${v_in_date} 00:00:00" +"%s");;
      *)          echo
  esac  
}

function ConvYMDtoNextMonthFirstDay ()
{
  local v_in_date
  v_in_date="$1"
  case "$(uname -s)" in
      Linux*)     echo $(date -u '+%Y-%m-01' -d "${v_in_date} +1 month -$(($(date +%d)-1)) days");;
      Darwin*)    echo $(date -j -u -v '+1m' -f '%Y-%m-%d' "${v_in_date}" +'%Y-%m-01');;
      *)          echo
  esac  
}

function ConvEpochToYMDhms ()
{
  local v_in_epoch
  v_in_epoch="$1"
  case "$(uname -s)" in
      Linux*)     echo $(date -u '+%Y-%m-%dT%T' -d @${v_in_epoch});;
      Darwin*)    echo $(date -j -u -f '%s' "${v_in_epoch}" +"%Y-%m-%dT%T");;
      *)          echo
  esac  
}

function ConvEpochToWeekDay ()
{
  local v_in_epoch
  v_in_epoch="$1"
  case "$(uname -s)" in
      Linux*)     echo $(date -u '+%u' -d @${v_in_epoch});;
      Darwin*)    echo $(date -j -u -f '%s' "${v_in_epoch}" +"%u");;
      *)          echo
  esac  
}

################################################
################# OPTION LIST ##################
################################################

# Structure:
# 1st - Json Function Name.
# 2nd - Json Target File Name. Used when ALL parameter is passed to the shell.
# 3rd - Function to call. Can be one off the generics above or a custom one.
# 4th - CURL command line to be executed.

## https://docs.oracle.com/en/cloud/get-started/subscriptions-cloud/meter/rest-endpoints.html

# DON'T REMOVE/CHANGE THOSE COMMENTS. THEY ARE USED TO GENERATE DYNAMIC FUNCTIONS

# BEGIN DYNFUNC
# IAM-RegionSub,oci_iam_region-subscription.json,jsonSimple,"iam region-subscription list" "."
# IAM-Comparts,oci_iam_compartment.json,jsonCompartments
# Audit-Events,oci_audit_event.json,jsonAudEvents
# END DYNFUNC

# The while loop below will create a function for each line above.
# Using File Descriptor 3 to not interfere on "eval"
while read -u 3 -r c_line || [ -n "$c_line" ]
do
  c_name=$(cut -d ',' -f 1 <<< "$c_line")
  c_fname=$(cut -d ',' -f 2 <<< "$c_line")
  c_subfunc=$(cut -d ',' -f 3 <<< "$c_line")
  c_param=$(cut -d ',' -f 4 <<< "$c_line")
  if [ -z "${v_tmpfldr}" ]
  then
    eval "function ${c_name} ()
          {
            local c_ret
            ${c_subfunc} ${c_param} && c_ret=\$? || c_ret=\$?
            return \${c_ret}
          }"
  else
    eval "function ${c_name} ()
          {
            local c_ret
            stopIfProcessed ${c_fname} || return 0
            ${c_subfunc} ${c_param} > ${v_tmpfldr}/.${c_fname} && c_ret=\$? || c_ret=\$?
            cat ${v_tmpfldr}/.${c_fname}
            return \${c_ret}
          }"
  fi
done 3< <(echo "$v_func_list")

function stopIfProcessed ()
{
  set ${v_dbgflag} # Enable Debug
  # If function was executed before, print the output and return error. The dynamic eval function will stop if error is returned.
  local v_arg1="$1"
  [ -z "${v_tmpfldr}" ] && return 0
  if [ -f "${v_tmpfldr}/.${v_arg1}" ]
  then
    cat "${v_tmpfldr}/.${v_arg1}"
    return 1
  else
    return 0
  fi
}

function runAndZip ()
{
  [ "$#" -eq 2 -a "$1" != "" -a "$2" != "" ] || { echoError "${FUNCNAME[0]} needs 2 parameters"; return 1; }
  local v_arg1 v_arg2 v_ret
  v_arg1="$1"
  v_arg2="$2"
  echo "Processing \"${v_arg2}\"."
  ${v_arg1} > "${v_arg2}" 2> "${v_arg2}.err" && v_ret=$? || v_ret=$?
  if [ $v_ret -eq 0 ]
  then
    if [ -s "${v_arg2}.err" ]
    then
      mv "${v_arg2}.err" "${v_arg2}.log"
      zip -qmT "$v_outfile" "${v_arg2}.log"
    fi
  else
    if [ -f "${v_arg2}.err" ]
    then
      echo "Skipped. Check \"${v_arg2}.err\" for more details."
      zip -qmT "$v_outfile" "${v_arg2}.err"
    fi
  fi
  [ ! -f "${v_arg2}.err" ] || rm -f "${v_arg2}.err"
  if [ -s "${v_arg2}" ]
  then
    zip -qmT "$v_outfile" "${v_arg2}"
  else
    rm -f "${v_arg2}"
  fi
  echo "$v_arg2" >> "${v_listfile}"
}

function cleanTmpFiles ()
{
  [ -z "${v_tmpfldr}" ] || rm -f "${v_tmpfldr}"/.*.json 2>&- || true
}

function uncompressHist ()
{
  set ${v_dbgflag} # Enable Debug
  if [ -n "${HIST_ZIP_FILE}" ]
  then
    rm -rf ${v_hist_folder}
    mkdir  ${v_hist_folder}
    if [ -r "${HIST_ZIP_FILE}" ]
    then
      unzip -d ${v_hist_folder} "${HIST_ZIP_FILE}" >/dev/null
    fi
  fi
  return 0
}

function cleanHist ()
{
  set ${v_dbgflag} # Enable Debug
  if [ -n "${HIST_ZIP_FILE}" ]
  then
    # [ "$(ls -A ${v_hist_folder})" ] && zip -mj ${HIST_ZIP_FILE} ${v_hist_folder}/* >/dev/null
    # rmdir ${v_hist_folder}
    rm -rf ${v_hist_folder}
  fi
  return 0
}

function getFromHist ()
{
  set -eo pipefail
  set ${v_dbgflag} # Enable Debug
  [ -z "${HIST_ZIP_FILE}" ] && return 1
  [ "$#" -ne 1 ] && { echoError "${FUNCNAME[0]} needs 1 parameter"; return 1; }
  local v_arg1 v_line v_sep v_list v_file v_file_epoch v_now_epoch
  v_arg1="$1"
  v_list="audit_hist_list.txt"
  v_sep="|"
  # grep -q "startTime=" <<< "${v_arg1}" || return 1
  # grep -q "endTime=" <<< "${v_arg1}" || return 1
  [ ! -r "${v_hist_folder}/${v_list}" ] && return 1
  v_line=$(grep -F "${v_arg1}${v_sep}" "${v_hist_folder}/${v_list}")
  [ $(wc -l <<< "${v_line}") -gt 1 ] && return 1
  v_file=$(cut -d"${v_sep}" -f2 <<< "${v_line}")
  [ -z "${v_file}" ] && return 1
  [ ! -r "${v_hist_folder}/${v_file}" ] && return 1
  if ! ( grep -q -F "start-time" <<< "${v_arg1}" && grep -q -F "end-time" <<< "${v_arg1}" )
  then    
    v_file_epoch=$(date -r "${v_hist_folder}/${v_file}" -u '+%s')
    v_now_epoch=$(date -u '+%s')
    [ $((v_now_epoch-v_file_epoch)) -ge $((3600*24*3)) ] && return 1 # 3 days
  fi
  cat "${v_hist_folder}/${v_file}"
  return 0
}

function putOnHist ()
{
  set -eo pipefail
  set ${v_dbgflag} # Enable Debug
  [ -z "${HIST_ZIP_FILE}" ] && return 1
  [ "$#" -ne 2 ] && { echoError "${FUNCNAME[0]} needs 2 parameters"; return 1; }
  local v_arg1 v_arg2 v_line v_sep v_list v_file v_last
  v_arg1="$1"
  v_arg2="$2"
  v_list="audit_hist_list.txt"
  v_sep="|"
  v_line=$(grep -F "${v_arg1}${v_sep}" "${v_hist_folder}/${v_list}") || true
  if [ -z "${v_line}" ]
  then
    if [ -r "${v_hist_folder}/${v_list}" ]
    then
      v_last=$(cut -d"${v_sep}" -f2 < "${v_hist_folder}/${v_list}" | sed 's/\.json$//' | sort -nr | head -n 1)
    else
      v_last=0
    fi
    v_file="$((v_last+1)).json"
    [ -r "${v_hist_folder}/${v_file}" ] && return 1
    echo "${v_arg1}${v_sep}${v_file}" >> "${v_hist_folder}/${v_list}"
    echo "${v_arg2}" > "${v_hist_folder}/${v_file}"
  else
    [ $(wc -l <<< "${v_line}") -gt 1 ] && return 1
    v_file=$(cut -d"${v_sep}" -f2 <<< "${v_line}")
    [ ! -r "${v_hist_folder}/${v_file}" ] && return 1
    echo "${v_arg2}" > "${v_hist_folder}/${v_file}"
  fi
  zip -j ${HIST_ZIP_FILE} "${v_hist_folder}/${v_file}" >/dev/null
  zip -j ${HIST_ZIP_FILE} "${v_hist_folder}/${v_list}" >/dev/null
  return 0
}

function main ()
{
  # If ALL or ALL_REGIONS, loop over all defined options.
  local c_line c_name c_file
  cleanTmpFiles
  uncompressHist
  if [ "${v_param1}" != "ALL" -a "${v_param1}" != "ALL_REGIONS" ]
  then
    ${v_param1} && v_ret=$? || v_ret=$?
  else
    [ -n "$v_outfile" ] || v_outfile="${v_this_script%.*}_$(date '+%Y%m%d%H%M%S').zip"
    v_listfile="${v_this_script%.*}_list.txt"
    rm -f "${v_listfile}"
    while read -u 3 -r c_line || [ -n "$c_line" ]
    do
       c_name=$(cut -d ',' -f 1 <<< "$c_line")
       c_file=$(cut -d ',' -f 2 <<< "$c_line")
       runAndZip $c_name $c_file
    done 3< <(echo "$v_func_list")
    zip -qmT "$v_outfile" "${v_listfile}"
    v_ret=0
  fi
  cleanHist
  cleanTmpFiles
}

# Start code execution.
echoDebug "BEGIN"
if [ "${v_param1}" == "ALL_REGIONS" ]
then
  l_regions=$(IAM-RegionSub | ${v_jq} -r '.data[]."region-name"')
  v_oci_orig="$v_oci"
  v_outfile_pref="${v_this_script%.*}_$(date '+%Y%m%d%H%M%S')"
  for v_region in $l_regions
  do
    echo "########################"
    echo "Region ${v_region} set."
    v_oci="${v_oci_orig} --region ${v_region}"
    v_outfile="${v_outfile_pref}_${v_region}.zip"
    main
  done
else
  main
fi
echoDebug "END"

[ -z "${v_tmpfldr}" ] || rmdir ${v_tmpfldr} 2>&- || true

exit ${v_ret}
###