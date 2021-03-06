# vim: set filetype=sh ts=4 sw=4 et

# sibman_functions.sh - common functions and variables

# Copyright (c) 2015-2017 moocowmoo - moocowmoo@masternode.me

# variables are for putting things in ----------------------------------------

C_RED="\e[31m"
C_YELLOW="\e[33m"
C_GREEN="\e[32m"
C_PURPLE="\e[35m"
C_CYAN="\e[36m"
C_NORM="\e[0m"

SIB_ORG='https://www.sibcoin.org'
DOWNLOAD_PAGE='https://www.sibcoin.org/downloads/'
CHECKSUM_URL='https://www.sibcoin.org/binaries/SHA256SUMS.asc'
SIBCOIND_RUNNING=0
SIBCOIND_RESPONDING=0
SIBMAN_VERSION=$(cat $SIBMAN_GITDIR/VERSION)
SIBMAN_CHECKOUT=$(GIT_DIR=$SIBMAN_GITDIR/.git GIT_WORK_TREE=$SIBMAN_GITDIR git describe --dirty | sed -e "s/^.*-\([0-9]\+-g\)/\1/" )
if [ "$SIBMAN_CHECKOUT" == "v"$SIBMAN_VERSION ]; then
    SIBMAN_CHECKOUT=""
else
    SIBMAN_CHECKOUT=" ("$SIBMAN_CHECKOUT")"
fi

curl_cmd="timeout 7 curl -s -L -A sibman/$SIBMAN_VERSION"
wget_cmd='wget --no-check-certificate -q'


# (mostly) functioning functions -- lots of refactoring to do ----------------

pending(){ [[ $QUIET ]] || ( echo -en "$C_YELLOW$1$C_NORM" && tput el ); }

ok(){ [[ $QUIET ]] || echo -e "$C_GREEN$1$C_NORM" ; }

warn() { [[ $QUIET ]] || echo -e "$C_YELLOW$1$C_NORM" ; }
highlight() { [[ $QUIET ]] || echo -e "$C_PURPLE$1$C_NORM" ; }

err() { [[ $QUIET ]] || echo -e "$C_RED$1$C_NORM" ; }
die() { [[ $QUIET ]] || echo -e "$C_RED$1$C_NORM" ; exit 1 ; }

quit(){ [[ $QUIET ]] || echo -e "$C_GREEN${1:-${messages["exiting"]}}$C_NORM" ; echo ; exit 0 ; }

confirm() { read -r -p "$(echo -e "${1:-${messages["prompt_are_you_sure"]} [y/N]}")" ; [[ ${REPLY:0:1} = [Yy] ]]; }


up()     { echo -e "\e[${1:-1}A"; }
clear_n_lines(){ for n in $(seq ${1:-1}) ; do tput cuu 1; tput el; done ; }


usage(){
    cat<<EOF



    ${messages["usage"]}: ${0##*/} [command]

        ${messages["usage_title"]}

    ${messages["commands"]}

        install

            ${messages["usage_install_description"]}

        update

            ${messages["usage_update_description"]}

        reinstall

            ${messages["usage_reinstall_description"]}

        restart [now]

            ${messages["usage_restart_description"]}
                banlist.dat
                budget.dat
                debug.log
                fee_estimates.dat
                governance.dat
                mncache.dat
                mnpayments.dat
                netfulfilled.dat
                peers.dat

            ${messages["usage_restart_description_now"]}

        status

            ${messages["usage_status_description"]}

        vote

            ${messages["usage_vote_description"]}

        sync

            ${messages["usage_sync_description"]}

        branch

            ${messages["usage_branch_description"]}

        version

            ${messages["usage_version_description"]}

EOF
}

function cache_output(){
    # cached output
    FILE=$1
    # command to cache
    CMD=$2
    OLD=0
    CONTENTS=""
    # is cache older than 1 minute?
    if [ -e $FILE ]; then
        OLD=$(find $FILE -mmin +1 -ls | wc -l)
        CONTENTS=$(cat $FILE);
    fi
    # is cache empty or older than 1 minute? rebuild
    if [ -z "$CONTENTS" ] || [ "$OLD" -gt 0 ]; then
        CONTENTS=$(eval $CMD)
        echo "$CONTENTS" > $FILE
    fi
    echo "$CONTENTS"
}

_check_dependencies() {

    (which python 2>&1) >/dev/null || die "${messages["err_missing_dependency"]} python - sudo apt-get install python"

    DISTRO=$(/usr/bin/env python -mplatform | sed -e 's/.*with-//g')
    if [[ $DISTRO == *"Ubuntu"* ]] || [[ $DISTRO == *"debian"* ]]; then
        PKG_MANAGER=apt-get
    elif [[ $DISTRO == *"centos"* ]]; then
        PKG_MANAGER=yum
    fi

    if [ -z "$PKG_MANAGER" ]; then
        (which apt-get 2>&1) >/dev/null || \
            (which yum 2>&1) >/dev/null || \
            die ${messages["err_no_pkg_mgr"]}

    fi

    (which curl 2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}curl "
    (which perl 2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}perl "
    (which git  2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}git "

    MN_CONF_ENABLED=$( egrep -s '^[^#]*\s*masternode\s*=\s*1' $HOME/.sibcoin{,core}/sibcoin.conf | wc -l 2>/dev/null)
    if [ $MN_CONF_ENABLED -gt 0 ] ; then
        (which unzip 2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}unzip "
        (which virtualenv 2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}python-virtualenv "
    fi

    if [ "$1" == "install" ]; then
        # only require unzip for install
        (which unzip 2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}unzip "
        (which pv   2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}pv "

        # only require python-virtualenv for sentinel
        if [ "$2" == "sentinel" ]; then
            (which virtualenv 2>&1) >/dev/null || MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}python-virtualenv "
        fi
    fi

    # make sure we have the right netcat version (-4,-6 flags)
    if [ ! -z "$(which nc)" ]; then
        (nc -z -4 8.8.8.8 53 2>&1) >/dev/null
        if [ $? -gt 0 ]; then
            MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}netcat6 "
        fi
    else
        MISSING_DEPENDENCIES="${MISSING_DEPENDENCIES}netcat "
    fi

    if [ ! -z "$MISSING_DEPENDENCIES" ]; then
        err "${messages["err_missing_dependency"]} $MISSING_DEPENDENCIES\n"
        sudo $PKG_MANAGER install $MISSING_DEPENDENCIES
    fi


}

