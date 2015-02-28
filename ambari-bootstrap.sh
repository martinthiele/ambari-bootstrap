#!/bin/sh -
set -o errexit
set -o nounset
set -o pipefail

# This script provides an easy install of Ambari
# for RedHat Enterpise Linux 6 & CentOS 6
#
# source at http://github.com/seanorama/ambari-bootstrap
#
# Download and run as root or with sudo. Or alternatively:
#   curl -sSL https://s3-us-west-2.amazonaws.com/ambari-bootstrap/ambari-bootstrap-rhel6.sh | sudo -E sh
#

# defaults can be overriden by setting variables in the environment:
#   For example:
#       export java_provider=oracle
#export install_ambari_server=true
#       sh ambari-bootstrap.sh

install_ambari_agent="${install_ambari_agent:-true}"
install_ambari_server="${install_ambari_server:-false}"
java_provider="${java_provider:-open}" # accepts: open, oracle
ambari_server="${ambari_server:-hdp1.hwx.com}"
ambari_version="${ambari_version:-1.7.0}"
ambari_repo="${ambari_repo:-http://public-repo-1.hortonworks.com/ambari/centos6/1.x/updates/${ambari_version}/ambari.repo}"
ambari_aptsource="" # TODO
curl="curl -sSL"

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

if [ ! "$(hostname -f)" ]; then
    printf >&2 'Error: "hostname -f" failed to report an FQDN.\n'
    printf >&2 'The system must report a FQDN in order to use Ambari\n'
    exit 1
fi

if [ "$(id -ru)" != 0 ]; then
    printf >&2 'Error: this installer needs the ability to run commands as root.\n'
    printf >&2 'Install as root or with sudo\n'
    exit 1
fi

case "$(uname -m)" in
    *64)
        ;;
    *)
        printf >&2 'Error: you are not using a 64bit platform.\n'
        printf >&2 'This installer requires a 64bit platforms.\n'
        exit 1
        ;;
esac

