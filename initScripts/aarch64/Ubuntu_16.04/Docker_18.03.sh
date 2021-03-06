#!/bin/bash
set -e
set -o pipefail

# initScript for Ubuntu 16.04 and Docker 18.03
# ------------------------------------------------------------------------------

readonly DOCKER_VERSION="18.03.1"
readonly SWAP_FILE_PATH="/root/.__sh_swap__"
export docker_restart=false

export SHIPPABLE_RUNTIME_DIR="/var/lib/shippable"
export BASE_UUID="$(cat /proc/sys/kernel/random/uuid)"
export BASE_DIR="$SHIPPABLE_RUNTIME_DIR/$BASE_UUID"
export REQPROC_DIR="$BASE_DIR/reqProc"
export REQEXEC_DIR="$BASE_DIR/reqExec"
export REQEXEC_BIN_PATH="$REQEXEC_DIR/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM/dist/main/main"
export REQKICK_DIR="$BASE_DIR/reqKick"
export REQKICK_SERVICE_DIR="$REQKICK_DIR/init/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM"
export REQKICK_CONFIG_DIR="/etc/shippable/reqKick"
export BUILD_DIR="$BASE_DIR/build"
export STATUS_DIR=$BUILD_DIR/status
export SCRIPTS_DIR=$BUILD_DIR/scripts
export REQPROC_MOUNTS=""
export REQPROC_ENVS=""
export REQPROC_OPTS=""
export REQPROC_CONTAINER_NAME_PATTERN="reqProc"
export EXEC_CONTAINER_NAME_PATTERN="shippable-exec"
export REQPROC_CONTAINER_NAME="$REQPROC_CONTAINER_NAME_PATTERN-$BASE_UUID"
export REQKICK_SERVICE_NAME_PATTERN="shippable-reqKick@"
export REPORTS_BINARY_LOCATION_ON_HOST="/pipelines/reports"
export DEFAULT_TASK_CONTAINER_MOUNTS="-v $BUILD_DIR:$BUILD_DIR \
  -v $REQEXEC_DIR:/reqExec"
export TASK_CONTAINER_COMMAND="/reqExec/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM/dist/main/main"
export DEFAULT_TASK_CONTAINER_OPTIONS="-d --rm"
export SHIPPABLE_DIND_IMAGE="docker:$DOCKER_VERSION-dind"
export SHIPPABLE_DIND_CONTAINER_NAME="shippable-dind"

create_shippable_dir() {
  mkdir -p /home/shippable
}

install_prereqs() {
  local nodejs_version="8.16.0"
  echo "Installing prerequisite binaries"

  update_cmd="apt-get update"
  exec_cmd "$update_cmd"

  install_prereqs_cmd="apt-get -yy install apt-transport-https git python-pip software-properties-common ca-certificates curl"
  exec_cmd "$install_prereqs_cmd"

  pushd /tmp
  echo "Installing node $nodejs_version"

  get_node_tar_cmd="wget https://nodejs.org/dist/v$nodejs_version/node-v$nodejs_version-linux-arm64.tar.xz"
  exec_cmd "$get_node_tar_cmd"

  node_extract_cmd="tar -xf node-v$nodejs_version-linux-arm64.tar.xz"
  exec_cmd "$node_extract_cmd"

  node_copy_cmd="cp -Rf node-v$nodejs_version-linux-arm64/{bin,include,lib,share} /usr/local"
  exec_cmd "$node_copy_cmd"

  check_node_version_cmd="node -v"
  exec_cmd "$check_node_version_cmd"
  popd

  if ! [ -x "$(command -v jq)" ]; then
    echo "Installing jq"
    apt-get install -y jq
  fi

  update_cmd="apt-get update"
  exec_cmd "$update_cmd"
}

check_swap() {
  echo "Checking for swap space"

  swap_available=$(free | grep Swap | awk '{print $2}')
  if [ $swap_available -eq 0 ]; then
    echo "No swap space available, adding swap"
    is_swap_required=true
  else
    echo "Swap space available, not adding"
  fi
}