# attempt to locate sibcoin-cli executable.
# search current dir, ~/.dash, `which dash-cli` ($PATH), finally recursive
_find_dash_directory() {

    INSTALL_DIR=''

    # sibcoin-cli in PATH

    if [ ! -z $(which sibcoin-cli 2>/dev/null) ] ; then
        INSTALL_DIR=$(readlink -f `which sibcoin-cli`)
        INSTALL_DIR=${INSTALL_DIR%%/sibcoin-cli*};


        #TODO prompt for single-user or multi-user install


        # if copied to /usr/*
        if [[ $INSTALL_DIR =~ \/usr.* ]]; then
            LINK_TO_SYSTEM_DIR=$INSTALL_DIR

            # if not run as root
            if [ $EUID -ne 0 ] ; then
                die "\n${messages["exec_found_in_system_dir"]} $INSTALL_DIR${messages["run_sibman_as_root"]} ${messages["exiting"]}"
            fi
        fi

    # sibcoin-cli not in PATH

        # check current directory
    elif [ -e ./sibcoin-cli ] ; then
        INSTALL_DIR='.' ;

        # check ~/.sibcoin directory
    elif [ -e $HOME/.sibcoin/sibcoin-cli ] ; then
        INSTALL_DIR="$HOME/.sibcoin" ;

    elif [ -e $HOME/sibcoin/sibcoin-cli ] ; then
        INSTALL_DIR="$HOME/.sibcoincore" ;

        # TODO try to find sibcoin-cli with find
#    else
#        CANDIDATES=`find $HOME -name sibcoin-cli`
    fi

    if [ ! -z "$INSTALL_DIR" ]; then
        INSTALL_DIR=$(readlink -f $INSTALL_DIR) 2>/dev/null
        if [ ! -e $INSTALL_DIR ]; then
            echo -e "${C_RED}${messages["sibcli_not_found_in_cwd"]}, ~/sibcoin, or \$PATH. -- ${messages["exiting"]}$C_NORM"
            exit 1
        fi
    else
        echo -e "${C_RED}${messages["sibcli_not_found_in_cwd"]}, ~/sibcoin, or \$PATH. -- ${messages["exiting"]}$C_NORM"
        exit 1
    fi

    SIBCOIN_CLI="$INSTALL_DIR/sibcoin-cli"

    # check INSTALL_DIR has sibcoind and sibcoin-cli
    if [ ! -e $INSTALL_DIR/sibcoind ]; then
        echo -e "${C_RED}${messages["sibcoind_not_found"]} $INSTALL_DIR -- ${messages["exiting"]}$C_NORM"
        exit 1
    fi

    if [ ! -e $SIBCOIN_CLI ]; then
        echo -e "${C_RED}${messages["dashcli_not_found"]} $INSTALL_DIR -- ${messages["exiting"]}$C_NORM"
        exit 1
    fi

}


_check_dashman_updates() {
    GITHUB_SIBMAN_VERSION=$( $curl_cmd https://raw.githubusercontent.com/moocowmoo/dashman/master/VERSION )
    if [ ! -z "$GITHUB_SIBMAN_VERSION" ] && [ "$SIBMAN_VERSION" != "$GITHUB_SIBMAN_VERSION" ]; then
        echo -e "\n"
        echo -e "${C_RED}${0##*/} ${messages["requires_updating"]} $C_GREEN$GITHUB_SIBMAN_VERSION$C_RED\n${messages["requires_sync"]}$C_NORM\n"

        pending "${messages["sync_to_github"]} "

        if confirm " [${C_GREEN}y${C_NORM}/${C_RED}N${C_NORM}] $C_CYAN"; then
            echo $SIBMAN_VERSION > $SIBMAN_GITDIR/PREVIOUS_VERSION
            exec $SIBMAN_GITDIR/${0##*/} sync $COMMAND
        fi
        die "${messages["exiting"]}"
    fi
}

_get_platform_info() {
    PLATFORM=$(uname -m)
    case "$PLATFORM" in
        i[3-6]86)
            BITS=32
            ;;
        x86_64)
            BITS=64
            ;;
        armv7l|aarch64)
            BITS=32
            ARM=1
            BIGARM=$(grep -E "(BCM2709|Freescale i\\.MX6)" /proc/cpuinfo | wc -l)
            ;;
        *)
            err "${messages["err_unknown_platform"]} $PLATFORM"
            err "${messages["err_dashman_supports"]}"
            die "${messages["exiting"]}"
            ;;
    esac
}

