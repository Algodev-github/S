if [ "$SUDO_USER" != "" ]; then
	CONF_DEST_DIR=/home/$SUDO_USER
else
	CONF_DEST_DIR=~
fi

if [ ! -f $CONF_DEST_DIR/.S-config.sh ]; then
	echo No user config found in $CONF_DEST_DIR, copying default config
	tail -n +5 ../def_config_params.sh > $CONF_DEST_DIR/.S-config.sh

	if [ "$SUDO_USER" != "" ]; then
		chown $SUDO_USER:$SUDO_USER $CONF_DEST_DIR/.S-config.sh
	fi
else
	if [ ../def_config_params.sh -nt $CONF_DEST_DIR/.S-config.sh ]; then
		echo Your config file \($CONF_DEST_DIR/.S-config.sh\) is older
		echo than my default config file. If this is ok for you,
		echo then just
		echo touch $CONF_DEST_DIR/.S-config.sh
		echo to eliminate this error.
		echo Otherwise
		echo rm $CONF_DEST_DIR/.S-config.sh
		echo to have your config file updated automatically.
		exit
	fi
fi

. $CONF_DEST_DIR/.S-config.sh
