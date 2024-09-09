#!/usr/bin/env bash

KANAE_FIRST_START_CHECK="KANAE_FIRST_START"

if [ ! -f $KANAE_FIRST_START_CHECK ]; then
    touch $KANAE_FIRST_START_CHECK
    echo "DO NOT EDIT THIS FILE! THIS IS USED WHEN YOU FIRST RUN KANAE USING DOCKER!" >> $KANAE_FIRST_START_CHECK
    # python3 /kanae/server/migrations.py init
fi

exec python3 /kanae/server/launcher.py --no-workers