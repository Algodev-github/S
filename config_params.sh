if [ "$SUDO_USER" != "" ]; then
    eval CONF_DEST_DIR=~$SUDO_USER
else
    CONF_DEST_DIR=~
fi

if [ ! -f $CONF_DEST_DIR/.S-config.sh ]; then
	echo No user config found in $CONF_DEST_DIR, copying default config
	tail -n +5 ../def_config.sh > $CONF_DEST_DIR/.S-config.sh

	if [ "$SUDO_USER" != "" ]; then
		chown $SUDO_USER:$SUDO_USER $CONF_DEST_DIR/.S-config.sh
	fi
else
	sed 's/^#.*//g' ../def_config.sh > def_file
	sed 's/^#.*//g' $CONF_DEST_DIR/.S-config.sh > user_file
	if [[ "$(diff -d -B def_file user_file)" != "" && \
		  ../def_config.sh -nt $CONF_DEST_DIR/.S-config.sh ]]; then
		echo Your config file \($CONF_DEST_DIR/.S-config.sh\) is older
		echo than my default config file. If this is ok for you,
		echo then just
		echo touch $CONF_DEST_DIR/.S-config.sh
		echo to eliminate this error.
		echo Otherwise
		echo rm $CONF_DEST_DIR/.S-config.sh
		echo to have your config file updated automatically
		echo with default values.
		rm def_file user_file
		exit
	fi
	rm def_file user_file
fi

. $CONF_DEST_DIR/.S-config.sh
. ../process_config.sh
