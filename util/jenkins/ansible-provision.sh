#!/usr/bin/env bash

# Ansible provisioning wrapper script that
# assumes the following parameters set
# as environment variables
#
# - github_username
# - server_type
# - instance_type
# - region
# - aws_account
# - keypair
# - ami
# - root_ebs_size
# - security_group
# - dns_zone
# - dns_name
# - environment
# - name_tag
set -x

# Seeing the environment is fine, spewing secrets to the log isn't ok
env | grep -v AWS | grep -v ARN

export PYTHONUNBUFFERED=1
export BOTO_CONFIG=/var/lib/jenkins/${aws_account}.boto

# docker on OS-X includes your Mac's home directory in the socket path
# that SSH/Ansible uses for the control socket, pushing you over
# the 108 character limit.
if [ -f /.dockerenv ]; then
    export ANSIBLE_SSH_CONTROL_PATH=/tmp/%%C
fi

run_ansible() {
  if [[ "$VERBOSE" == "true" ]]; then
    verbose_arg='-vvv'
  else
    verbose_arg=''
  fi

  ansible-playbook $verbose_arg $@
  ret=$?
  if [[ $ret -ne 0 ]]; then
    exit $ret
  fi
}

# Install yq
wget https://github.com/mikefarah/yq/releases/download/v4.27.5/yq_linux_amd64  -O $WORKSPACE/yq && chmod +x $WORKSPACE/yq

function provision_fluentd() {
    echo "#!/usr/bin/env bash"
    echo "set -ex"

    # add tracking log file to host instance
    echo "touch /var/tmp/tracking_logs.log"
    echo "chown www-data:www-data /var/tmp/tracking_logs.log"

    echo "docker pull fluent/fluentd:edge-debian"

    # create fluentd config
    echo "fluentd_config=/var/tmp/fluentd.conf"
    echo "cat << 'EOF' > \$fluentd_config
    <source>
        @type tail
        path /var/tmp/tracking_logs.log
        pos_file /var/tmp/tracking_logs.pos
        rotate_wait 10
        tag *
        <parse>
            @type none
        </parse>
    </source>

    <match **>
        @type stdout
    </match>
EOF"
    echo "docker run -d --name fluentd --network host -v /var/tmp/fluentd.conf:/fluentd/etc/fluentd.conf -v /var/tmp:/var/tmp fluent/fluentd:edge-debian -c /fluentd/etc/fluentd.conf"
}

