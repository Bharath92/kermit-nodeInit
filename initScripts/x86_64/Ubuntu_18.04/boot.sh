#!/bin/bash
set -e
set -o pipefail

# Main directories
readonly SHIPPABLE_DIR="/jfrog/config"

# Node ENVs
readonly NODE_ENV="$SHIPPABLE_DIR/nodeInit.env"
source $NODE_ENV

# Scripts
readonly NODE_INIT_SCRIPT="$NODE_SCRIPTS_LOCATION/initScripts/$NODE_INIT_SCRIPT"
readonly NODE_LIB_DIR="$NODE_SCRIPTS_LOCATION/lib"

# Source libraries
source "$NODE_LIB_DIR/logger.sh"
source "$NODE_LIB_DIR/headers.sh"
source "$NODE_LIB_DIR/helpers.sh"

check_input() {
  local expected_envs=(
    'EXEC_IMAGE'
    'LISTEN_QUEUE'
    'NODE_ARCHITECTURE'
    'NODE_ID'
    'NODE_INIT_SCRIPT'
    'NODE_OPERATING_SYSTEM'
    'NODE_TYPE_CODE'
    'RUN_MODE'
    'SHIPPABLE_AMQP_DEFAULT_EXCHANGE'
    'SHIPPABLE_AMQP_URL'
    'SHIPPABLE_API_URL'
    'SHIPPABLE_WWW_URL'
    'SHIPPABLE_RUNTIME_VERSION'
    'SHIPPABLE_RELEASE_VERSION'
  )

  check_envs "${expected_envs[@]}"
}

export_envs() {
  export BASE_DIR="/jfrog"
  export REQPROC_DIR="$BASE_DIR/reqProc"
  export REQEXEC_DIR="$BASE_DIR/reqExec"
  export EXECTEMPLATES_DIR="$BASE_DIR/execTemplates"
  export REQEXEC_BIN_PATH="$REQEXEC_DIR/dist/main/main"
  export REQKICK_DIR="$BASE_DIR/reqKick"
  export REQKICK_SERVICE_DIR="$REQKICK_DIR/helpers/templates/service/init/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM"
  export REQKICK_CONFIG_DIR="$BASE_DIR/config"
  # This is set while booting dynamic nodes
  export REQPROC_MOUNTS="$REQPROC_MOUNTS"
  export REQPROC_ENVS="$REQPROC_ENVS"
  export REQPROC_OPTS="$REQPROC_OPTS"
  export REQPROC_CONTAINER_NAME="reqProc"
  export REQKICK_SERVICE_NAME="shippable-reqKick"
  export TASK_CONTAINER_COMMAND="/reqExec/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM/dist/main/main"
  export DEFAULT_TASK_CONTAINER_OPTIONS="-d --rm"
  export DOCKER_VERSION="$(sudo docker version --format {{.Server.Version}})"
}

setup_dirs() {
  mkdir -p $BASE_DIR
  mkdir -p $REQPROC_DIR
  mkdir -p $REQEXEC_DIR
  mkdir -p $REQKICK_DIR
}

initialize() {
  __process_marker "Initializing node..."
  source $NODE_INIT_SCRIPT
}

remove_reqProc() {
  __process_marker "Removing exisiting reqProc containers..."

  local running_container_ids=$(docker ps -a \
    | grep $REQPROC_CONTAINER_NAME \
    | awk '{print $1}')

  if [ ! -z "$running_container_ids" ]; then
    docker rm -f -v $running_container_ids || true
  fi
}

remove_reqKick() {
  __process_marker "Removing existing reqKick services..."

  local running_service_names=$(systemctl list-units -a \
    | grep $REQKICK_SERVICE_NAME \
    | awk '{ print $1 }')

  if [ ! -z "$running_service_names" ]; then
    systemctl stop $running_service_names || true
    systemctl disable $running_service_names || true
  fi

  rm -rf $REQKICK_CONFIG_DIR
  rm -f /etc/systemd/system/$REQKICK_SERVICE_NAME.service

  systemctl daemon-reload
}