add_swap() {
  echo "Adding swap file"
  echo "Creating Swap file at: $SWAP_FILE_PATH"
  add_swap_file="touch $SWAP_FILE_PATH"
  exec_cmd "$add_swap_file"

  swap_size=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  swap_size=$(($swap_size/1024))
  echo "Allocating swap of: $swap_size MB"
  initialize_file="dd if=/dev/zero of=$SWAP_FILE_PATH bs=1M count=$swap_size"
  exec_cmd "$initialize_file"

  echo "Updating Swap file permissions"
  update_permissions="chmod -c 600 $SWAP_FILE_PATH"
  exec_cmd "$update_permissions"

  echo "Setting up Swap area on the device"
  initialize_swap="mkswap $SWAP_FILE_PATH"
  exec_cmd "$initialize_swap"

  echo "Turning on Swap"
  turn_swap_on="swapon $SWAP_FILE_PATH"
  exec_cmd "$turn_swap_on"

}

check_fstab_entry() {
  echo "Checking fstab entries"

  if grep -q $SWAP_FILE_PATH /etc/fstab; then
    exec_cmd "echo /etc/fstab updated, swap check complete"
  else
    echo "No entry in /etc/fstab, updating ..."
    add_swap_to_fstab="echo $SWAP_FILE_PATH none swap sw 0 0 | tee -a /etc/fstab"
    exec_cmd "$add_swap_to_fstab"
    exec_cmd "echo /etc/fstab updated"
  fi
}

initialize_swap() {
  check_swap
  if [ "$is_swap_required" == true ]; then
    add_swap
  fi
  check_fstab_entry
}

docker_install() {
  echo "Installing docker"

  add-apt-repository -y "deb [arch=arm64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" && apt-get update

  install_docker="apt-get install -q --force-yes -y -o Dpkg::Options::='--force-confnew' docker-ce=$DOCKER_VERSION~ce-0~ubuntu"
  exec_cmd "$install_docker"

  get_static_docker_binary="wget https://download.docker.com/linux/static/stable/aarch64/docker-$DOCKER_VERSION-ce.tgz -P /tmp/docker"
  exec_cmd "$get_static_docker_binary"

  extract_static_docker_binary="tar -xzf /tmp/docker/docker-$DOCKER_VERSION-ce.tgz --directory /opt"
  exec_cmd "$extract_static_docker_binary"

  remove_static_docker_binary='rm -rf /tmp/docker'
  exec_cmd "$remove_static_docker_binary"
}

check_docker_opts() {
  echo "Adding docker options"
  mkdir -p /etc/docker
  echo '{"graph": "/data"}' > /etc/docker/daemon.json
  docker_restart=true
}

add_docker_proxy_envs() {
  mkdir -p /etc/systemd/system/docker.service.d
  proxy_envs="[Service]\nEnvironment="

  if [ ! -z "$SHIPPABLE_HTTP_PROXY" ]; then
    proxy_envs="$proxy_envs \"HTTP_PROXY=$SHIPPABLE_HTTP_PROXY\""
  fi

  if [ ! -z "$SHIPPABLE_HTTPS_PROXY" ]; then
    proxy_envs="$proxy_envs \"HTTPS_PROXY=$SHIPPABLE_HTTPS_PROXY\""
  fi

  if [ ! -z "$SHIPPABLE_NO_PROXY" ]; then
    proxy_envs="$proxy_envs \"NO_PROXY=$SHIPPABLE_NO_PROXY\""
  fi

  echo -e "$proxy_envs" > /etc/systemd/system/docker.service.d/proxy.conf
  # Maybe don't restart always. We seem to restart in check_docker_opts always anyway, so leaving this is a future enhancement.
  docker_restart=true
}

restart_docker_service() {
  echo "checking if docker restart is necessary"

  {
    systemctl is-active docker
  } ||
  {
    docker_restart=true
  }

  if [ "$docker_restart" = true ]; then
    echo "restarting docker service on reset"
    exec_cmd "systemctl daemon-reload"
    exec_cmd "systemctl restart docker"
  else
    echo "docker_restart set to false, not restarting docker daemon"
  fi
}

install_ntp() {
  {
    check_ntp=$(service --status-all 2>&1 | grep ntp)
  } || {
    true
  }

  if [ ! -z "$check_ntp" ]; then
    echo "NTP already installed, skipping."
  else
    echo "Installing NTP"
    exec_cmd "apt-get install -y ntp"
    exec_cmd "service ntp restart"
  fi
}

