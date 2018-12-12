#!/bin/bash

# Check and install dependencies

# Make this associative array global
declare -A packages

function select_packages_and_manager
{
    declare -A rpm_packages
    rpm_packages=( [fio]=fio [iostat]=sysstat [/usr/bin/time]=time \
		   [/usr/include/libaio.h]=libaio-devel [awk]=gawk \
		   [dd]=coreutils [bc]=bc [fio]=fio [killall]=psmisc \
		   [g++]=gcc-c++ [git]=git-core [mplayer]=mplayer \
		   [xterm]=xterm [gnome-terminal]=gnome-terminal \
		   [pv]=pv \
		 )
    declare -A deb_packages
    deb_packages=( [fio]=fio [iostat]=sysstat [/usr/bin/time]=time \
		   [/usr/include/libaio.h]=libaio-dev [awk]=gawk \
		   [dd]=coreutils [bc]=bc [fio]=fio [killall]=psmisc \
		   [g++]=g++ [git]=git [mplayer]=mplayer \
		   [xterm]=xterm [gnome-terminal]=gnome-terminal \
		   [pv]=pv \
		 )

    declare -A pack_managers
    pack_managers[/etc/fedora-release]=dnf
    pack_managers[/usr/lib/os.release.d/issue-fedora]=dnf
    pack_managers[/etc/redhat-release]=yum
    pack_managers[/etc/debian_version]=apt
    pack_managers[/etc/issue]=apt
    # pack_managers[/etc/SuSE-release]=zypper not supported yet
    # pack_managers[/etc/arch-release]=pacman not supported yet
    # pack_managers[/etc/gentoo-release]=emerge not supported yet

    declare -A pack_formats
    pack_formats[/etc/fedora-release]=rpm
    pack_formats[/usr/lib/os.release.d/issue-fedora]=rpm
    pack_formats[/etc/redhat-release]=rpm
    pack_formats[/etc/debian_version]=deb
    pack_formats[/etc/issue]=deb
    # pack_formats[/etc/SuSE-release]=rpm not supported yet

    for f in ${!pack_managers[@]}
    do
	f=$(readlink -f $f)

	if [[ -f $f ]]; then
	    DISTRO_FOUND=yes
	    if [[ "$PACKAGE_MANAGER" == "" ]]; then
		PACKAGE_MANAGER=${pack_managers[$f]}
	    fi
	    type $PACKAGE_MANAGER >/dev/null 2>&1
	    if [[ $? -ne 0 ]]; then
		echo Looked for $PACKAGE_MANAGER as package manager
		echo for installing missing commands, but not found.
		echo You may want to choose the package manager to use
		echo manually, by setting the config parameter
		echo PACKAGE_MANAGER

		return
	    else
		PACK_MAN_FOUND=yes
	    fi
	    break
	fi
    done

    if [[ "$DISTRO_FOUND" != yes ]]; then
	echo -n Sorry, automatic dependency installation not yet supported
	echo for your distribution.
	return
    fi

    if [[ ${pack_formats[$f]} == rpm ]]; then
	for k in "${!rpm_packages[@]}"; do
	    packages[$k]=${rpm_packages[$k]};
	done
    else
	for k in "${!deb_packages[@]}"; do
	    packages[$k]=${deb_packages[$k]};
	done
    fi
}

function install_commands
{

    select_packages_and_manager

    if [[ "$DISTRO_FOUND" != yes || "$PACK_MAN_FOUND" != yes ]]; then
	return
    fi

    for comm in $MISSING_LIST; do
	if [[ "${packages[$comm]}" == "" ]]; then
	    echo Sorry, no package associated with $comm in my database
	    PARTIAL_INSTALL=yes
	fi
	PACKAGE_LIST="$PACKAGE_LIST ${packages[$comm]}"
    done

    if [[ "$PACKAGE_LIST" != "" && "$PACKAGE_LIST" != " " ]]; then
	echo -n "To install the above missing commands, "
	echo I\'m about to install the following packages:
	echo $PACKAGE_LIST

	$PACKAGE_MANAGER -y install $PACKAGE_LIST
    fi

    if [[ $? -ne 0 ]]; then
	echo Some packages failed to be installed
    else
	INSTALL_SUCCESS=yes
    fi
}

function check_dep
{
    COMMAND_LIST=( "$@" )
    MISSING_LIST=
    for i in "${COMMAND_LIST[@]}" ; do
	type $i >/dev/null 2>&1 || [ -f $i ] || \
	    { echo >&2 "$i not found."; \
	      MISSING_LIST="$MISSING_LIST $i"; }
    done

    if [ "$MISSING_LIST" == "" ]; then
	return
    fi

    install_commands "$MISSING_LIST"

    if [[ "$INSTALL_SUCCESS" != yes || "$PARTIAL_INSTALL" == yes ]]; then
	echo Please install unsolved dependencies manually, and retry.
	echo Aborting now.
	exit 1
    fi
}

if [[ "$@" == "" ]] ; then
    echo "Checking principal dependencies..."
    check_dep awk iostat bc time fio

    echo "Checking secondary dependencies..."
    check_dep pv git make
else
    check_dep "$@"
fi