boot_reqKick() {
  __process_marker "Booting up reqKick service..."

  mkdir -p $REQKICK_CONFIG_DIR

  cp "$REQKICK_SERVICE_DIR"/"$REQKICK_SERVICE_NAME".service.template /etc/systemd/system/"$REQKICK_SERVICE_NAME".service
  chmod 644 /etc/systemd/system/"$REQKICK_SERVICE_NAME".service

  local reqkick_env_template=$REQKICK_SERVICE_DIR/$REQKICK_SERVICE_NAME.env.template
  local reqkick_env_file=$REQKICK_CONFIG_DIR/reqKick.env
  touch $reqkick_env_file
  sed "s#{{REQEXEC_BIN_PATH}}#$REQEXEC_BIN_PATH#g" $reqkick_env_template > $reqkick_env_file
  sed -i "s#{{RUN_MODE}}#$RUN_MODE#g" $reqkick_env_file
  sed -i "s#{{NODE_ID}}#$NODE_ID#g" $reqkick_env_file
  sed -i "s#{{PROJECT_ID}}#$PROJECT_ID#g" $reqkick_env_file
  sed -i "s#{{NODE_TYPE_CODE}}#$NODE_TYPE_CODE#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_NODE_ARCHITECTURE}}#$NODE_ARCHITECTURE#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_NODE_OPERATING_SYSTEM}}#$NODE_OPERATING_SYSTEM#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_API_URL}}#$SHIPPABLE_API_URL#g" $reqkick_env_file
  sed -i "s#{{EXECTEMPLATES_DIR}}#$EXECTEMPLATES_DIR#g" $reqkick_env_file
  sed -i "s#{{LISTEN_QUEUE}}#$LISTEN_QUEUE#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_AMQP_URL}}#$SHIPPABLE_AMQP_URL#g" $reqkick_env_file
  sed -i "s#{{BASE_DIR}}#$BASE_DIR#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_RUNTIME_VERSION}}#$SHIPPABLE_RUNTIME_VERSION#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_RELEASE_VERSION}}#$SHIPPABLE_RELEASE_VERSION#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_WWW_URL}}#$SHIPPABLE_WWW_URL#g" $reqkick_env_file
  sed -i "s#{{REQEXEC_DIR}}#$REQEXEC_DIR#g" $reqkick_env_file

  systemctl daemon-reload
  systemctl enable $REQKICK_SERVICE_NAME.service
  systemctl start $REQKICK_SERVICE_NAME.service

  {
    echo "Checking if $REQKICK_SERVICE_NAME.service is active"
    local check_reqKick_is_active=$(systemctl is-active $REQKICK_SERVICE_NAME.service)
    echo "$REQKICK_SERVICE_NAME.service is $check_reqKick_is_active"
  } || {
    echo "$REQKICK_SERVICE_NAME.service failed to start"
    journalctl -n 100 -u $REQKICK_SERVICE_NAME.service
    popd
    exit 1
  }
}

cleanup() {
  __process_marker "Cleaning up..."
  rm -f "$NODE_ENV"
}

before_exit() {
  echo $1
  echo $2

  echo "Boot script completed"
}

main() {
  trap before_exit EXIT
  exec_grp "check_input"

  trap before_exit EXIT
  exec_grp "export_envs"

  trap before_exit EXIT
  exec_grp "setup_dirs"

  if [ "$NODE_TYPE_CODE" -ne 7001 ]; then
    initialize
  fi

  trap before_exit EXIT
  exec_grp "remove_reqProc"

  trap before_exit EXIT
  exec_grp "remove_reqKick"

  trap before_exit EXIT
  exec_grp "boot_reqKick"

  trap before_exit EXIT
  exec_grp "cleanup"
}

main