setup_docker_in_docker() {
  echo "Fetching docker in docker image $SHIPPABLE_DIND_IMAGE"
  docker pull $SHIPPABLE_DIND_IMAGE

  echo "Cleaning up docker in docker containers, if any"
  docker rm -fv $SHIPPABLE_DIND_CONTAINER_NAME || true
}

setup_mounts() {
  rm -rf $SHIPPABLE_RUNTIME_DIR
  mkdir -p $BASE_DIR
  mkdir -p $REQPROC_DIR
  mkdir -p $REQEXEC_DIR
  mkdir -p $REQKICK_DIR
  mkdir -p $BUILD_DIR

  REQPROC_MOUNTS="$REQPROC_MOUNTS \
    -v $BASE_DIR:$BASE_DIR \
    -v /opt/docker/docker:/usr/bin/docker \
    -v /var/run/docker.sock:/var/run/docker.sock"

  if [ "$IS_RESTRICTED_NODE" == "true" ]; then
    DEFAULT_TASK_CONTAINER_MOUNTS="$DEFAULT_TASK_CONTAINER_MOUNTS \
      -v /opt/docker/docker:/usr/bin/docker \
      -v $NODE_SCRIPTS_LOCATION:/var/lib/shippable/node"
  else
    DEFAULT_TASK_CONTAINER_MOUNTS="$DEFAULT_TASK_CONTAINER_MOUNTS \
      -v /opt/docker/docker:/usr/bin/docker \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v $NODE_SCRIPTS_LOCATION:/var/lib/shippable/node"
  fi
}

setup_envs() {
  REQPROC_ENVS="$REQPROC_ENVS \
    -e SHIPPABLE_AMQP_URL=$SHIPPABLE_AMQP_URL \
    -e SHIPPABLE_AMQP_DEFAULT_EXCHANGE=$SHIPPABLE_AMQP_DEFAULT_EXCHANGE \
    -e SHIPPABLE_API_URL=$SHIPPABLE_API_URL \
    -e SHIPPABLE_WWW_URL=$SHIPPABLE_WWW_URL \
    -e LISTEN_QUEUE=$LISTEN_QUEUE \
    -e NODE_ID=$NODE_ID \
    -e RUN_MODE=$RUN_MODE \
    -e SUBSCRIPTION_ID=$SUBSCRIPTION_ID \
    -e NODE_TYPE_CODE=$NODE_TYPE_CODE \
    -e BASE_DIR=$BASE_DIR \
    -e REQPROC_DIR=$REQPROC_DIR \
    -e REQEXEC_DIR=$REQEXEC_DIR \
    -e REQKICK_DIR=$REQKICK_DIR \
    -e BUILD_DIR=$BUILD_DIR \
    -e REQPROC_CONTAINER_NAME=$REQPROC_CONTAINER_NAME \
    -e DEFAULT_TASK_CONTAINER_MOUNTS='$DEFAULT_TASK_CONTAINER_MOUNTS' \
    -e TASK_CONTAINER_COMMAND=$TASK_CONTAINER_COMMAND \
    -e DEFAULT_TASK_CONTAINER_OPTIONS='$DEFAULT_TASK_CONTAINER_OPTIONS' \
    -e EXEC_IMAGE=$EXEC_IMAGE \
    -e SHIPPABLE_DOCKER_VERSION=$DOCKER_VERSION \
    -e IS_DOCKER_LEGACY=false \
    -e SHIPPABLE_NODE_ARCHITECTURE=$NODE_ARCHITECTURE \
    -e SHIPPABLE_NODE_OPERATING_SYSTEM=$NODE_OPERATING_SYSTEM \
    -e SHIPPABLE_RELEASE_VERSION=$SHIPPABLE_RELEASE_VERSION \
    -e SHIPPABLE_RUNTIME_VERSION=$SHIPPABLE_RUNTIME_VERSION \
    -e SHIPPABLE_NODE_SCRIPTS_LOCATION=$NODE_SCRIPTS_LOCATION \
    -e CLUSTER_TYPE_CODE=$CLUSTER_TYPE_CODE \
    -e IS_RESTRICTED_NODE=$IS_RESTRICTED_NODE"

  if [ ! -z "$SHIPPABLE_HTTP_PROXY" ]; then
    REQPROC_ENVS="$REQPROC_ENVS \
      -e http_proxy=$SHIPPABLE_HTTP_PROXY"
  fi

  if [ ! -z "$SHIPPABLE_HTTPS_PROXY" ]; then
    REQPROC_ENVS="$REQPROC_ENVS \
      -e https_proxy=$SHIPPABLE_HTTPS_PROXY"
  fi

  if [ ! -z "$SHIPPABLE_NO_PROXY" ]; then
    REQPROC_ENVS="$REQPROC_ENVS \
      -e no_proxy=$SHIPPABLE_NO_PROXY"
  fi

  if [ "$NO_VERIFY_SSL" == "true" ]; then
    REQPROC_ENVS="$REQPROC_ENVS \
      -e NODE_TLS_REJECT_UNAUTHORIZED=0"
  fi

  if [ "$IS_RESTRICTED_NODE" == "true" ]; then
    REQPROC_ENVS="$REQPROC_ENVS \
      -e SHIPPABLE_DIND_IMAGE=$SHIPPABLE_DIND_IMAGE \
      -e SHIPPABLE_DIND_CONTAINER_NAME=$SHIPPABLE_DIND_CONTAINER_NAME"
  fi
}