## basic platform detection
lsb_dist=''
if [ -z "${lsb_dist}" ] && [ -r /etc/centos-release ]; then
    lsb_dist='centos'
    lsb_dist_release=$(cat /etc/centos-release | sed s/.*release\ // | sed s/\ .*//)
fi
if [ -z "${lsb_dist}" ] && [ -r /etc/redhat-release ]; then
    lsb_dist='redhat'
    lsb_dist_release=$(cat /etc/redhat-release | sed s/.*release\ // | sed s/\ .*//)
fi
lsb_dist="$(echo "${lsb_dist}" | tr '[:upper:]' '[:lower:]')"

if command_exists ambari-agent || command_exists ambari-server; then
    printf >&2 'Warning: "ambari-agent" or "ambari-server" command appears to already exist.\n'
    printf >&2 'Please ensure that you do not already have ambari-agent installed.\n'
    printf >&2 'You may press Ctrl+C now to abort this process and rectify this situation.\n'
    ( set -x; sleep 20 )
fi

my_disable_thp() {
    ( cat > /usr/local/sbin/ambari-thp-disable.sh <<-'EOF'
#!/usr/bin/env bash
# disable transparent huge pages: for Hadoop
thp_disable=true
if [ "${thp_disable}" = true ]; then
    for path in redhat_transparent_hugepage transparent_hugepage; do
        for file in enabled defrag; do
            if test -f /sys/kernel/mm/${path}/${file}; then
                echo never > /sys/kernel/mm/${path}/${file}
            fi
        done
        if test -f /sys/kernel/mm/${path}/khugepaged/defrag; then
            echo no > /sys/kernel/mm/${path}/khugepaged/defrag
        fi
    done
fi
exit 0
EOF
    )
    chmod +x /usr/local/sbin/ambari-thp-disable.sh
    sh /usr/local/sbin/ambari-thp-disable.sh
    printf '\nsh /usr/local/sbin/ambari-thp-disable.sh || /bin/true\n\n' >> /etc/rc.local
}

my_disable_ipv6() {
    mkdir -p /etc/sysctl.d
    ( cat > /etc/sysctl.d/99-hadoop-ipv6.conf <<-'EOF'
## Disabled ipv6
## Provided by Ambari Bootstrap
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    )
    sysctl -e -p /etc/sysctl.d/99-hadoop-ipv6.conf
}

case "${lsb_dist}" in
    centos|redhat)

    case "${lsb_dist_release}" in
        6.*)

        printf "## Info: Installing base packages\n"
        yum repolist ## we want the script to fail if yum isn't working
        yum clean all
        yum install -y curl ntp openssl python zlib wget unzip openssh-clients

        (
            set +o errexit

            printf "## Info: Fixing sudo to not requiretty. This is the default in newer distributions\n"
            printf 'Defaults !requiretty\n' > /etc/sudoers.d/888-dont-requiretty

            setenforce 0
            sed -i 's/\(^[^#]*\)SELINUX=enforcing/\1SELINUX=disabled/' /etc/selinux/config
            sed -i 's/\(^[^#]*\)SELINUX=permissive/\1SELINUX=disabled/' /etc/selinux/config

            printf "## Info: Disabling Transparent Huge Pages\n"
            my_disable_thp

            printf "## Info: Disabling IPv6\n"
            my_disable_ipv6

            printf "## Info: Disabling iptables\n"
            chkconfig iptables off || true
            service iptables stop || true
            chkconfig ip6tables off || true
            service ip6tables stop || true

            printf "## Syncing time via ntpd\n"
            chkconfig ntpd on || true
            ntpd -q || true
            service ntpd restart || true
        )

        if [ "${java_provider}" != 'oracle' ]; then
            printf "## installing java\n"
	        wget --no-check-certificate --no-cookies --header "Cookie: oraclelicense=accept-securebackup-cookie" http://download.oracle.com/otn-pub/java/jdk/7u75-b13/jdk-7u75-linux-x64.rpm -O /tmp/jdk-7u75-linux-x64.rpm
            wget --no-check-certificate --no-cookies --header "Cookie: oraclelicense=accept-securebackup-cookie" http://download.oracle.com/otn-pub/java/jce/7/UnlimitedJCEPolicyJDK7.zip -O /tmp/UnlimitedJCEPolicyJDK7.zip
            yum install -y /tmp/jdk-7u75-linux-x64.rpm
            ln -s /etc/alternatives/java_sdk /usr/java/default
            JAVA_HOME='/usr/java/default'
	        echo 'export JAVA_HOME=/usr/java/default'>/etc/profile.d/java.sh
            echo 'export PATH=$JAVA_HOME/bin:$PATH'>>/etc/profile.d/java.sh
            source /etc/profile.d/java.sh
        fi

        printf "## fetch ambari repo\n"
        ${curl} -o /etc/yum.repos.d/ambari.repo \
            "${ambari_repo}"

        if [ "${install_ambari_agent}" = true ]; then
            printf "## installing ambari-agent\n"
            yum install -y ambari-agent
            sed -i.orig -r 's/^[[:space:]]*hostname=.*/hostname='"${ambari_server}"'/' \
                /etc/ambari-agent/conf/ambari-agent.ini
            ambari-agent start
        fi
        if [ "${install_ambari_server}" = true ]; then
            printf "## install ambari-server\n"
            yum install -y ambari-server
            if [ "${java_provider}" = 'oracle' ]; then
                ambari-server setup -s -j /usr/java/default
            else
                ambari-server setup -j "${JAVA_HOME}" -s
            fi
            ambari-server start
        fi
        printf "## Success! All done.\n"
        exit 0
    ;;
    esac
;;
esac

cat >&2 <<'EOF'

  Your platform is not currently supported by this script or was not
  easily detectable.

  The script currently supports:
    Red Hat Enterprise Linux 6
    CentOS 6

  Please visit the following URL for more detailed installation
  instructions:

    https://docs.hortonworks.com/

EOF
exit 1