# This DATE_TIME will be used as instance launch time tag
if [[ ! -n ${sandbox_life//[0-9]/} ]]  && [[ ${sandbox_life} -le 30 ]]; then
    TERMINATION_DATE_TIME=`date +"%m-%d-%Y %T" --date "${sandbox_life=7} days"`
else
   echo "Please enter the valid value for the sandbox_life(between 1 to 30)"
   exit 1
fi


if [[ -z $BUILD_USER ]]; then
    BUILD_USER=jenkins
fi

if [[ -z $BUILD_USER_ID ]]; then
    BUILD_USER_ID=edx-sandbox
fi


if [[ -z $WORKSPACE ]]; then
    dir=$(dirname $0)
    source "$dir/ascii-convert.sh"
    source "$dir/app-container-provisioner.sh"
    source "$dir/demo-course-provisioner.sh"
else
    source "$WORKSPACE/configuration/util/jenkins/ascii-convert.sh"
    source "$WORKSPACE/configuration/util/jenkins/app-container-provisioner.sh"
    source "$WORKSPACE/configuration/util/jenkins/demo-course-provisioner.sh"
fi

if [[ -z $static_url_base ]]; then
  static_url_base="/static"
fi

if [[ -z $github_username  ]]; then
  github_username=$BUILD_USER_ID
fi

# Having access keys OR a boto config allows sandboxes to be built.
if [[ ( -z $AWS_ACCESS_KEY_ID || -z $AWS_SECRET_ACCESS_KEY ) && (! -f $BOTO_CONFIG) ]]; then
  echo "AWS credentials not found for $aws_account"
  exit 1
fi

extra_vars_file="/var/tmp/extra-vars-$$.yml"
sandbox_secure_vars_file="${WORKSPACE}/configuration-secure/ansible/vars/developer-sandbox.yml"
sandbox_internal_vars_file="${WORKSPACE}/configuration-internal/ansible/vars/developer-sandbox.yml"
extra_var_arg="-e@${extra_vars_file}"
program_console="false"

if [[ $edx_internal == "true" ]]; then
    # if this is a an edx server include
    # the secret var file
    extra_var_arg="-e@${sandbox_internal_vars_file} -e@${sandbox_secure_vars_file} -e@${extra_vars_file} -e DECRYPT_CONFIG_PRIVATE_KEY=$WORKSPACE/configuration-secure/ansible/keys/sandbox-remote-config/sandbox/private.key -e ENCRYPTED_CFG_DIR=$WORKSPACE/configuration-internal/sandbox-remote-config/sandbox -e UNENCRYPTED_CFG_DIR=$WORKSPACE"
fi

if [[ -z $region ]]; then
  region="us-east-1"
fi

# edX has reservations for sandboxes in this zone, don't change without updating reservations.
if [[ -z $zone ]]; then
  zone="us-east-1c"
fi

if [[ -z $vpc_subnet_id ]]; then
  vpc_subnet_id="subnet-cd867aba"
fi

if [[ -z $elb ]]; then
  elb="false"
fi

if [[ -z $dns_name ]]; then
  dns_name=${github_username}
fi

if [[ -z $name_tag ]]; then
  name_tag=${github_username}-${environment}
fi

if [[ -z $sandbox_platform_name ]]; then
    sandbox_platform_name=$dns_name
fi

if [[ -z $ami ]]; then
  if [[ $server_type == "full_edx_installation" ]]; then
    ami="ami-0644020c3c81d30ba"
  elif [[ $server_type == "ubuntu_18.04" ]]; then
    ami="ami-07ebfd5b3428b6f4d"
  elif [[ $server_type == "ubuntu_20.04" || $server_type == "full_edx_installation_from_scratch" ]]; then
    ami="ami-089b5711e63812c2a"
    # Ansible will always use Python3 interpreter on Ubuntu 20.04 hosts to execute modules
    extra_var_arg+=' -e ansible_python_interpreter=auto'
  fi
fi

if [[ -z $instance_type ]]; then
  instance_type="r5.large"
fi

if [[ -z $instance_initiated_shutdown_behavior ]]; then
  instance_initiated_shutdown_behavior="terminate"
fi

if [[ -z $enable_newrelic ]]; then
  enable_newrelic="false"
fi

if [[ -z $enable_datadog ]]; then
  enable_datadog="false"
fi

if [[ -z $performance_course ]]; then
  performance_course="false"
fi

if [[ -z $edx_demo_course ]]; then
  edx_demo_course="false"
fi

if [[ -z $enable_automatic_auth_for_testing ]]; then
  enable_automatic_auth_for_testing="false"
fi

if [[ -z $enable_client_profiling ]]; then
  enable_client_profiling="false"
fi

if [[ -z $registrar ]]; then
  registrar="false"
fi

if [[ -z $registrar_version ]]; then
  REGISTRAR_VERSION="master"
fi

if [[ -z $license_manager ]]; then
  license_manager="false"
fi

if [[ -z $license_manager_version ]]; then
  LICENSE_MANAGER_VERSION="master"
fi

if [[ -z $commerce_coordinator ]]; then
  commerce_coordinator="false"
fi

if [[ -z $commerce_coordinator_version ]]; then
  COMMERCE_COORDINATOR_VERSION="master"
fi

if [[ -z $enterprise_catalog_version ]]; then
  ENTERPRISE_CATALOG_VERSION="master"
fi

if [[ -z $learner_portal ]]; then
  learner_portal="false"
fi

if [[ -z $learner_portal_version ]]; then
  LEARNER_PORTAL_VERSION="master"
fi

if [[ -z $prospectus ]]; then
  prospectus="false"
fi

if [[ -z $prospectus_version ]]; then
  PROSPECTUS_VERSION="master"
fi

if [[ -z $prospectus_contentful_environment ]]; then
  prospectus_contentful_environment="master"
fi

if [[ $registrar == 'true' ]]; then
  program_console="true"
fi

if [[ -z authn ]]; then
  authn="false"
fi

if [[ -z $authn_version ]]; then
  AUTHN_MFE_VERSION="master"
fi

if [[ -z $payment ]]; then
  payment="false"
fi

if [[ -z $payment_version ]]; then
  PAYMENT_MFE_VERSION="master"
fi

if [[ -z $learning ]]; then
  learning="false"
fi

if [[ -z $learning_version ]]; then
  LEARNING_MFE_VERSION="master"
fi

if [[ -z $library_authoring ]]; then
  library_authoring="false"
fi

if [[ -z $library_authoring_version ]]; then
  LIBRARY_AUTHORING_MFE_VERSION="master"
fi

if [[ -z $course_authoring ]]; then
  course_authoring="false"
fi

if [[ -z $course_authoring_version ]]; then
  COURSE_AUTHORING_MFE_VERSION="master"
fi

if [[ -z $ora_grading ]]; then
  ora_grading="false"
fi

if [[ -z $ora_grading_version ]]; then
  ORA_GRADING_MFE_VERSION="master"
fi

if [[ -z $course_authoring ]]; then
  course_authoring="false"
fi

if [[ -z $course_authoring_version ]]; then
  COURSE_AUTHORING_MFE_VERSION="master"
fi

if [[ -z $library_authoring ]]; then
  library_authoring="false"
fi

if [[ -z $library_authoring_version ]]; then
  LIBRARY_AUTHORING_MFE_VERSION="master"
fi

# Lowercase the dns name to deal with an ansible bug
dns_name="${dns_name,,}"

deploy_host="${dns_name}.${dns_zone}"
ssh-keygen -f "/var/lib/jenkins/.ssh/known_hosts" -R "$deploy_host"

cd playbooks

cat << EOF > $extra_vars_file
EDX_PLATFORM_VERSION: $edxapp_version
FORUM_VERSION: $forum_version
XQUEUE_VERSION: $xqueue_version
CONFIGURATION_VERSION: $configuration_version
DEMO_VERSION: $demo_version
THEMES_VERSION: $themes_version
REGISTRAR_VERSION: $registrar_version
LEARNER_PORTAL_VERSION: $learner_portal_version
PROGRAM_CONSOLE_VERSION: $program_console_version
PROSPECTUS_VERSION: $prospectus_version

edx_ansible_source_repo: ${configuration_source_repo}
edx_platform_repo: ${edx_platform_repo}

EDXAPP_PLATFORM_NAME: $sandbox_platform_name
SANDBOX_CONFIG: True
CONFIGURE_JWTS: True

EDXAPP_STATIC_URL_BASE: $static_url_base
EDXAPP_LMS_NGINX_PORT: 80
EDXAPP_CMS_NGINX_PORT: 80

ECOMMERCE_NGINX_PORT: 80
ECOMMERCE_SSL_NGINX_PORT: 443
ECOMMERCE_VERSION: $ecommerce_version

CREDENTIALS_NGINX_PORT: 80
CREDENTIALS_SSL_NGINX_PORT: 443
CREDENTIALS_VERSION: $credentials_version

ANALYTICS_API_NGINX_PORT: 80
ANALYTICS_API_SSL_NGINX_PORT: 443
ANALYTICS_API_VERSION: $analytics_api_version

REGISTRAR_NGINX_PORT: 80
REGISTRAR_SSL_NGINX_PORT: 443
REGISTRAR_VERSION: $registrar_version
REGISTRAR_ENABLED: $registrar

LEARNER_PORTAL_NGINX_PORT: 80
LEARNER_PORTAL_SSL_NGINX_PORT: 443
LEARNER_PORTAL_VERSION: $learner_portal_version
LEARNER_PORTAL_ENABLED: $learner_portal
LEARNER_PORTAL_SANDBOX_BUILD: True

PROGRAM_CONSOLE_NGINX_PORT: 80
PROGRAM_CONSOLE_SSL_NGINX_PORT: 443
PROGRAM_CONSOLE_VERSION: $program_console_version
PROGRAM_CONSOLE_ENABLED: $program_console
PROGRAM_CONSOLE_SANDBOX_BUILD: True

PROSPECTUS_NGINX_PORT: 80
PROSPECTUS_SSL_NGINX_PORT: 443
PROSPECTUS_VERSION: $prospectus_version
PROSPECTUS_ENABLED: $prospectus
PROSPECTUS_CONTENTFUL_ENVIRONMENT: $prospectus_contentful_environment
PROSPECTUS_SANDBOX_BUILD: True

AUTHN_NGINX_PORT: 80
AUTHN_SSL_NGINX_PORT: 443
AUTHN_MFE_VERSION: $authn_version
AUTHN_ENABLED: $authn
AUTHN_SANDBOX_BUILD: True

PAYMENT_NGINX_PORT: 80
PAYMENT_SSL_NGINX_PORT: 443
PAYMENT_MFE_VERSION: $payment_version
PAYMENT_MFE_ENABLED: $payment
PAYMENT_SANDBOX_BUILD: True

LICENSE_MANAGER_NGINX_PORT: 80
LICENSE_MANAGER_SSL_NGINX_PORT: 443
LICENSE_MANAGER_VERSION: $license_manager_version
LICENSE_MANAGER_ENABLED: $license_manager
LICENSE_MANAGER_DECRYPT_CONFIG_ENABLED: true
LICENSE_MANAGER_COPY_CONFIG_ENABLED: true

COMMERCE_COORDINATOR_NGINX_PORT: 80
COMMERCE_COORDINATOR_SSL_NGINX_PORT: 443
COMMERCE_COORDINATOR_VERSION: $commerce_coordinator_version
COMMERCE_COORDINATOR_ENABLED: $commerce_coordinator
COMMERCE_COORDINATOR_DECRYPT_CONFIG_ENABLED: true
COMMERCE_COORDINATOR_COPY_CONFIG_ENABLED: true

EDX_EXAMS_NGINX_PORT: 80
EDX_EXAMS_SSL_NGINX_PORT: 443
EDX_EXAMS_DEFAULT_DB_NAME: 'edx_exams'
EDX_EXAMS_MYSQL_USER: 'edx_exams001'
EDX_EXAMS_MYSQL_PASSWORD: 'password'
edx_exams_service_name: 'edx_exams'
EDX_EXAMS_URL_ROOT: https://edx-exams-${deploy_host}
EDX_EXAMS_SOCIAL_AUTH_EDX_OAUTH2_KEY: 'edx_exams-sso-key'
EDX_EXAMS_SOCIAL_AUTH_EDX_OAUTH2_SECRET: 'edx_exams-sso-secret'
EDX_EXAMS_BACKEND_SERVICE_EDX_OAUTH2_KEY: 'edx_exams-backend-service-key'
EDX_EXAMS_BACKEND_SERVICE_EDX_OAUTH2_SECRET: 'edx_exams-backend-service-secret'
EDX_EXAMS_LOGOUT_URL: '{{ EDX_EXAMS_URL_ROOT }}/logout/'
EDX_EXAMS_SERVICE_USER_EMAIL: 'edx_exams_worker@example.com'
EDX_EXAMS_SERVICE_USER_NAME: 'edx_exams_worker'

SUBSCRIPTIONS_DEFAULT_DB_NAME: 'subscriptions'
SUBSCRIPTIONS_MYSQL_USER: 'subscriptions001'
SUBSCRIPTIONS_MYSQL_PASSWORD: 'password'

ENTERPRISE_CATALOG_NGINX_PORT: 80
ENTERPRISE_CATALOG_SSL_NGINX_PORT: 443
ENTERPRISE_CATALOG_VERSION: $enterprise_catalog_version
ENTERPRISE_CATALOG_ENABLED: $enterprise_catalog
ENTERPRISE_CATALOG_DECRYPT_CONFIG_ENABLED: true
ENTERPRISE_CATALOG_COPY_CONFIG_ENABLED: true

DISCOVERY_NGINX_PORT: 80
DISCOVERY_SSL_NGINX_PORT: 443
DISCOVERY_VERSION: $discovery_version
NGINX_SET_X_FORWARDED_HEADERS: True
NGINX_REDIRECT_TO_HTTPS: True
EDX_ANSIBLE_DUMP_VARS: true
migrate_db: "yes"
dns_name: $dns_name
COMMON_HOSTNAME: $dns_name
COMMON_DEPLOY_HOSTNAME: ${deploy_host}
COMMON_DEPLOYMENT: edx
COMMON_ENVIRONMENT: sandbox
COMMON_LMS_BASE_URL: https://${deploy_host}
COMMON_ECOMMERCE_BASE_URL: https://ecommerce-${deploy_host}
nginx_default_sites:
  - lms

LEARNING_NGINX_PORT: 80
LEARNING_SSL_NGINX_PORT: 443
LEARNING_MFE_VERSION: $learning_version
LEARNING_MFE_ENABLED: $learning
LEARNING_SANDBOX_BUILD: True

COURSE_AUTHORING_NGINX_PORT: 80
COURSE_AUTHORING_SSL_NGINX_PORT: 443
COURSE_AUTHORING_MFE_VERSION: $course_authoring_version
COURSE_AUTHORING_MFE_ENABLED: $course_authoring
COURSE_AUTHORING_SANDBOX_BUILD: True

LIBRARY_AUTHORING_NGINX_PORT: 80
LIBRARY_AUTHORING_SSL_NGINX_PORT: 443
LIBRARY_AUTHORING_MFE_VERSION: $library_authoring_version
LIBRARY_AUTHORING_MFE_ENABLED: $library_authoring
LIBRARY_AUTHORING_SANDBOX_BUILD: True

ORA_GRADING_NGINX_PORT: 80
ORA_GRADING_SSL_NGINX_PORT: 443
ORA_GRADING_MFE_VERSION: $ora_grading_version
ORA_GRADING_MFE_ENABLED: $ora_grading
ORA_GRADING_SANDBOX_BUILD: True

COURSE_AUTHORING_NGINX_PORT: 80
COURSE_AUTHORING_SSL_NGINX_PORT: 443
COURSE_AUTHORING_MFE_VERSION: $course_authoring_version
COURSE_AUTHORING_MFE_ENABLED: $course_authoring
COURSE_AUTHORING_SANDBOX_BUILD: True

LIBRARY_AUTHORING_NGINX_PORT: 80
LIBRARY_AUTHORING_SSL_NGINX_PORT: 443
LIBRARY_AUTHORING_MFE_VERSION: $library_authoring_version
LIBRARY_AUTHORING_MFE_ENABLED: $library_authoring
LIBRARY_AUTHORING_SANDBOX_BUILD: True

mysql_server_version_5_7: True

edxapp_container_enabled: $edxapp_container_enabled

# User provided extra vars
$extra_vars
EOF

if [[ $basic_auth == "true" ]]; then
    # vars specific to provisioning added to $extra-vars
    cat << EOF_AUTH >> $extra_vars_file
COMMON_ENABLE_BASIC_AUTH: True
COMMON_HTPASSWD_USER: $auth_user
COMMON_HTPASSWD_PASS: $auth_pass
XQUEUE_BASIC_AUTH_USER: $auth_user
XQUEUE_BASIC_AUTH_PASSWORD: $auth_pass
EOF_AUTH

else
    cat << EOF_AUTH >> $extra_vars_file
COMMON_ENABLE_BASIC_AUTH: False
EOF_AUTH

fi

if [[ $mongo_version == "4.2" ]]; then
    cat << MONGO_VERSION >> $extra_vars_file
MONGO_4_2_ENABLED: True
MONGO_4_4_ENABLED: False
MONGO_VERSION
fi
if [[ $mongo_version == "4.4" ]]; then
    cat << MONGO_VERSION >> $extra_vars_file
MONGO_4_2_ENABLED: False
MONGO_4_4_ENABLED: True
MONGO_VERSION
fi

if [[ -n $nginx_users ]]; then
   cat << EOF_AUTH >> $extra_vars_file
NGINX_USERS: $nginx_users
EOF_AUTH
fi

if [[ $enable_client_profiling == "true" ]]; then
    cat << EOF_PROFILING >> $extra_vars_file
EDXAPP_SESSION_SAVE_EVERY_REQUEST: True
EOF_PROFILING
fi

if [[ $edx_internal == "true" ]]; then
    cat << EOF >> $extra_vars_file
EDXAPP_PREVIEW_LMS_BASE: preview-${deploy_host}
EDXAPP_LMS_BASE: ${deploy_host}
EDXAPP_CMS_BASE: studio-${deploy_host}
EDXAPP_CMS_URL_ROOT: "https://{{ EDXAPP_CMS_BASE }}"
EDXAPP_SITE_NAME: ${deploy_host}
edx_internal: True
COMMON_USER_INFO:
  - name: ${github_username}
    github: true
    type: admin
USER_CMD_PROMPT: '[$name_tag] '
COMMON_ENABLE_NEWRELIC_APP: $enable_newrelic
COMMON_ENABLE_DATADOG: $enable_datadog
COMMON_OAUTH_BASE_URL: "https://${deploy_host}"
FORUM_NEW_RELIC_ENABLE: $enable_newrelic
ENABLE_PERFORMANCE_COURSE: $performance_course
ENABLE_EDX_DEMO_COURSE: $edx_demo_course
EDXAPP_ENABLE_AUTO_AUTH: $enable_automatic_auth_for_testing
EDXAPP_NEWRELIC_LMS_APPNAME: sandbox-${dns_name}-edxapp-lms
EDXAPP_NEWRELIC_CMS_APPNAME: sandbox-${dns_name}-edxapp-cms
EDXAPP_NEWRELIC_WORKERS_APPNAME: sandbox-${dns_name}-edxapp-workers
XQUEUE_NEWRELIC_APPNAME: sandbox-${dns_name}-xqueue
XQUEUE_CONSUMER_NEWRELIC_APPNAME: sandbox-${dns_name}-xqueue_consumer
FORUM_NEW_RELIC_APP_NAME: sandbox-${dns_name}-forums
SANDBOX_USERNAME: $github_username
EDXAPP_ECOMMERCE_PUBLIC_URL_ROOT: "https://ecommerce-${deploy_host}"
EDXAPP_ECOMMERCE_API_URL: "https://ecommerce-${deploy_host}/api/v2"
EDXAPP_DISCOVERY_API_URL: "https://discovery-${deploy_host}/api/v1"
EDXAPP_COURSE_CATALOG_API_URL: "{{ EDXAPP_DISCOVERY_API_URL }}"

ANALYTICS_API_LMS_BASE_URL: "https://{{ EDXAPP_LMS_BASE }}/"

# NOTE: This is the same as DISCOVERY_URL_ROOT below
ECOMMERCE_DISCOVERY_SERVICE_URL: "https://discovery-${deploy_host}"
ECOMMERCE_ECOMMERCE_URL_ROOT: "https://ecommerce-${deploy_host}"
ECOMMERCE_LMS_URL_ROOT: "https://${deploy_host}"
ECOMMERCE_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true
ecommerce_create_demo_data: true

DISCOVERY_URL_ROOT: "https://discovery-${deploy_host}"
DISCOVERY_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true

REGISTRAR_URL_ROOT: "https://registrar-${deploy_host}"
REGISTRAR_API_ROOT: "https://registrar-${deploy_host}/api"
REGISTRAR_DISCOVERY_BASE_URL: "https://discovery-${deploy_host}"
REGISTRAR_LMS_BASE_URL: "https://${deploy_host}"
REGISTRAR_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true

LEARNER_PORTAL_URL_ROOT: "https://learner-portal-${deploy_host}"
LEARNER_PORTAL_DISCOVERY_BASE_URL: "https://discovery-${deploy_host}"
LEARNER_PORTAL_LMS_BASE_URL: "https://${deploy_host}"

PROGRAM_CONSOLE_URL_ROOT: "https://program-console-${deploy_host}"
PROGRAM_CONSOLE_DISCOVERY_BASE_URL: "https://discovery-${deploy_host}"
PROGRAM_CONSOLE_LMS_BASE_URL: "https://${deploy_host}"
PROGRAM_CONSOLE_REGISTRAR_API_BASE_URL: "https://registrar-${deploy_host}/api"

PROSPECTUS_URL_ROOT: "https://prospectus-${deploy_host}"
OAUTH_ID: "{{ PROSPECTUS_OAUTH_ID }}"
OAUTH_SECRET: "{{ PROSPECTUS_OAUTH_SECRET }}"

AUTHN_URL_ROOT: "https://authn-${deploy_host}"
PAYMENT_URL_ROOT: "https://payment-${deploy_host}"
PAYMENT_ECOMMERCE_BASE_URL: "https://ecommerce-${deploy_host}"
PAYMENT_LMS_BASE_URL: "https://${deploy_host}"

credentials_create_demo_data: true
CREDENTIALS_LMS_URL_ROOT: "https://${deploy_host}"
CREDENTIALS_DOMAIN: "credentials-${deploy_host}"
CREDENTIALS_URL_ROOT: "https://{{ CREDENTIALS_DOMAIN }}"
CREDENTIALS_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true
CREDENTIALS_DISCOVERY_API_URL: "{{ DISCOVERY_URL_ROOT }}/api/v1/"

COURSE_AUTHORING_URL_ROOT: "https://course-authoring-${deploy_host}"
LIBRARY_AUTHORING_URL_ROOT: "https://library-authoring-${deploy_host}"

LICENSE_MANAGER_URL_ROOT: "https://license-manager-${deploy_host}"

COMMERCE_COORDINATOR_URL_ROOT: "https://commerce-coordinator-${deploy_host}"

ENTERPRISE_CATALOG_URL_ROOT: "https://enterprise-catalog-${deploy_host}"

EOF
fi

encrypted_config_apps=(edxapp ecommerce ecommerce_worker analytics_api discovery credentials registrar edx_notes_api license_manager commerce_coordinator)

for app in ${encrypted_config_apps[@]}; do
     eval app_decrypt_and_copy_config_enabled=\${${app}_decrypt_and_copy_config_enabled}
     if [[ ${app_decrypt_and_copy_config_enabled} == "true" ]]; then
         cat << EOF >> $extra_vars_file
${app^^}_DECRYPT_CONFIG_ENABLED: true
${app^^}_COPY_CONFIG_ENABLED: true
EOF
     fi
done

if [[ $recreate == "true" ]]; then
    # vars specific to provisioning added to $extra-vars
    cat << EOF >> $extra_vars_file
dns_name: $dns_name
keypair: $keypair
instance_type: $instance_type
security_group: $security_group
ami: $ami
region: $region
zone: $zone
instance_initiated_shutdown_behavior: $instance_initiated_shutdown_behavior
instance_tags:
    environment: $environment
    github_username: $github_username
    Name: $name_tag
    source: jenkins
    owner: $BUILD_USER
    instance_termination_time: $TERMINATION_DATE_TIME
    datadog: monitored
root_ebs_size: $root_ebs_size
name_tag: $name_tag
dns_zone: $dns_zone
elb: $elb
EOF


    if [[ $server_type == "full_edx_installation" ]]; then
        extra_var_arg+=' -e instance_userdata="" -e launch_wait_time=0 -e elb_pre_post=false'
    fi
    # run the tasks to launch an ec2 instance from AMI
    cat $extra_vars_file
    run_ansible edx_provision.yml -i inventory.ini $extra_var_arg --user ubuntu

    if [[ $server_type == "full_edx_installation" ]]; then
        # additional tasks that need to be run if the
        # entire edx stack is brought up from an AMI
        run_ansible redis.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
        run_ansible restart_supervisor.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
    fi
fi

# ansible overrides for master's integration environment setup
if [[ $masters_integration_environment == "true" ]]; then
    cat << EOF >> $extra_vars_file
COMMON_ENABLE_SPLUNKFORWARDER: true
EDXAPP_ENABLE_ENROLLMENT_RESET: true
DISCOVERY_POST_MIGRATE_COMMANDS:
  - command: "./manage.py remove_program_types_from_migrations"
    when: true
  - command: >
      ./manage.py createsuperuser
      --username="admin"
      --email="admin@example.com"
      --no-input
    when: true
registrar_post_migrate_commands:
  - command: >
      ./manage.py createsuperuser
      --username="admin"
      --email="admin@example.com"
      --no-input
    when: true
EOF
fi

declare -A deploy
plays="prospectus edxapp forum ecommerce credentials discovery enterprise_catalog analyticsapi xqueue certs demo testcourses registrar program_console learner_portal"

for play in $plays; do
    deploy[$play]=${!play}
done

# If reconfigure was selected or if starting from an ubuntu 16.04 AMI
# run non-deploy tasks for all plays
if [[ $reconfigure == "true" || $server_type == "full_edx_installation_from_scratch" || $server_type == "ubuntu_20.04" ]]; then
    cat $extra_vars_file
    if [[ $edxapp_container_enabled == "true" ]]; then
      cat << EOF > $WORKSPACE/edxapp_extra_var.yml
edxapp_containerized: true
CAN_GENERATE_NEW_JWT_SIGNATURE: false
EOF
      ansible -i "${deploy_host}," $deploy_host -m include_role -a "name=memcache" -u ubuntu -b
      for playbook in redis $mongo_version; do
          run_ansible $playbook.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
      done
      run_ansible edx_continuous_integration.yml -i "${deploy_host}," $extra_var_arg --user ubuntu --tags "edxlocal"
      # create fluentd container for processing tracking logs
      provision_fluentd_script="/var/tmp/provision-fluentd-script.sh"
      cat << EOF > $provision_fluentd_script
$(provision_fluentd)
EOF
      ansible -c ssh -i "${deploy_host}," $deploy_host -m script -a "${provision_fluentd_script}" -u ubuntu -b

      rm -f "${provision_fluentd_script}"

      # decrypt lms config file
      asym_crypto_yaml decrypt-encrypted-yaml --secrets_file_path $WORKSPACE/configuration-internal/sandbox-remote-config/sandbox/lms.yml --private_key_path $WORKSPACE/configuration-secure/ansible/keys/sandbox-remote-config/sandbox/private.key --outfile_path $WORKSPACE/lms.yml
      # decrypt cms config file
      asym_crypto_yaml decrypt-encrypted-yaml --secrets_file_path $WORKSPACE/configuration-internal/sandbox-remote-config/sandbox/studio.yml --private_key_path $WORKSPACE/configuration-secure/ansible/keys/sandbox-remote-config/sandbox/private.key --outfile_path $WORKSPACE/cms.yml

      sed -i "s/deploy_host/${dns_name}.${dns_zone}/g" $WORKSPACE/lms.yml
      sed -i "s/deploy_host/${dns_name}.${dns_zone}/g" $WORKSPACE/cms.yml

      # Remove exiting private requirements if found
      if [[ -f "$WORKSPACE/dockerfiles-internal/edx-platform-private/private_requirements.txt" ]] ; then
          rm -f $WORKSPACE/dockerfiles-internal/edx-platform-private/private_requirements.txt
      fi

      # Extract private requirements for sandbox
      readarray app_private_requirements < <(cat $WORKSPACE/configuration/playbooks/roles/edxapp/defaults/main.yml | $WORKSPACE/yq e -o=j -I=0 '.EDXAPP_PRIVATE_REQUIREMENTS[]')
      for app_private_requirement in "${app_private_requirements[@]}"; do
          if ! $(echo ${app_private_requirement} | $WORKSPACE/yq '. | has("extra_args")' -) ; then
              req_name=$(echo "${app_private_requirement}" | $WORKSPACE/yq -e '.name' -)
              echo -e "${req_name}" >> $WORKSPACE/dockerfiles-internal/edx-platform-private/private_requirements.txt
          else
              req_name=$(echo "${app_private_requirement}" | $WORKSPACE/yq -e '.name' -)
              req_extra_args=$(echo "${app_private_requirement}" | $WORKSPACE/yq -e '.extra_args' -)
              echo -e "${req_extra_args} ${req_name}" >> $WORKSPACE/dockerfiles-internal/edx-platform-private/private_requirements.txt
          fi
      done

      # copy app config file
      ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=$WORKSPACE/lms.yml dest=/var/tmp/lms.yml" -u ubuntu -b
      ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=$WORKSPACE/cms.yml dest=/var/tmp/cms.yml" -u ubuntu -b
      # copy private Dockerfile and requirements file
      ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=$WORKSPACE/dockerfiles-internal/edx-platform-private dest=/var/tmp/" -u ubuntu -b

      set +x
      app_git_ssh_key="$($WORKSPACE/yq '._local_git_identity' $WORKSPACE/configuration-secure/ansible/vars/developer-sandbox.yml)"

      # specify variable names
      app_hostname="courses"
      app_service_name="lms"
      app_name="edxapp"
      app_repo="edx-platform"
      app_version=$edxapp_version
      app_gunicorn_port=8000
      app_cfg=LMS_CFG
      app_admin_password=SANDBOX_ADMIN_PASSWORD

      app_provision_script="/var/tmp/app-container-provision-script-$$.sh"

      write_app_deployment_script $app_provision_script
      set -x

      ssh \
        -o ControlMaster=auto \
        -o ControlPersist=60s \
        -o "ControlPath=/tmp/${app_service_name}-ssh-%h-%p-%r" \
        -o ServerAliveInterval=30 \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        ubuntu@${deploy_host} "sudo -n -s bash" < $app_provision_script

      rm -f "${app_provision_script}"

      # create CMS provision script
      # specify variable names
      app_hostname="studio"
      app_service_name="cms"
      app_name="edxapp"
      app_repo="edx-platform"
      app_version=$edxapp_version
      app_gunicorn_port=8010
      app_cfg=CMS_CFG

      app_provision_script="/var/tmp/app-container-provision-script-$$.sh"

      write_app_deployment_script $app_provision_script
      set -x

      ssh \
        -o ControlMaster=auto \
        -o ControlPersist=60s \
        -o "ControlPath=/tmp/${app_service_name}-ssh-%h-%p-%r" \
        -o ServerAliveInterval=30 \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        ubuntu@${deploy_host} "sudo -n -s bash" < $app_provision_script

      rm -f "${app_provision_script}"

      # set admin password for demo users
      set +x
      admin_hashed_password="$($WORKSPACE/yq '.SANDBOX_ADMIN_PASSWORD' $WORKSPACE/configuration-internal/ansible/vars/developer-sandbox.yml)"

      # create demo course and test users
      demo_course_provision_script="/var/tmp/demo-provision-script.sh"
      write_demo_course_script $demo_course_provision_script
      set -x

      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${deploy_host} "sudo -n -s bash" < $demo_course_provision_script

      rm -f "${demo_course_provision_script}"

      # edxapp celery workers
      # Export LC_* vars. To be passed to remote instance via SSH where SSH configuration allows LC_* to be accepted as environment variables.
      # LC_* is normally used for passing through locale settings of SSH clients to SSH servers.
      export LC_WORKER_CFG=$(cat <<EOF
  worker_cfg:
    - queue: default
      service_variant: cms
      concurrency: 1
      prefetch_optimization: default
    - queue: high
      service_variant: cms
      concurrency: 1
      prefetch_optimization: default
    - queue: default
      service_variant: lms
      concurrency: 1
      prefetch_optimization: default
    - queue: high
      service_variant: lms
      concurrency: 1
      prefetch_optimization: default
    - queue: high_mem
      service_variant: lms
      concurrency: 1
      prefetch_optimization: default
EOF
  )
      # Remote SSH configuration allows using LC_* (normally for locale variables) to be passed as environment variables to the remote instance.
      export LC_WORKER_OF="edxapp"
      export LC_WORKER_IMAGE_NAME="$LC_WORKER_OF"
      export LC_WORKER_SERVICE_REPO="edx-platform"
      export LC_WORKER_SERVICE_REPO_VERSION="$edxapp_version"
      export LC_SANDBOX_USER="$github_username"
      ssh \
        -o ControlMaster=auto \
        -o ControlPersist=60s \
        -o "ControlPath=/tmp/edxapp-workers-ssh-%h-%p-%r" \
        -o ServerAliveInterval=30 \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        ubuntu@${deploy_host} "sudo -n -s bash" < $WORKSPACE/configuration/util/jenkins/worker-container-provisioner.sh
      unset LC_WORKER_OF
      unset LC_WORKER_IMAGE_NAME
      unset LC_WORKER_SERVICE_REPO
      unset LC_SANDBOX_USER
      run_ansible edx_continuous_integration.yml -i "${deploy_host}," $extra_var_arg -e @$WORKSPACE/edxapp_extra_var.yml --user ubuntu
    else
      cat << EOF > $WORKSPACE/edxapp_extra_var.yml
edxapp_containerized: false
EOF
      run_ansible edx_continuous_integration.yml -i "${deploy_host}," $extra_var_arg -e @$WORKSPACE/edxapp_extra_var.yml --user ubuntu
    fi
fi

if [[ $reconfigure != "true" && $server_type == "full_edx_installation" ]]; then
    # Run deploy tasks for the plays selected
    for i in $plays; do
        if [[ ${deploy[$i]} == "true" ]]; then
            cat $extra_vars_file
            run_ansible ${i}.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
            if [[ ${i} == "edxapp" ]]; then
                run_ansible worker.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
            fi
        fi
    done
fi

# deploy the edx_ansible play
run_ansible edx_ansible.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
cat $sandbox_secure_vars_file $sandbox_internal_vars_file $extra_vars_file | grep -v -E "_version|migrate_db" > ${extra_vars_file}_clean
ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=${extra_vars_file}_clean dest=/edx/app/edx_ansible/server-vars.yml" -u ubuntu -b
ret=$?
if [[ $ret -ne 0 ]]; then
  exit $ret
fi

#if [[ $run_oauth == "true" ]]; then
#    # Setup the OAuth2 clients
#    run_ansible oauth_client_setup.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
#fi

# set the hostname
run_ansible set_hostname.yml -i "${deploy_host}," -e hostname_fqdn=${deploy_host} --user ubuntu

# master's integration environment setup
if [[ $masters_integration_environment == "true" ]]; then
  # vars specific to master's integration environment
  cat << EOF >> $extra_vars_file
username: $registrar_user_email
email: $registrar_user_email
organization_key: $registrar_org_key
registrar_role: "organization_read_write_enrollments"
EOF
  run_ansible masters_sandbox.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
fi

# prospectus sandbox
if [[ $prospectus == "true" ]]; then
   run_ansible prospectus_sandbox.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
fi

if [[ $enable_newrelic == "true" ]]; then
    run_ansible run_role.yml -i "${deploy_host}," -e role=newrelic_infrastructure $extra_var_arg  --user ubuntu
fi

if [[ $edx_exams == 'true' ]]; then
    set +x
    app_git_ssh_key="$($WORKSPACE/yq '._local_git_identity' $WORKSPACE/configuration-secure/ansible/vars/developer-sandbox.yml)"

    app_hostname="edx-exams"
    app_service_name="edx_exams"
    app_name="edx-exams"
    app_repo="edx-exams"
    app_version=$edx_exams_version
    app_gunicorn_port=18740
    app_cfg=EDX_EXAMS_CFG

    app_provision_script="/var/tmp/app-container-provision-script-$$.sh"

    write_app_deployment_script $app_provision_script
    set -x

    sed -i "s/deploy_host/${dns_name}.${dns_zone}/g" $WORKSPACE/configuration-internal/k8s-sandbox-config/$app_service_name.yml
    ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=${WORKSPACE}/configuration-internal/k8s-sandbox-config/${app_service_name}.yml dest=/var/tmp/${app_service_name}.yml" -u ubuntu -b
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${deploy_host} "sudo -n -s bash" < $app_provision_script
    rm -f "${app_provision_script}"
fi

if [[ $subscriptions == 'true' ]]; then
    set +x
    app_git_ssh_key="$($WORKSPACE/yq '._local_git_identity' $WORKSPACE/configuration-secure/ansible/vars/developer-sandbox.yml)"

    app_hostname="subscriptions"
    app_service_name="subscriptions"
    app_name="subscriptions"
    app_repo="subscriptions"
    app_version=$subscriptions_version
    app_gunicorn_port=18750
    app_cfg=SUBSCRIPTIONS_CFG
    app_repo_is_private=true

    app_provision_script="/var/tmp/app-container-provision-script-$$.sh"

    write_app_deployment_script $app_provision_script
    set -x

    sed -i "s/deploy_host/${dns_name}.${dns_zone}/g" $WORKSPACE/configuration-internal/k8s-sandbox-config/$app_service_name.yml
    ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=${WORKSPACE}/configuration-internal/k8s-sandbox-config/${app_service_name}.yml dest=/var/tmp/${app_service_name}.yml" -u ubuntu -b
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${deploy_host} "sudo -n -s bash" < $app_provision_script
    rm -f "${app_provision_script}"
fi

rm -f "$extra_vars_file"
rm -f ${extra_vars_file}_clean