setup_opts() {
  REQPROC_OPTS="$REQPROC_OPTS \
    -d \
    --restart=always \
    --name=$REQPROC_CONTAINER_NAME \
    "
}

remove_genexec() {
  __process_marker "Removing exisiting genexec containers..."

  local running_container_ids=$(docker ps -a \
    | grep $EXEC_CONTAINER_NAME_PATTERN \
    | awk '{print $1}')

  if [ ! -z "$running_container_ids" ]; then
    docker rm -f -v $running_container_ids || true
  fi
}

remove_reqProc() {
  __process_marker "Removing exisiting reqProc containers..."

  local running_container_ids=$(docker ps -a \
    | grep $REQPROC_CONTAINER_NAME_PATTERN \
    | awk '{print $1}')

  if [ ! -z "$running_container_ids" ]; then
    docker rm -f -v $running_container_ids || true
  fi
}

remove_reqKick() {
  __process_marker "Removing existing reqKick services..."

  local running_service_names=$(systemctl list-units -a \
    | grep $REQKICK_SERVICE_NAME_PATTERN \
    | awk '{ print $1 }')

  if [ ! -z "$running_service_names" ]; then
    systemctl stop $running_service_names || true
    systemctl disable $running_service_names || true
  fi

  rm -rf $REQKICK_CONFIG_DIR
  rm -f /etc/systemd/system/shippable-reqKick@.service

  systemctl daemon-reload
}

fetch_reports_binary() {
  __process_marker "Installing report parser..."

  local reports_dir="$REPORTS_BINARY_LOCATION_ON_HOST"
  local reports_tar_file="reports.tar.gz"
  rm -rf $reports_dir
  mkdir -p $reports_dir
  pushd $reports_dir
    wget $REPORTS_DOWNLOAD_URL -O $reports_tar_file
    tar -xf $reports_tar_file
    rm -rf $reports_tar_file
  popd
}

