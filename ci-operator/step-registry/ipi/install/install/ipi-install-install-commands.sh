#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-$(date +%s).log"
  sed -i '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/terraform.txt"
  tar -czvf "${ARTIFACT_DIR}/terraform.tar.gz" --remove-files "${dir}/terraform.txt"
  case "${CLUSTER_TYPE}" in
    alibabacloud)
      awk -F'id=' '/alicloud_instance.*Creation complete/ && /master/{ print $2 }' "${dir}/.openshift_install.log" | tr -d ']"' > "${SHARED_DIR}/alibaba-instance-ids.txt";;
  *) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}' to collect machine IDs"
  esac
}

# copy_kubeconfig_minimal runs in the background to monitor kubeconfig file
# As soon as kubeconfig file is available, it copes it to shared dir as kubeconfig-minimal
# Installer might still amend the file. But this is a minimally working kubeconfig and is
# useful for components like observers. In the end, the complete kubeconfig will be copies
# as before.
function copy_kubeconfig_minimal() {
  local dir=${1}
  echo "waiting for ${dir}/auth/kubeconfig to exist"
  while [ ! -s  "${dir}/auth/kubeconfig" ]
  do
    sleep 5
  done
  echo 'kubeconfig received!'

  echo 'waiting for api to be available'
  until env KUBECONFIG="${dir}/auth/kubeconfig" oc get --raw / >/dev/null 2>&1; do
    sleep 5
  done
  echo 'api available'

  echo 'waiting for bootstrap to complete'
  openshift-install --dir="${dir}" wait-for bootstrap-complete &
  wait "$!"
  ret=$?
  if [ $ret -eq 0 ]; then
    echo "Copying kubeconfig to shared dir as kubeconfig-minimal"
    cp "${dir}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig-minimal"
  fi
}

function write_install_status() {
  #Save exit code for must-gather to generate junit
  echo "$ret" >> "${SHARED_DIR}/install-status.txt"
}

