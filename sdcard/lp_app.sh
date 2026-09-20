#!/bin/sh

if ! grep rtsp_server_mode /userdata/xhr_config.ini ; then
  echo >> /userdata/xhr_config.ini
  echo '[config]' >> /userdata/xhr_config.ini
  echo 'rtsp_server_mode=2' >> /userdata/xhr_config.ini
fi

if ! grep 'rtsp_server_mode=2' /userdata/xhr_config.ini ; then
  sed -i 's/rtsp_server_mode=.*/rtsp_server_mode=2/' /userdata/xhr_config.ini
fi

cp /userdata/xhr_config.ini /mnt/sdcard/xhr_config.ini
sync

lp_app --noshell --log2file /mnt/sdcard/logs