boot_reqKick() {
  __process_marker "Booting up reqKick service..."
  local reqKick_tar_file="reqKick.tar.gz"

  rm -rf $REQKICK_DIR
  rm -rf $reqKick_tar_file
  pushd /tmp
    wget $REQKICK_DOWNLOAD_URL -O $reqKick_tar_file
    mkdir -p $REQKICK_DIR
    tar -xzf $reqKick_tar_file -C $REQKICK_DIR --strip-components=1
    rm -rf $reqKick_tar_file
  popd
  pushd $REQKICK_DIR
  npm install

  mkdir -p $REQKICK_CONFIG_DIR

  cp $REQKICK_SERVICE_DIR/shippable-reqKick@.service.template /etc/systemd/system/shippable-reqKick@.service
  chmod 644 /etc/systemd/system/shippable-reqKick@.service

  local reqkick_env_template=$REQKICK_SERVICE_DIR/shippable-reqKick.env.template
  local reqkick_env_file=$REQKICK_CONFIG_DIR/$BASE_UUID.env
  touch $reqkick_env_file
  sed "s#{{STATUS_DIR}}#$STATUS_DIR#g" $reqkick_env_template > $reqkick_env_file
  sed -i "s#{{SCRIPTS_DIR}}#$SCRIPTS_DIR#g" $reqkick_env_file
  sed -i "s#{{REQEXEC_BIN_PATH}}#$REQEXEC_BIN_PATH#g" $reqkick_env_file
  sed -i "s#{{RUN_MODE}}#$RUN_MODE#g" $reqkick_env_file
  sed -i "s#{{NODE_ID}}#$NODE_ID#g" $reqkick_env_file
  sed -i "s#{{SUBSCRIPTION_ID}}#$SUBSCRIPTION_ID#g" $reqkick_env_file
  sed -i "s#{{NODE_TYPE_CODE}}#$NODE_TYPE_CODE#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_NODE_ARCHITECTURE}}#$NODE_ARCHITECTURE#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_NODE_OPERATING_SYSTEM}}#$NODE_OPERATING_SYSTEM#g" $reqkick_env_file
  sed -i "s#{{SHIPPABLE_API_URL}}#$SHIPPABLE_API_URL#g" $reqkick_env_file

  systemctl daemon-reload
  systemctl enable shippable-reqKick@$BASE_UUID.service
  systemctl start shippable-reqKick@$BASE_UUID.service

  {
    echo "Checking if shippable-reqKick@$BASE_UUID.service is active"
    local check_reqKick_is_active=$(systemctl is-active shippable-reqKick@$BASE_UUID.service)
    echo "shippable-reqKick@$BASE_UUID.service is $check_reqKick_is_active"
  } ||
  {
    echo "shippable-reqKick@$BASE_UUID.service failed to start"
    journalctl -n 100 -u shippable-reqKick@$BASE_UUID.service
    popd
    exit 1
  }
  popd
}

boot_reqProc() {
  __process_marker "Booting up reqProc..."
  docker pull $EXEC_IMAGE
  local start_cmd="docker run $REQPROC_OPTS $REQPROC_MOUNTS $REQPROC_ENVS $EXEC_IMAGE"
  eval "$start_cmd"
}

before_exit() {
  echo $1
  echo $2

  echo "Node init script completed"
}

main() {
  trap before_exit EXIT
  exec_grp "create_shippable_dir"

  trap before_exit EXIT
  exec_grp "install_prereqs"

  if [ "$IS_SWAP_ENABLED" == "true" ]; then
    trap before_exit EXIT
    exec_grp "initialize_swap"
  fi

  trap before_exit EXIT
  exec_grp "docker_install"

  trap before_exit EXIT
  exec_grp "check_docker_opts"

  if [ ! -z "$SHIPPABLE_HTTP_PROXY" ] || [ ! -z "$SHIPPABLE_HTTPS_PROXY" ] || [ ! -z "$SHIPPABLE_NO_PROXY" ]; then
    trap before_exit EXIT
    exec_grp "add_docker_proxy_envs"
  fi

  trap before_exit EXIT
  exec_grp "restart_docker_service"

  trap before_exit EXIT
  exec_grp "install_ntp"

  if [ "$IS_RESTRICTED_NODE" == "true" ]; then
    trap before_exit EXIT
    exec_grp "setup_docker_in_docker"
  fi

  trap before_exit EXIT
  exec_grp "setup_mounts"

  trap before_exit EXIT
  exec_grp "setup_envs"

  trap before_exit EXIT
  exec_grp "setup_opts"

  trap before_exit EXIT
  exec_grp "remove_genexec"

  trap before_exit EXIT
  exec_grp "remove_reqProc"

  trap before_exit EXIT
  exec_grp "remove_reqKick"

  trap before_exit EXIT
  exec_grp "fetch_reports_binary"

  trap before_exit EXIT
  exec_grp "boot_reqKick"

  trap before_exit EXIT
  exec_grp "boot_reqProc"
}

main