function prepare_next_steps() {
  write_install_status
  set +e
  echo "Tear down the backgroup process of copying kube config"
  if [[ -v copy_kubeconfig_pid ]]; then
    if ps -p $copy_kubeconfig_pid &> /dev/null; then
        echo "Kill the backgroup process - $copy_kubeconfig_pid"
        kill $copy_kubeconfig_pid
    else
        echo "The process - $copy_kubeconfig_pid is not existing any more"
    fi
  fi

  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir

  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"

  # For private cluster, the bootstrap address is private, installer cann't gather log-bundle directly even if proxy is set
  # the workaround is gather log-bundle from bastion host
  # copying install folder to bastion host for gathering logs
  publish=$(grep "publish:" ${SHARED_DIR}/install-config.yaml | awk '{print $2}')
  if [[ "${publish}" == "Internal" ]] && [[ ! $(grep "Bootstrap status: complete" "${dir}/.openshift_install.log") ]]; then
    echo "Copying install dir to bastion host."
    echo > "${SHARED_DIR}/REQUIRE_INSTALL_DIR_TO_BASTION"
    if [[ -s "${SHARED_DIR}/bastion_ssh_user" ]] && [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
      bastion_ssh_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
      bastion_public_address=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
      if [[ -n "${bastion_ssh_user}" ]] && [[ -n "${bastion_public_address}" ]]; then

        # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
        # to be able to SSH.
        if ! whoami &> /dev/null; then
          if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
          else
            echo "/etc/passwd is not writeable, and user matching this uid is not found."
            exit 1
          fi
        fi

        # this required rsync daemon is running on ${bastion_public_address} and /tmp dir is configured
        cmd="rsync -rtv ${dir}/ ${bastion_public_address}::tmp/installer/"
        echo "Running Command: ${cmd}"
        eval "${cmd}"
        echo > "${SHARED_DIR}/COPIED_INSTALL_DIR_TO_BASTION"
      else
        echo "ERROR: Can not get bastion user/host, skip to copy install dir."
      fi
    else
      echo "ERROR: File bastion_ssh_user or bastion_public_address is empty or not exist, skip to copy install dir."
    fi
  fi

  # TODO: remove once BZ#1926093 is done and backported
  if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
    cp -t "${SHARED_DIR}" "${dir}"/terraform.*
  fi
}

function inject_promtail_service() {
  GRAFANACLOUND_USERNAME=$(cat /var/run/loki-grafanacloud-secret/client-id)
  export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"
  export PROMTAIL_IMAGE="quay.io/openshift-cr/promtail"
  export PROMTAIL_VERSION="v2.4.1"

  config_dir=/tmp/promtail
  mkdir "${config_dir}"
  cp /var/run/loki-grafanacloud-secret/client-secret "${config_dir}/grafanacom-secrets-password"
  cat >> "${config_dir}/promtail_config.yml" << EOF
clients:
  - backoff_config:
      max_period: 5m
      max_retries: 20
      min_period: 1s
    batchsize: 102400
    batchwait: 10s
    basic_auth:
      username: ${GRAFANACLOUND_USERNAME}
      password_file: /etc/promtail/grafanacom-secrets-password
    timeout: 10s
    url: https://logs-prod3.grafana.net/api/prom/push
positions:
  filename: "/run/promtail/positions.yaml"
scrape_configs:
- job_name: kubernetes-pods-static
  pipeline_stages:
  - cri: {}
  - labeldrop:
    - filename
  - pack:
      labels:
      - namespace
      - pod_name
      - container_name
      - app
  - labelallow:
      - host
      - invoker
  kubernetes_sd_configs:
  - role: pod
  relabel_configs:
  - action: drop
    regex: ''
    source_labels:
    - __meta_kubernetes_pod_uid
  - source_labels:
    - __meta_kubernetes_pod_label_name
    target_label: __service__
  - source_labels:
    - __meta_kubernetes_pod_node_name
    target_label: __host__
  - action: replace
    replacement:
    separator: "/"
    source_labels:
    - __meta_kubernetes_namespace
    - __service__
    target_label: job
  - action: replace
    source_labels:
    - __meta_kubernetes_namespace
    target_label: namespace
  - action: replace
    source_labels:
    - __meta_kubernetes_pod_name
    target_label: pod_name
  - action: replace
    source_labels:
    - __meta_kubernetes_pod_container_name
    target_label: container_name
  - replacement: /var/log/pods/*\$1/*.log
    separator: /
    source_labels:
    - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
    - __meta_kubernetes_pod_container_name
    target_label: __path__
  - action: labelmap
    regex: __meta_kubernetes_pod_label_(.+)
- job_name: journal
  journal:
    path: /var/log/journal
    labels:
      job: systemd-journal
  pipeline_stages:
  - labeldrop:
    - filename
    - stream
  - pack:
      labels:
      - boot_id
      - systemd_unit
  - labelallow:
      - host
      - invoker
  relabel_configs:
  - action: labelmap
    regex: __journal__(.+)
server:
  http_listen_port: 3101
target_config:
  sync_period: 10s
EOF

  cat >> "${config_dir}/fcct.yml" << EOF
variant: fcos
version: 1.1.0
ignition:
  config:
    merge:
      - local: bootstrap_initial.ign
storage:
  files:
    - path: /etc/promtail/grafanacom-secrets-password
      contents:
        local: grafanacom-secrets-password
      mode: 0644
    - path: /etc/promtail/config.yaml
      contents:
        local: promtail_config.yml
      mode: 0644
systemd:
  units:
    - name: promtail.service
      enabled: true
      contents: |
        [Unit]
        Description=promtail
        Wants=network-online.target
        After=network-online.target

        [Service]
        ExecStartPre=/usr/bin/podman create --rm --name=promtail -v /var/log/journal/:/var/log/journal/:z -v /etc/machine-id:/etc/machine-id -v /etc/promtail:/etc/promtail ${PROMTAIL_IMAGE}:${PROMTAIL_VERSION} -config.file=/etc/promtail/config.yaml -client.external-labels=host=%H,invoker='${OPENSHIFT_INSTALL_INVOKER}'
        ExecStart=/usr/bin/podman start -a promtail
        ExecStop=-/usr/bin/podman stop -t 10 promtail
        Restart=always
        RestartSec=60

        [Install]
        WantedBy=multi-user.target
EOF

  cp "${dir}/bootstrap.ign" "${config_dir}/bootstrap_initial.ign"
  # We're using ancient fcct as glibc in installer container is 1.28
  curl -sL https://github.com/coreos/butane/releases/download/v0.7.0/fcct-x86_64-unknown-linux-gnu >/tmp/fcct && chmod ug+x /tmp/fcct
  /tmp/fcct --pretty --strict -d "${config_dir}" "${config_dir}/fcct.yml" > "${dir}/bootstrap.ign"
}

# inject_boot_diagnostics is an azure specific function for enabling boot diagnostics on Azure workers.
function inject_boot_diagnostics() {
  local dir=${1}

  if [ ! -f /tmp/yq ]; then
    curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
  fi

  PATCH="${SHARED_DIR}/machinesets-boot-diagnostics.yaml.patch"
  cat > "${PATCH}" << EOF
spec:
  template:
    spec:
      providerSpec:
        value:
          diagnostics:
            boot:
              storageAccountType: AzureManaged
EOF

  for MACHINESET in $dir/openshift/99_openshift-cluster-api_worker-machineset-*.yaml; do
    /tmp/yq m -x -i "${MACHINESET}" "${PATCH}"
  done
}

# inject_spot_instance_config is an AWS specific option that enables the use of AWS spot instances for worker nodes
function inject_spot_instance_config() {
  local dir=${1}

  if [ ! -f /tmp/yq ]; then
    curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
  fi

  PATCH="${SHARED_DIR}/machinesets-spot-instances.yaml.patch"
  cat > "${PATCH}" << EOF
spec:
  template:
    spec:
      providerSpec:
        value:
          spotMarketOptions: {}
EOF

  for MACHINESET in $dir/openshift/99_openshift-cluster-api_worker-machineset-*.yaml; do
    /tmp/yq m -x -i "${MACHINESET}" "${PATCH}"
    echo "Patched spotMarketOptions into ${MACHINESET}"
  done

  echo "Enabled AWS Spot instances for worker nodes"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov)
    if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
        echo "Setting AWS credential with minimal permision for installer"
        export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission
    else
        export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    fi
    ;;
azure4|azuremag|azure-arm64)
    if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
        echo "Setting AZURE credential with minimal permissions for installer"
        export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure_minimal_permission
    else
        export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
    fi
    ;;
azurestack)
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json
    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
    fi
    ;;
gcp)
    export GOOGLE_CLOUD_KEYFILE_JSON=${CLUSTER_PROFILE_DIR}/gce.json
    if [ -f "${SHARED_DIR}/gcp_min_permissions.json" ]; then
      echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the minimum permissions testing on GCP..."
      export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/gcp_min_permissions.json"
    fi
    ;;
ibmcloud*)
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY
    ;;
alibabacloud) export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini;;
kubevirt) export KUBEVIRT_KUBECONFIG=${HOME}/.kube/config;;
vsphere)
    export VSPHERE_PERSIST_SESSION=true
    declare cloud_where_run
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/vsphere_context.sh"
    if [ "$cloud_where_run" == "IBMC-DEVQE" ]; then
        export SSL_CERT_FILE=/var/run/devqe-secrets/vcenter-certificate
    else
        export SSL_CERT_FILE=/var/run/vsphere8-secrets/vcenter-certificate
    fi
    ;;
openstack-osuosl) ;;
openstack-ppc64le) ;;
openstack*) export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml ;;
ovirt) export OVIRT_CONFIG="${SHARED_DIR}/ovirt-config.yaml" ;;
nutanix) ;;
*) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret" | tee ${ARTIFACT_DIR}/install-config.yaml

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

openshift-install --dir="${dir}" create manifests &
wait "$!"

# Platform specific manifests adjustments
case "${CLUSTER_TYPE}" in
azure4|azure-arm64) inject_boot_diagnostics ${dir} ;;
aws|aws-arm64|aws-usgov)
    if [[ "${SPOT_INSTANCES:-}"  == 'true' ]]; then
      inject_spot_instance_config ${dir}
    fi
    ;;
esac

sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${dir}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)

if [ ! -z "${OPENSHIFT_INSTALL_PROMTAIL_ON_BOOTSTRAP:-}" ]; then
  # Inject promtail in bootstrap.ign
  openshift-install --dir="${dir}" create ignition-configs &
  wait "$!"
  inject_promtail_service
fi

if [ "${OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY:-}" == "true" ]; then
	echo "Cluster will be created with public subnets only"
fi

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
export TF_LOG_PATH="${dir}/terraform.txt"

# Cloud infrastructure problems are common, instead of failing and
# forcing a retest of the entire job, try the installation again if
# the installer exits with 4, indicating an infra problem.
case $JOB_NAME in
  *vsphere*)
    # Do not retry because `cluster destroy` doesn't properly clean up tags on vsphere.
    max=1
    ;;
  *)
    max=3
    ;;
esac
ret=4
tries=1
set +o errexit
backup=/tmp/install-orig
cp -rfpv "$dir" "$backup"
while [ $ret -eq 4 ] && [ $tries -le $max ]
do
  echo "Install attempt $tries of $max"
  if [ $tries -gt 1 ]; then
    write_install_status
    cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
    openshift-install --dir="${dir}" destroy cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
    wait "$!"
    ret="$?"
    if test "${ret}" -ne 0 ; then
      echo "Failed to destroy cluster, aborting retries."
      ret=4
      break
    fi
    if [[ -v copy_kubeconfig_pid ]]; then
      kill $copy_kubeconfig_pid
    fi
    rm -rf "$dir"
    cp -rfpv "$backup" "$dir"
  else
    date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
  fi

  copy_kubeconfig_minimal "${dir}" &
  copy_kubeconfig_pid=$!
  openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"
  ret="$?"
  echo "Installer exit with code $ret"

  tries=$((tries+1))
done
set -o errexit

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "$ret"
