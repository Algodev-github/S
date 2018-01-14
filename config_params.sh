if [ "$SUDO_USER" != "" ]; then
	CONF_DEST_DIR=/home/$SUDO_USER
else
	CONF_DEST_DIR=~
fi

if [ ! -f $CONF_DEST_DIR/.S-config.sh ]; then
	echo No user config found in $CONF_DEST_DIR, copying default config
	tail -n +5 ../def_config_params.sh > $CONF_DEST_DIR/.S-config.sh
fi

. $CONF_DEST_DIR/.S-config.sh