_get_versions() {
    _get_platform_info


    local IFS=' '
    DOWNLOAD_FOR='linux'
    if [ ! -z "$BIGARM" ]; then
        DOWNLOAD_FOR='RPi2'
    fi

    CHECKSUM_FILE=$( $curl_cmd $CHECKSUM_URL )
    DOWNLOAD_HTML=$( echo "$CHECKSUM_FILE" )

    read -a DOWNLOAD_URLS <<< $( echo $DOWNLOAD_HTML | sed -e 's/ /\n/g' | grep -v '.asc' | grep $DOWNLOAD_FOR | tr "\n" " ")

    #$(( <-- vim syntax highlighting fix
    LATEST_VERSION=$( echo ${DOWNLOAD_URLS[0]} | perl -ne '/dashcore-([0-9.]+)-/; print $1;' 2>/dev/null )
    if [ -z "$LATEST_VERSION" ]; then
        die "\n${messages["err_could_not_get_version"]} $DOWNLOAD_PAGE -- ${messages["exiting"]}"
    fi

    if [ -z "$SIBCOIN_CLI" ]; then SIBCOIN_CLI='echo'; fi
    CURRENT_VERSION=$( $SIBCOIN_CLI --version | perl -ne '/v([0-9.]+)/; print $1;' 2>/dev/null ) 2>/dev/null
    for url in "${DOWNLOAD_URLS[@]}"
    do
        if [ $DOWNLOAD_FOR == 'linux' ] ; then
            if [[ $url =~ .*linux${BITS}.* ]] ; then
                if [[ ! $url =~ "http" ]] ; then
                    url=$SIB_ORG"/binaries/"$url
                fi
                DOWNLOAD_URL=$url
                DOWNLOAD_FILE=${DOWNLOAD_URL##*/}
            fi
        elif [ $DOWNLOAD_FOR == 'RPi2' ] ; then
            if [[ ! $url =~ "http" ]] ; then
                url=$SIB_ORG"/binaries/"$url
            fi
            DOWNLOAD_URL=$url
            DOWNLOAD_FILE=${DOWNLOAD_URL##*/}
        fi
    done
}


_check_sibcoind_state() {
    _get_sibcoind_proc_status
    SIBCOIND_RUNNING=0
    SIBCOIND_RESPONDING=0
    if [ $SIBCOIND_HASPID -gt 0 ] && [ $SIBCOIND_PID -gt 0 ]; then
        SIBCOIND_RUNNING=1
    fi
    if [ $( $SIBCOIN_CLI help 2>/dev/null | wc -l ) -gt 0 ]; then
        SIBCOIND_RESPONDING=1
    fi
}

restart_sibcoind(){

    if [ $SIBCOIND_RUNNING == 1 ]; then
        pending " --> ${messages["stopping"]} sibcoind. ${messages["please_wait"]}"
        $SIBCOIN_CLI stop 2>&1 >/dev/null
        sleep 10
        killall -9 sibcoind dash-shutoff 2>/dev/null
        ok "${messages["done"]}"
        SIBCOIND_RUNNING=0
    fi

    pending " --> ${messages["deleting_cache_files"]}"

    cd $INSTALL_DIR

    rm -f banlist.dat governance.dat netfulfilled.dat budget.dat debug.log fee_estimates.dat mncache.dat mnpayments.dat peers.dat
    ok "${messages["done"]}"

    pending " --> ${messages["starting_sibcoind"]}"
    $INSTALL_DIR/sibcoind 2>&1 >/dev/null
    SIBCOIND_RUNNING=1
    ok "${messages["done"]}"

    pending " --> ${messages["waiting_for_sibcoind_to_respond"]}"
    echo -en "${C_YELLOW}"
    while [ $SIBCOIND_RUNNING == 1 ] && [ $SIBCOIND_RESPONDING == 0 ]; do
        echo -n "."
        _check_sibcoind_state
        sleep 2
    done
    if [ $SIBCOIND_RUNNING == 0 ]; then
        die "\n - sibcoind unexpectedly quit. ${messages["exiting"]}"
    fi
    ok "${messages["done"]}"
    pending " --> sibcoin-cli getinfo"
    echo
    $SIBCOIN_CLI getinfo
    echo

}


update_sibcoind(){

    if [ $LATEST_VERSION != $CURRENT_VERSION ] || [ ! -z "$REINSTALL" ] ; then
                    

        if [ ! -z "$REINSTALL" ];then
            echo -e ""
            echo -e "$C_GREEN*** ${messages["dash_version"]} $CURRENT_VERSION is up-to-date. ***$C_NORM"
            echo -e ""
            echo -en

            pending "${messages["reinstall_to"]} $INSTALL_DIR$C_NORM?"
        else
            echo -e ""
            echo -e "$C_RED*** ${messages["newer_dash_available"]} ***$C_NORM"
            echo -e ""
            echo -e "${messages["currnt_version"]} $C_RED$CURRENT_VERSION$C_NORM"
            echo -e "${messages["latest_version"]} $C_GREEN$LATEST_VERSION$C_NORM"
            echo -e ""
            if [ -z "$UNATTENDED" ] ; then
                pending "${messages["download"]} $DOWNLOAD_URL\n${messages["and_install_to"]} $INSTALL_DIR?"
            else
                echo -e "$C_GREEN*** UNATTENDED MODE ***$C_NORM"
            fi
        fi


        if [ -z "$UNATTENDED" ] ; then
            if ! confirm " [${C_GREEN}y${C_NORM}/${C_RED}N${C_NORM}] $C_CYAN"; then
                echo -e "${C_RED}${messages["exiting"]}$C_NORM"
                echo ""
                exit 0
            fi
        fi

        # push it ----------------------------------------------------------------

        cd $INSTALL_DIR

        # pull it ----------------------------------------------------------------

        pending " --> ${messages["downloading"]} ${DOWNLOAD_URL}... "
        wget --no-check-certificate -q -r $DOWNLOAD_URL -O $DOWNLOAD_FILE
        wget --no-check-certificate -q -r https://github.com/dashpay/dash/releases/download/v$LATEST_VERSION/SHA256SUMS.asc -O ${DOWNLOAD_FILE}.DIGESTS.txt
        if [ ! -e $DOWNLOAD_FILE ] ; then
            echo -e "${C_RED}${messages["err_downloading_file"]}"
            echo -e "${messages["err_tried_to_get"]} $DOWNLOAD_URL$C_NORM"

            exit 1
        else
            ok "${messages["done"]}"
        fi

        # prove it ---------------------------------------------------------------

        pending " --> ${messages["checksumming"]} ${DOWNLOAD_FILE}... "
        SHA256SUM=$( sha256sum $DOWNLOAD_FILE )
        SHA256PASS=$( grep $SHA256SUM ${DOWNLOAD_FILE}.DIGESTS.txt | wc -l )
        if [ $SHA256PASS -lt 1 ] ; then
            echo -e " ${C_RED} SHA256 ${messages["checksum"]} ${messages["FAILED"]} ${messages["try_again_later"]} ${messages["exiting"]}$C_NORM"
            exit 1
        fi
        ok "${messages["done"]}"

        # produce it -------------------------------------------------------------

        pending " --> ${messages["unpacking"]} ${DOWNLOAD_FILE}... " && \
        tar zxf $DOWNLOAD_FILE && \
        ok "${messages["done"]}"

        # pummel it --------------------------------------------------------------

        if [ $SIBCOIND_RUNNING == 1 ]; then
            pending " --> ${messages["stopping"]} sibcoind. ${messages["please_wait"]}"
            $SIBCOIN_CLI stop >/dev/null 2>&1
            sleep 15
            killall -9 sibcoind dash-shutoff >/dev/null 2>&1
            ok "${messages["done"]}"
        fi

        # prune it ---------------------------------------------------------------

        pending " --> ${messages["removing_old_version"]}"
        rm -rf \
            banlist.dat \
            budget.dat \
            debug.log \
            fee_estimates.dat \
            governance.dat \
            mncache.dat \
            mnpayments.dat \
            netfulfilled.dat \
            peers.dat \
            sibcoind \
            sibcoind-$CURRENT_VERSION \
            dash-qt \
            dash-qt-$CURRENT_VERSION \
            sibcoin-cli \
            sibcoin-cli-$CURRENT_VERSION \
            dashcore-${CURRENT_VERSION}.gz*
        ok "${messages["done"]}"

        # place it ---------------------------------------------------------------

        mv dashcore-0.12.2/bin/sibcoind sibcoind-$LATEST_VERSION
        mv dashcore-0.12.2/bin/sibcoin-cli sibcoin-cli-$LATEST_VERSION
        if [ $PLATFORM != 'armv7l' ];then
            mv dashcore-0.12.2/bin/dash-qt dash-qt-$LATEST_VERSION
        fi
        ln -s sibcoind-$LATEST_VERSION sibcoind
        ln -s sibcoin-cli-$LATEST_VERSION sibcoin-cli
        if [ $PLATFORM != 'armv7l' ];then
            ln -s dash-qt-$LATEST_VERSION dash-qt
        fi

        # permission it ----------------------------------------------------------

        if [ ! -z "$SUDO_USER" ]; then
            chown -h $SUDO_USER:$SUDO_USER {$DOWNLOAD_FILE,${DOWNLOAD_FILE}.DIGESTS.txt,sibcoin-cli,sibcoind,dash-qt,dash*$LATEST_VERSION}
        fi

        # purge it ---------------------------------------------------------------

        rm -rf dash-0.12.0
        rm -rf dashcore-0.12.1*
        rm -rf dashcore-0.12.2

        # punch it ---------------------------------------------------------------

        pending " --> ${messages["launching"]} sibcoind... "
        touch $INSTALL_DIR/sibcoind.pid
        $INSTALL_DIR/sibcoind > /dev/null
        ok "${messages["done"]}"

        # probe it ---------------------------------------------------------------

        pending " --> ${messages["waiting_for_sibcoind_to_respond"]}"
        echo -en "${C_YELLOW}"
        SIBCOIND_RUNNING=1
        while [ $SIBCOIND_RUNNING == 1 ] && [ $SIBCOIND_RESPONDING == 0 ]; do
            echo -n "."
            _check_sibcoind_state
            sleep 1
        done
        if [ $SIBCOIND_RUNNING == 0 ]; then
            die "\n - sibcoind unexpectedly quit. ${messages["exiting"]}"
        fi
        ok "${messages["done"]}"

        # poll it ----------------------------------------------------------------

        MN_CONF_ENABLED=$( egrep -s '^[^#]*\s*masternode\s*=\s*1' $INSTALL_DIR/dash.conf | wc -l 2>/dev/null)
        if [ $MN_CONF_ENABLED -gt 0 ] ; then

            # populate it --------------------------------------------------------

            pending " --> updating sentinel... "
            cd sentinel
            git remote update >/dev/null 2>&1 
            git reset -q --hard origin/master
            cd ..
            ok "${messages["done"]}"

            # patch it -----------------------------------------------------------

            pending "  --> updating crontab... "
            (crontab -l 2>/dev/null | grep -v sentinel.py ; echo "* * * * * cd $INSTALL_DIR/sentinel && venv/bin/python bin/sentinel.py  2>&1 >> sentinel-cron.log") | crontab -
            ok "${messages["done"]}"

        fi

        # poll it ----------------------------------------------------------------

        LAST_VERSION=$CURRENT_VERSION

        _get_versions

        # pass or punt -----------------------------------------------------------

        if [ $LATEST_VERSION == $CURRENT_VERSION ]; then
            echo -e ""
            echo -e "${C_GREEN}${messages["successfully_upgraded"]} ${LATEST_VERSION}$C_NORM"
            echo -e ""
            echo -e "${C_GREEN}${messages["installed_in"]} ${INSTALL_DIR}$C_NORM"
            echo -e ""
            ls -l --color {$DOWNLOAD_FILE,${DOWNLOAD_FILE}.DIGESTS.txt,sibcoin-cli,sibcoind,dash-qt,dash*$LATEST_VERSION}
            echo -e ""

            quit
        else
            echo -e "${C_RED}${messages["dash_version"]} $CURRENT_VERSION ${messages["is_not_uptodate"]} ($LATEST_VERSION) ${messages["exiting"]}$C_NORM"
        fi

    else
        echo -e ""
        echo -e "${C_GREEN}${messages["dash_version"]} $CURRENT_VERSION ${messages["is_uptodate"]} ${messages["exiting"]}$C_NORM"
    fi

    exit 0
}

install_sibcoind(){

    INSTALL_DIR=$HOME/.dashcore
    SIBCOIN_CLI="$INSTALL_DIR/sibcoin-cli"

    if [ -e $INSTALL_DIR ] ; then
        die "\n - ${messages["preexisting_dir"]} $INSTALL_DIR ${messages["found"]} ${messages["run_reinstall"]} ${messages["exiting"]}"
    fi

    if [ -z "$UNATTENDED" ] ; then
        pending "${messages["download"]} $DOWNLOAD_URL\n${messages["and_install_to"]} $INSTALL_DIR?"
    else
        echo -e "$C_GREEN*** UNATTENDED MODE ***$C_NORM"
    fi

    if [ -z "$UNATTENDED" ] ; then
        if ! confirm " [${C_GREEN}y${C_NORM}/${C_RED}N${C_NORM}] $C_CYAN"; then
            echo -e "${C_RED}${messages["exiting"]}$C_NORM"
            echo ""
            exit 0
        fi
    fi

    get_public_ips
    # prompt for ipv4 or ipv6 install
#    if [ ! -z "$PUBLIC_IPV6" ] && [ ! -z "$PUBLIC_IPV4" ]; then
#        pending " --- " ; echo
#        pending " - ${messages["prompt_ipv4_ipv6"]}"
#        if confirm " [${C_GREEN}y${C_NORM}/${C_RED}N${C_NORM}] $C_CYAN"; then
#            USE_IPV6=1
#        fi
#    fi

    echo ""

    # prep it ----------------------------------------------------------------

    mkdir -p $INSTALL_DIR

    if [ ! -e $INSTALL_DIR/dash.conf ] ; then
        pending " --> ${messages["creating"]} dash.conf... "

        IPADDR=$PUBLIC_IPV4
#        if [ ! -z "$USE_IPV6" ]; then
#            IPADDR='['$PUBLIC_IPV6']'
#        fi
        RPCUSER=`echo $(dd if=/dev/urandom bs=128 count=1 2>/dev/null) | sha256sum | awk '{print $1}'`
        RPCPASS=`echo $(dd if=/dev/urandom bs=128 count=1 2>/dev/null) | sha256sum | awk '{print $1}'`
        while read; do
            eval echo "$REPLY"
        done < $SIBMAN_GITDIR/.dash.conf.template > $INSTALL_DIR/dash.conf
        ok "${messages["done"]}"
    fi

    # push it ----------------------------------------------------------------

    cd $INSTALL_DIR

    # pull it ----------------------------------------------------------------

    pending " --> ${messages["downloading"]} ${DOWNLOAD_URL}... "
    tput sc
    echo -e "$C_CYAN"
    $wget_cmd -O - $DOWNLOAD_URL | pv -trep -s27M -w80 -N wallet > $DOWNLOAD_FILE
    $wget_cmd -O - https://github.com/dashpay/dash/releases/download/v$LATEST_VERSION/SHA256SUMS.asc | pv -trep -w80 -N checksums > ${DOWNLOAD_FILE}.DIGESTS.txt
    echo -ne "$C_NORM"
    clear_n_lines 2
    tput rc
    clear_n_lines 3
    if [ ! -e $DOWNLOAD_FILE ] ; then
        echo -e "${C_RED}error ${messages["downloading"]} file"
        echo -e "tried to get $DOWNLOAD_URL$C_NORM"
        exit 1
    else
        ok ${messages["done"]}
    fi

    # prove it ---------------------------------------------------------------

    pending " --> ${messages["checksumming"]} ${DOWNLOAD_FILE}... "
    SHA256SUM=$( sha256sum $DOWNLOAD_FILE )
    #MD5SUM=$( md5sum $DOWNLOAD_FILE )
    SHA256PASS=$( grep $SHA256SUM ${DOWNLOAD_FILE}.DIGESTS.txt | wc -l )
    #MD5SUMPASS=$( grep $MD5SUM ${DOWNLOAD_FILE}.DIGESTS.txt | wc -l )
    if [ $SHA256PASS -lt 1 ] ; then
        echo -e " ${C_RED} SHA256 ${messages["checksum"]} ${messages["FAILED"]} ${messages["try_again_later"]} ${messages["exiting"]}$C_NORM"

        exit 1
    fi
    #if [ $MD5SUMPASS -lt 1 ] ; then
    #    echo -e " ${C_RED} MD5 ${messages["checksum"]} ${messages["FAILED"]} ${messages["try_again_later"]} ${messages["exiting"]}$C_NORM"
    #    exit 1
    #fi
    ok "${messages["done"]}"

    # produce it -------------------------------------------------------------

    pending " --> ${messages["unpacking"]} ${DOWNLOAD_FILE}... " && \
    tar zxf $DOWNLOAD_FILE && \
    ok "${messages["done"]}"

    # pummel it --------------------------------------------------------------

#    if [ $SIBCOIND_RUNNING == 1 ]; then
#        pending " --> ${messages["stopping"]} sibcoind. ${messages["please_wait"]}"
#        $SIBCOIN_CLI stop >/dev/null 2>&1
#        sleep 15
#        killall -9 sibcoind dash-shutoff >/dev/null 2>&1
#        ok "${messages["done"]}"
#    fi

    # prune it ---------------------------------------------------------------

#    pending " --> ${messages["removing_old_version"]}"
#    rm -f \
#        banlist.dat \
#        budget.dat \
#        debug.log \
#        fee_estimates.dat \
#        governance.dat \
#        mncache.dat \
#        mnpayments.dat \
#        netfulfilled.dat \
#        peers.dat \
#        sibcoind \
#        sibcoind-$CURRENT_VERSION \
#        dash-qt \
#        dash-qt-$CURRENT_VERSION \
#        sibcoin-cli \
#        sibcoin-cli-$CURRENT_VERSION
#    ok "${messages["done"]}"

    # place it ---------------------------------------------------------------

    mv dashcore-0.12.2/bin/sibcoind sibcoind-$LATEST_VERSION
    mv dashcore-0.12.2/bin/sibcoin-cli sibcoin-cli-$LATEST_VERSION
    if [ $PLATFORM != 'armv7l' ];then
        mv dashcore-0.12.2/bin/dash-qt dash-qt-$LATEST_VERSION
    fi
    ln -s sibcoind-$LATEST_VERSION sibcoind
    ln -s sibcoin-cli-$LATEST_VERSION sibcoin-cli
    if [ $PLATFORM != 'armv7l' ];then
        ln -s dash-qt-$LATEST_VERSION dash-qt
    fi

    # permission it ----------------------------------------------------------

    if [ ! -z "$SUDO_USER" ]; then
        chown -h $SUDO_USER:$SUDO_USER {$DOWNLOAD_FILE,${DOWNLOAD_FILE}.DIGESTS.txt,sibcoin-cli,sibcoind,dash-qt,dash*$LATEST_VERSION}
    fi

    # purge it ---------------------------------------------------------------

    rm -rf dash-0.12.0

    # preload it -------------------------------------------------------------

    pending " --> ${messages["bootstrapping"]} blockchain. ${messages["please_wait"]}\n"
    pending "  --> ${messages["downloading"]} bootstrap... "
    BOOSTRAP_LINKS='https://raw.githubusercontent.com/UdjinM6/dash-bootstrap/master/links-mainnet.md'
    wget --no-check-certificate -q $BOOSTRAP_LINKS -O - | grep 'bootstrap\.dat\.zip' | grep 'sha256\.txt' > links.md
    MAINNET_BOOTSTRAP_FILE_1=$(head -1 links.md | awk '{print $9}' | sed 's/.*\(http.*\.zip\).*/\1/')
    MAINNET_BOOTSTRAP_FILE_1_SIZE=$(head -1 links.md | awk '{print $10}' | sed 's/[()]//g')
    MAINNET_BOOTSTRAP_FILE_1_SIZE_M=$(( $(echo $MAINNET_BOOTSTRAP_FILE_1_SIZE | sed -e 's/[^0-9]//g') * 99 ))
    MAINNET_BOOTSTRAP_FILE_2=$(head -3 links.md | tail -1 | awk '{print $9}' | sed 's/.*\(http.*\.zip\).*/\1/')
    pending " $MAINNET_BOOTSTRAP_FILE_1_SIZE... "
    tput sc
    echo -e "$C_CYAN"
    $wget_cmd -O - $MAINNET_BOOTSTRAP_FILE_1 | pv -trepa -s${MAINNET_BOOTSTRAP_FILE_1_SIZE_M}m -w80 -N bootstrap > ${MAINNET_BOOTSTRAP_FILE_1##*/}
    MAINNET_BOOTSTRAP_FILE=${MAINNET_BOOTSTRAP_FILE_1##*/}
    if [ ! -s $MAINNET_BOOTSTRAP_FILE ]; then
        rm $MAINNET_BOOTSTRAP_FILE
        $wget_cmd -O - $MAINNET_BOOTSTRAP_FILE_2 | pv -trepa -s${MAINNET_BOOTSTRAP_FILE_1_SIZE_M}m -w80 -N bootstrap > ${MAINNET_BOOTSTRAP_FILE_2##*/}
        MAINNET_BOOTSTRAP_FILE=${MAINNET_BOOTSTRAP_FILE_2##*/}
    fi
    echo -ne "$C_NORM"
    clear_n_lines 1
    tput rc
    tput cuu 2
    if [ ! -s $MAINNET_BOOTSTRAP_FILE ]; then
        # TODO i18n
        err " bootstrap download failed. skipping."
    else
        ok "${messages["done"]}"
        pending "  --> ${messages["unzipping"]} bootstrap... "
        tput sc
        echo -e "$C_CYAN"
        BOOTSTRAP_SIZE_M=$(( $(unzip -l ${MAINNET_BOOTSTRAP_FILE##*/} | grep -v zip | grep bootstrap.dat | awk '{print $1}') / 1024 / 1024 ))
        unzip -qp ${MAINNET_BOOTSTRAP_FILE##*/} | pv -trep -s${BOOTSTRAP_SIZE_M}m -w80 -N 'unpacking bootstrap' > bootstrap.dat
        echo -ne "$C_NORM"
        clear_n_lines 1
        tput rc
        tput cuu 1
        ok "${messages["done"]}"
        rm -f links.md bootstrap.dat*.zip
    fi

    # punch it ---------------------------------------------------------------

    pending " --> ${messages["launching"]} sibcoind... "
    $INSTALL_DIR/sibcoind > /dev/null
    SIBCOIND_RUNNING=1
    ok "${messages["done"]}"

    # probe it ---------------------------------------------------------------

    pending " --> ${messages["waiting_for_sibcoind_to_respond"]}"
    echo -en "${C_YELLOW}"
    while [ $SIBCOIND_RUNNING == 1 ] && [ $SIBCOIND_RESPONDING == 0 ]; do
        echo -n "."
        _check_sibcoind_state
        sleep 2
    done
    if [ $SIBCOIND_RUNNING == 0 ]; then
        die "\n - sibcoind unexpectedly quit. ${messages["exiting"]}"
    fi
    ok "${messages["done"]}"

    # path it ----------------------------------------------------------------

    pending " --> adding $INSTALL_DIR PATH to ~/.bash_aliases ... "
    if [ ! -f ~/.bash_aliases ]; then touch ~/.bash_aliases ; fi
    sed -i.bak -e '/dashman_env/d' ~/.bash_aliases
    echo "export PATH=$INSTALL_DIR:\$PATH ; # dashman_env" >> ~/.bash_aliases
    ok "${messages["done"]}"


    # poll it ----------------------------------------------------------------

    _get_versions

    # pass or punt -----------------------------------------------------------

    if [ $LATEST_VERSION == $CURRENT_VERSION ]; then
        echo -e ""
        echo -e "${C_GREEN}dash ${LATEST_VERSION} ${messages["successfully_installed"]}$C_NORM"

        echo -e ""
        echo -e "${C_GREEN}${messages["installed_in"]} ${INSTALL_DIR}$C_NORM"
        echo -e ""
        ls -l --color {$DOWNLOAD_FILE,${DOWNLOAD_FILE}.DIGESTS.txt,sibcoin-cli,sibcoind,dash-qt,dash*$LATEST_VERSION}
        echo -e ""

        if [ ! -z "$SUDO_USER" ]; then
            echo -e "${C_GREEN}Symlinked to: ${LINK_TO_SYSTEM_DIR}$C_NORM"
            echo -e ""
            ls -l --color $LINK_TO_SYSTEM_DIR/{sibcoind,sibcoin-cli}
            echo -e ""
        fi

    else
        echo -e "${C_RED}${messages["dash_version"]} $CURRENT_VERSION ${messages["is_not_uptodate"]} ($LATEST_VERSION) ${messages["exiting"]}$C_NORM"
        exit 1
    fi

}

_get_sibcoind_proc_status(){
    SIBCOIND_HASPID=0
    if [ -e $INSTALL_DIR/sibcoind.pid ] ; then
        SIBCOIND_HASPID=`ps --no-header \`cat $INSTALL_DIR/sibcoind.pid 2>/dev/null\` | wc -l`;
    else
        SIBCOIND_HASPID=$(pidof sibcoind)
        if [ $? -gt 0 ]; then
            SIBCOIND_HASPID=0
        fi
    fi
    SIBCOIND_PID=$(pidof sibcoind)
}

get_sibcoind_status(){

    _get_sibcoind_proc_status

    SIBCOIND_UPTIME=$(ps -p $SIBCOIND_PID -o etime= 2>/dev/null | sed -e 's/ //g')
    SIBCOIND_UPTIME_TIMES=$(echo "$SIBCOIND_UPTIME" | perl -ne 'chomp ; s/-/:/ ; print join ":", reverse split /:/' 2>/dev/null )
    SIBCOIND_UPTIME_SECS=$( echo "$SIBCOIND_UPTIME_TIMES" | cut -d: -f1 )
    SIBCOIND_UPTIME_MINS=$( echo "$SIBCOIND_UPTIME_TIMES" | cut -d: -f2 )
    SIBCOIND_UPTIME_HOURS=$( echo "$SIBCOIND_UPTIME_TIMES" | cut -d: -f3 )
    SIBCOIND_UPTIME_DAYS=$( echo "$SIBCOIND_UPTIME_TIMES" | cut -d: -f4 )
    if [ -z "$SIBCOIND_UPTIME_DAYS" ]; then SIBCOIND_UPTIME_DAYS=0 ; fi
    if [ -z "$SIBCOIND_UPTIME_HOURS" ]; then SIBCOIND_UPTIME_HOURS=0 ; fi
    if [ -z "$SIBCOIND_UPTIME_MINS" ]; then SIBCOIND_UPTIME_MINS=0 ; fi
    if [ -z "$SIBCOIND_UPTIME_SECS" ]; then SIBCOIND_UPTIME_SECS=0 ; fi

    SIBCOIND_LISTENING=`netstat -nat | grep LIST | grep 9999 | wc -l`;
    SIBCOIND_CONNECTIONS=`netstat -nat | grep ESTA | grep 9999 | wc -l`;
    SIBCOIND_CURRENT_BLOCK=`$SIBCOIN_CLI getblockcount 2>/dev/null`
    if [ -z "$SIBCOIND_CURRENT_BLOCK" ] ; then SIBCOIND_CURRENT_BLOCK=0 ; fi
    SIBCOIND_GETINFO=`$SIBCOIN_CLI getinfo 2>/dev/null`;
    SIBCOIND_DIFFICULTY=$(echo "$SIBCOIND_GETINFO" | grep difficulty | awk '{print $2}' | sed -e 's/[",]//g')

    WEB_BLOCK_COUNT_CHAINZ=`$curl_cmd https://chainz.cryptoid.info/dash/api.dws?q=getblockcount`;
    if [ -z "$WEB_BLOCK_COUNT_CHAINZ" ]; then
        WEB_BLOCK_COUNT_CHAINZ=0
    fi

    WEB_BLOCK_COUNT_DQA=`$curl_cmd https://explorer.dash.org/chain/Dash/q/getblockcount`;
    if [ -z "$WEB_BLOCK_COUNT_DQA" ]; then
        WEB_BLOCK_COUNT_DQA=0
    fi

    WEB_SIBWHALE=`$curl_cmd https://www.dashcentral.org/api/v1/public`;
    if [ -z "$WEB_SIBWHALE" ]; then
        sleep 3
        WEB_SIBWHALE=`$curl_cmd https://www.dashcentral.org/api/v1/public`;
    fi

    WEB_SIBWHALE_JSON_TEXT=$(echo $WEB_SIBWHALE | python -m json.tool)
    WEB_BLOCK_COUNT_DWHALE=$(echo "$WEB_SIBWHALE_JSON_TEXT" | grep consensus_blockheight | awk '{print $2}' | sed -e 's/[",]//g')

    WEB_ME=`$curl_cmd https://www.masternode.me/data/block_state.txt 2>/dev/null`;
    if [[ $(echo "$WEB_ME" | grep cloudflare | wc -l) -gt 0 ]]; then
        WEB_ME=`$curl_cmd https://stats.masternode.me/data/block_state.txt 2>/dev/null`;
    fi
    WEB_BLOCK_COUNT_ME=$( echo $WEB_ME | awk '{print $1}')
    WEB_ME_FORK_DETECT=$( echo $WEB_ME | grep 'fork detected' | wc -l )

    WEB_ME=$(echo $WEB_ME | sed -s "s/no forks detected/${messages["no_forks_detected"]}/")

    CHECK_SYNC_AGAINST_HEIGHT=$(echo "$WEB_BLOCK_COUNT_CHAINZ $WEB_BLOCK_COUNT_ME $WEB_BLOCK_COUNT_DQA $WEB_BLOCK_COUNT_DWHALE" | tr " " "\n" | sort -rn | head -1)

    SIBCOIND_SYNCED=0
    if [ $CHECK_SYNC_AGAINST_HEIGHT -ge $SIBCOIND_CURRENT_BLOCK ] && [ $(($CHECK_SYNC_AGAINST_HEIGHT - 5)) -lt $SIBCOIND_CURRENT_BLOCK ];then
        SIBCOIND_SYNCED=1
    fi

    SIBCOIND_CONNECTED=0
    if [ $SIBCOIND_CONNECTIONS -gt 0 ]; then SIBCOIND_CONNECTED=1 ; fi

    SIBCOIND_UP_TO_DATE=0
    if [ $LATEST_VERSION == $CURRENT_VERSION ]; then
        SIBCOIND_UP_TO_DATE=1
    fi

    get_public_ips

    MASTERNODE_BIND_IP=$PUBLIC_IPV4
    PUBLIC_PORT_CLOSED=$( timeout 2 nc -4 -z $PUBLIC_IPV4 9999 2>&1 >/dev/null; echo $? )
#    if [ $PUBLIC_PORT_CLOSED -ne 0 ] && [ ! -z "$PUBLIC_IPV6" ]; then
#        PUBLIC_PORT_CLOSED=$( timeout 2 nc -6 -z $PUBLIC_IPV6 9999 2>&1 >/dev/null; echo $? )
#        if [ $PUBLIC_PORT_CLOSED -eq 0 ]; then
#            MASTERNODE_BIND_IP=$PUBLIC_IPV6
#        fi
#    else
#        MASTERNODE_BIND_IP=$PUBLIC_IPV4
#    fi

    # masternode (remote!) specific

    MN_CONF_ENABLED=$( egrep -s '^[^#]*\s*masternode\s*=\s*1' $HOME/.dash{,core}/dash.conf | wc -l 2>/dev/null)
    MN_STARTED=`$SIBCOIN_CLI masternode status 2>&1 | grep 'successfully started' | wc -l`
    MN_QUEUE_IN_SELECTION=0
    MN_QUEUE_LENGTH=0
    MN_QUEUE_POSITION=0


    NOW=`date +%s`
    MN_LIST="$(cache_output /tmp/mnlist_cache '$SIBCOIN_CLI masternodelist full 2>/dev/null')"

    SORTED_MN_LIST=$(echo "$MN_LIST" | grep ENABLED | sed -e 's/[}|{]//' -e 's/"//g' -e 's/,//g' | grep -v ^$ | \
awk ' \
{
    if ($7 == 0) {
        TIME = $6
        print $_ " " TIME

    }
    else {
        xxx = ("'$NOW'" - $7)
        if ( xxx >= $6) {
            TIME = $6
        }
        else {
            TIME = xxx
        }

        print $_ " " TIME
    }

}' |  sort -k10 -n)

    MN_STATUS=$(   echo "$SORTED_MN_LIST" | grep $MASTERNODE_BIND_IP | awk '{print $2}')
    MN_VISIBLE=$(  test "$MN_STATUS" && echo 1 || echo 0 )
    MN_ENABLED=$(  echo "$SORTED_MN_LIST" | grep -c ENABLED)
    MN_UNHEALTHY=$(echo "$SORTED_MN_LIST" | grep -c EXPIRED)
    #MN_EXPIRED=$(  echo "$SORTED_MN_LIST" | grep -c EXPIRED)
    MN_TOTAL=$(( $MN_ENABLED + $MN_UNHEALTHY ))

    MN_SYNC_STATUS=$( $SIBCOIN_CLI mnsync status )
    MN_SYNC_ASSET=$(echo "$MN_SYNC_STATUS" | grep 'AssetName' | awk '{print $2}' | sed -e 's/[",]//g' )
    MN_SYNC_COMPLETE=$(echo "$MN_SYNC_STATUS" | grep 'IsSynced' | grep 'true' | wc -l)

    if [ $MN_VISIBLE -gt 0 ]; then
        MN_QUEUE_LENGTH=$MN_ENABLED
        MN_QUEUE_POSITION=$(echo "$SORTED_MN_LIST" | grep ENABLED | grep -A9999999 $MASTERNODE_BIND_IP | wc -l)
        if [ $MN_QUEUE_POSITION -gt 0 ]; then
            MN_QUEUE_IN_SELECTION=$(( $MN_QUEUE_POSITION <= $(( $MN_QUEUE_LENGTH / 10 )) ))
        fi
    fi

    # sentinel checks
    if [ -e $INSTALL_DIR/sentinel ]; then

        SENTINEL_INSTALLED=0
        SENTINEL_PYTEST=0
        SENTINEL_CRONTAB=0
        SENTINEL_LAUNCH_OUTPUT=""
        SENTINEL_LAUNCH_OK=-1

        cd $INSTALL_DIR/sentinel
        SENTINEL_INSTALLED=$( ls -l bin/sentinel.py | wc -l )
        SENTINEL_PYTEST=$( venv/bin/py.test test 2>&1 > /dev/null ; echo $? )
        SENTINEL_CRONTAB=$( crontab -l | grep sentinel | grep -v '^#' | wc -l )
        SENTINEL_LAUNCH_OUTPUT=$( venv/bin/python bin/sentinel.py 2>&1 )
        if [ -z "$SENTINEL_LAUNCH_OUTPUT" ] ; then
            SENTINEL_LAUNCH_OK=$?
        fi
        cd - > /dev/null
    fi

    if [ $MN_CONF_ENABLED -gt 0 ] ; then
        WEB_NINJA_API=$($curl_cmd "https://www.dashninja.pl/api/masternodes?ips=\[\"${MASTERNODE_BIND_IP}:9999\"\]&portcheck=1&balance=1")
        if [ -z "$WEB_NINJA_API" ]; then
            sleep 2
            # downgrade connection to support distros with stale nss libraries
            WEB_NINJA_API=$($curl_cmd --ciphers rsa_3des_sha "https://www.dashninja.pl/api/masternodes?ips=\[\"${MASTERNODE_BIND_IP}:9999\"\]&portcheck=1&balance=1")
        fi

        WEB_NINJA_JSON_TEXT=$(echo $WEB_NINJA_API | python -m json.tool)
        WEB_NINJA_SEES_OPEN=$(echo "$WEB_NINJA_JSON_TEXT" | grep '"Result"' | grep open | wc -l)
        WEB_NINJA_MN_ADDY=$(echo "$WEB_NINJA_JSON_TEXT" | grep MasternodePubkey | awk '{print $2}' | sed -e 's/[",]//g')
        WEB_NINJA_MN_VIN=$(echo "$WEB_NINJA_JSON_TEXT" | grep MasternodeOutputHash | awk '{print $2}' | sed -e 's/[",]//g')
        WEB_NINJA_MN_VIDX=$(echo "$WEB_NINJA_JSON_TEXT" | grep MasternodeOutputIndex | awk '{print $2}' | sed -e 's/[",]//g')
        WEB_NINJA_MN_BALANCE=$(echo "$WEB_NINJA_JSON_TEXT" | grep Value | awk '{print $2}' | sed -e 's/[",]//g')
        WEB_NINJA_MN_LAST_PAID_TIME_EPOCH=$(echo "$WEB_NINJA_JSON_TEXT" | grep MNLastPaidTime | awk '{print $2}' | sed -e 's/[",]//g')
        WEB_NINJA_MN_LAST_PAID_AMOUNT=$(echo "$WEB_NINJA_JSON_TEXT" | grep MNLastPaidAmount | awk '{print $2}' | sed -e 's/[",]//g')
        WEB_NINJA_MN_LAST_PAID_BLOCK=$(echo "$WEB_NINJA_JSON_TEXT" | grep MNLastPaidBlock | awk '{print $2}' | sed -e 's/[",]//g')

        WEB_NINJA_LAST_PAYMENT_TIME=$(date -d @${WEB_NINJA_MN_LAST_PAID_TIME_EPOCH} '+%m/%d/%Y %H:%M:%S' 2>/dev/null)

        if [ ! -z "$WEB_NINJA_LAST_PAYMENT_TIME" ]; then
            local daysago=$(dateDiff -d now "$WEB_NINJA_LAST_PAYMENT_TIME")
            local hoursago=$(dateDiff -h now "$WEB_NINJA_LAST_PAYMENT_TIME")
            hoursago=$(( hoursago - (24 * daysago) ))
            WEB_NINJA_LAST_PAYMENT_TIME="$WEB_NINJA_LAST_PAYMENT_TIME ($daysago ${messages["days"]}, $hoursago ${messages["hours"]}${messages["ago"]})"

        fi

        WEB_NINJA_API_OFFLINE=0
        if [[ $(echo "$WEB_NINJA_API" | grep '"status":"ERROR"' | wc -l) > 0 ]];then
            WEB_NINJA_API_OFFLINE=1
        fi

    fi

}

date2stamp () {
    date --utc --date "$1" +%s
}

stamp2date (){
    date --utc --date "1970-01-01 $1 sec" "+%Y-%m-%d %T"
}

dateDiff (){
    case $1 in
        -s)   sec=1;      shift;;
        -m)   sec=60;     shift;;
        -h)   sec=3600;   shift;;
        -d)   sec=86400;  shift;;
        *)    sec=86400;;
    esac
    dte1=$(date2stamp $1)
    dte2=$(date2stamp "$2")
    diffSec=$((dte2-dte1))
    if ((diffSec < 0)); then abs=-1; else abs=1; fi
    echo $((diffSec/sec*abs))
}

get_host_status(){
    HOST_LOAD_AVERAGE=$(cat /proc/loadavg | awk '{print $1" "$2" "$3}')
    uptime=$(</proc/uptime)
    uptime=${uptime%%.*}
    HOST_UPTIME_DAYS=$(( uptime/60/60/24 ))
    HOSTNAME=$(hostname -f)
}


print_status() {

    SIBCOIND_UPTIME_STRING="$SIBCOIND_UPTIME_DAYS ${messages["days"]}, $SIBCOIND_UPTIME_HOURS ${messages["hours"]}, $SIBCOIND_UPTIME_MINS ${messages["mins"]}, $SIBCOIND_UPTIME_SECS ${messages["secs"]}"

    pending "${messages["status_hostnam"]}" ; ok "$HOSTNAME"
    pending "${messages["status_uptimeh"]}" ; ok "$HOST_UPTIME_DAYS ${messages["days"]}, $HOST_LOAD_AVERAGE"
    pending "${messages["status_sibcoindip"]}" ; [ $MASTERNODE_BIND_IP != 'none' ] && ok "$MASTERNODE_BIND_IP" || err "$MASTERNODE_BIND_IP"
    pending "${messages["status_sibcoindve"]}" ; ok "$CURRENT_VERSION"
    pending "${messages["status_uptodat"]}" ; [ $SIBCOIND_UP_TO_DATE -gt 0 ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_running"]}" ; [ $SIBCOIND_HASPID     -gt 0 ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_uptimed"]}" ; [ $SIBCOIND_RUNNING    -gt 0 ] && ok "$SIBCOIND_UPTIME_STRING" || err "$SIBCOIND_UPTIME_STRING"
    pending "${messages["status_drespon"]}" ; [ $SIBCOIND_RUNNING    -gt 0 ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_dlisten"]}" ; [ $SIBCOIND_LISTENING  -gt 0 ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_dconnec"]}" ; [ $SIBCOIND_CONNECTED  -gt 0 ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_dportop"]}" ; [ $PUBLIC_PORT_CLOSED  -lt 1 ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_dconcnt"]}" ; [ $SIBCOIND_CONNECTIONS   -gt 0 ] && ok "$SIBCOIND_CONNECTIONS" || err "$SIBCOIND_CONNECTIONS"
    pending "${messages["status_dblsync"]}" ; [ $SIBCOIND_SYNCED     -gt 0 ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_dbllast"]}" ; [ $SIBCOIND_SYNCED     -gt 0 ] && ok "$SIBCOIND_CURRENT_BLOCK" || err "$SIBCOIND_CURRENT_BLOCK"
    pending "${messages["status_webchai"]}" ; [ $WEB_BLOCK_COUNT_CHAINZ -gt 0 ] && ok "$WEB_BLOCK_COUNT_CHAINZ" || err "$WEB_BLOCK_COUNT_CHAINZ"
    pending "${messages["status_webdark"]}" ; [ $WEB_BLOCK_COUNT_DQA    -gt 0 ] && ok "$WEB_BLOCK_COUNT_DQA" || err "$WEB_BLOCK_COUNT_DQA"
    pending "${messages["status_webdash"]}" ; [ $WEB_BLOCK_COUNT_DWHALE -gt 0 ] && ok "$WEB_BLOCK_COUNT_DWHALE" || err "$WEB_BLOCK_COUNT_DWHALE"
    pending "${messages["status_webmast"]}" ; [ $WEB_ME_FORK_DETECT -gt 0 ] && err "$WEB_ME" || ok "$WEB_ME"
    pending "${messages["status_dcurdif"]}" ; ok "$SIBCOIND_DIFFICULTY"
    if [ $SIBCOIND_RUNNING -gt 0 ] && [ $MN_CONF_ENABLED -gt 0 ] ; then
    pending "${messages["status_mnstart"]}" ; [ $MN_STARTED -gt 0  ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_mnvislo"]}" ; [ $MN_VISIBLE -gt 0  ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
        if [ $WEB_NINJA_API_OFFLINE -eq 0 ]; then
    pending "${messages["status_mnvisni"]}" ; [ $WEB_NINJA_SEES_OPEN -gt 0  ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "${messages["status_mnaddre"]}" ; ok "$WEB_NINJA_MN_ADDY"
    pending "${messages["status_mnfundt"]}" ; ok "$WEB_NINJA_MN_VIN-$WEB_NINJA_MN_VIDX"
    pending "${messages["status_mnqueue"]}" ; [ $MN_QUEUE_IN_SELECTION -gt 0  ] && highlight "$MN_QUEUE_POSITION/$MN_QUEUE_LENGTH (selection pending)" || ok "$MN_QUEUE_POSITION/$MN_QUEUE_LENGTH"
    pending "  masternode mnsync state    : " ; [ ! -z "$MN_SYNC_ASSET" ] && ok "$MN_SYNC_ASSET" || ""
    pending "  masternode network state   : " ; [ "$MN_STATUS" == "ENABLED" ] && ok "$MN_STATUS" || highlight "$MN_STATUS"

    pending "${messages["status_mnlastp"]}" ; [ ! -z "$WEB_NINJA_MN_LAST_PAID_AMOUNT" ] && \
        ok "$WEB_NINJA_MN_LAST_PAID_AMOUNT in $WEB_NINJA_MN_LAST_PAID_BLOCK on $WEB_NINJA_LAST_PAYMENT_TIME " || warn 'never'
    pending "${messages["status_mnbalan"]}" ; [ ! -z "$WEB_NINJA_MN_BALANCE" ] && ok "$WEB_NINJA_MN_BALANCE" || warn '0'

    pending "    sentinel installed       : " ; [ $SENTINEL_INSTALLED -gt 0  ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "    sentinel tests passed    : " ; [ $SENTINEL_PYTEST    -eq 0  ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "    sentinel crontab enabled : " ; [ $SENTINEL_CRONTAB   -gt 0  ] && ok "${messages["YES"]}" || err "${messages["NO"]}"
    pending "    sentinel online          : " ; [ $SENTINEL_LAUNCH_OK -eq 0  ] && ok "${messages["YES"]}" || ([ $MN_SYNC_COMPLETE -eq 0 ] && warn "${messages["NO"]} - sync incomplete") || err "${messages["NO"]}"

        else
    err     "  dashninja api offline        " ;
        fi
    else
    pending "${messages["status_mncount"]}" ; [ $MN_TOTAL            -gt 0 ] && ok "$MN_TOTAL" || err "$MN_TOTAL"
    fi
}

show_message_configure() {
    echo
    ok "${messages["to_enable_masternode"]}"
    ok "${messages["uncomment_conf_lines"]}"
    echo
         pending "    $HOME/.dashcore/dash.conf" ; echo
    echo
    echo -e "$C_GREEN install sentinel$C_NORM"
    echo
    echo -e "    ${C_YELLOW}dashman install sentinel$C_NORM"
    echo
    echo -e "$C_GREEN ${messages["then_run"]}$C_NORM"
    echo
    echo -e "    ${C_YELLOW}dashman restart now$C_NORM"
    echo
}

get_public_ips() {
    PUBLIC_IPV4=$($curl_cmd -4 https://icanhazip.com/)
#    PUBLIC_IPV6=$($curl_cmd -6 https://icanhazip.com/)
#    if [ -z "$PUBLIC_IPV4" ] && [ -z "$PUBLIC_IPV6" ]; then
    if [ -z "$PUBLIC_IPV4" ]; then

        # try http
        PUBLIC_IPV4=$($curl_cmd -4 http://icanhazip.com/)
#        PUBLIC_IPV6=$($curl_cmd -6 http://icanhazip.com/)

#        if [ -z "$PUBLIC_IPV4" ] && [ -z "$PUBLIC_IPV6" ]; then
        if [ -z "$PUBLIC_IPV4" ]; then
            sleep 3
            err "  --> ${messages["err_failed_ip_resolve"]}"
            # try again
            get_public_ips
        fi

    fi
}

cat_until() {
    PATTERN=$1
    FILE=$2
    while read; do
        if [[ "$REPLY" =~ $PATTERN ]]; then
            return
        else
            echo "$REPLY"
        fi
    done < $FILE
}

install_sentinel() {



    # push it ----------------------------------------------------------------

    cd $INSTALL_DIR

    # pummel it --------------------------------------------------------------

    rm -rf sentinel

    # pull it ----------------------------------------------------------------

    pending "  --> ${messages["downloading"]} sentinel... "

    git clone -q https://github.com/dashpay/sentinel.git

    ok "${messages["done"]}"

    # prep it ----------------------------------------------------------------

    pending "  --> installing dependencies... "
    echo

    cd sentinel

    pending "   --> virtualenv init... "
    virtualenv venv 2>&1 > /dev/null;
    if [[ $? -gt 0 ]];then
        err "  --> virtualenv initialization failed"
        pending "  when running: " ; echo
        echo -e "    ${C_YELLOW}virtualvenv venv$C_NORM"
        quit
    fi
    ok "${messages["done"]}"

    pending "   --> pip modules... "
    venv/bin/pip install -r requirements.txt 2>&1 > /dev/null;
    if [[ $? -gt 0 ]];then
        err "  --> pip install failed"
        pending "  when running: " ; echo
        echo -e "    ${C_YELLOW}venv/bin/pip install -r requirements.txt$C_NORM"
        quit
    fi
    ok "${messages["done"]}"

    pending "  --> testing installation... "
    venv/bin/py.test ./test/ 2>&1>/dev/null; 
    if [[ $? -gt 0 ]];then
        err "  --> sentinel tests failed"
        pending "  when running: " ; echo
        echo -e "    ${C_YELLOW}venv/bin/py.test ./test/$C_NORM"
        quit
    fi
    ok "${messages["done"]}"

    pending "  --> installing crontab... "
    (crontab -l 2>/dev/null | grep -v sentinel.py ; echo "* * * * * cd $INSTALL_DIR/sentinel && venv/bin/python bin/sentinel.py  2>&1 >> sentinel-cron.log") | crontab -
    ok "${messages["done"]}"

    cd ..

}
