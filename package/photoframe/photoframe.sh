#! /bin/bash
CONF_DIR=/data/photoframe
MOUNTPOINT_DAV=/data/photoframe/images_webdav
FOLDER_IMAGES=/data/photoframe/images_local
THUMBNAILS_FOLDER_IMAGES=/data/photoframe/images_local_thumbnails
WEBDAV_CONF=${CONF_DIR}/conf/webdav.conf

if [ -e ${CONF_DIR}/conf/webdav_cert.pem ]
then
  DAVFS_CONF=/etc/photoframe/davfs2_owncert.conf
else
  DAVFS_CONF=/etc/photoframe/davfs2.conf
fi

#File that lists all available photos. Will be overwritten on sync
PHOTO_FILE_LIST=${CONF_DIR}/conf/filelist.txt

PARAMS_FBV="--noclear --smartfit 30 --delay 1"

NO_IMAGES="/usr/share/photoframe/noimages.png"

ERROR_DIR="/tmp/photoframe"
mkdir -p $ERROR_DIR

SLIDESHOW_DELAY=3
SHUFFLE=false
SHOW_FILENAME=false
SHOW_VIDEOS=false

GPIO_PIN_NEXT=16 # show next file
GPIO_PIN_PREVIOUS=17 # show previous file
GPIO_PIN_PLAY=22 # start/pause rotating images automatically
GPIO_ACTION_VALUE=0 # value to identify action, for an pullup the value should be 0, for pulldown 1

if [ -e ${CONF_DIR}/conf/photoframe.conf ]
then
  source ${CONF_DIR}/conf/photoframe.conf
fi

# configure control buttons
function init_gpio_input_pin() {
  if [ ! -d /sys/class/gpio/gpio${1} ]
  then
    echo ${1} > /sys/class/gpio/export
    echo "in" > /sys/class/gpio/gpio${1}/direction
  fi
}

init_gpio_input_pin ${GPIO_PIN_NEXT} 
init_gpio_input_pin ${GPIO_PIN_PLAY}
init_gpio_input_pin ${GPIO_PIN_PREVIOUS}

function read_conf {
  read -r firstline< $WEBDAV_CONF
  array=($firstline)
  echo ${array[0]}
}

function sync {
error_settopic 10_Sync

if [ -f "$WEBDAV_CONF" ]; then
  chmod 0600 ${WEBDAV_CONF}


  mkdir -p $FOLDER_IMAGES
  mkdir -p $MOUNTPOINT_DAV

  REMOTE_DAV=$(read_conf)

  ERROR=$(mount.davfs -o ro,conf=$DAVFS_CONF "$REMOTE_DAV" $MOUNTPOINT_DAV 2>&1 > /dev/null)
  if [ $? -ne 0 ]
  then
    error_write "Mounting $REMOTE_DAV failed: $ERROR"
  fi

  # Check if dav is mounted before starting rsync
  mount | grep $MOUNTPOINT_DAV > /dev/null
  if [ $? -eq 0 ]
  then
    # Only sync supported files
    if [ "$SHOW_VIDEOS" = true ]
    then
        ERROR=$(rsync --ignore-existing -vtrm --include '*.png' --include '*.PNG' --include '*.jpg' --include '*.JPG' --include '*.jpeg' --include '*.JPEG' --include '*.mp4' --include '*.MP4' --include '*.mov' --include '*.MOV' --include '*/' --exclude '*' --delete $MOUNTPOINT_DAV/ $FOLDER_IMAGES 2>&1 > /dev/null)
    else
        ERROR=$(rsync --ignore-existing -vtrm --include '*.png' --include '*.PNG' --include '*.jpg' --include '*.JPG' --include '*.jpeg' --include '*.JPEG' --include '*/' --exclude '*' --delete $MOUNTPOINT_DAV/ $FOLDER_IMAGES 2>&1 > /dev/null)
    fi

    [ $? -eq 0 ] || error_write "Syncing images failed: $ERROR"

    umount $MOUNTPOINT_DAV

    find $FOLDER_IMAGES -type f -iname '*\.jpg' -o -iname '*\.jpeg' -o -iname '*\.png' -o -iname '*\.mp4' -o -iname '*\.mov' | sort > $PHOTO_FILE_LIST
  fi
else

  error_write "No WebDAV server configured. Go to http://$(hostname)"

fi
}

# scale down images for faster displaying and switching
function prepare {
  if [ ! -d ${THUMBNAILS_FOLDER_IMAGES} ]
  then
    mkdir ${THUMBNAILS_FOLDER_IMAGES}
  fi

  for i in $(cat ${PHOTO_FILE_LIST})
  do
    THUMBNAIL_FILE="${THUMBNAILS_FOLDER_IMAGES}/$(basename ${i})"

    # if image does not exist
    if [ ! -f "${THUMBNAIL_FILE}" ]
    then
      if file "${i}" | cut -d':' -f2 |grep -qE 'image|bitmap'
      then # file is image
        convert "${i}" -resize '1920x1080>' "${THUMBNAIL_FILE}"
        jhead -autorot "${THUMBNAIL_FILE}" &> /dev/null
      else # file is video
        cp "${i}" "${THUMBNAIL_FILE}"
      fi
    fi
  done

  # recreate photo list
  find "${THUMBNAILS_FOLDER_IMAGES}" -type f -iname '*\.jpg' -o -iname '*\.jpeg' -o -iname '*\.png' -o -iname '*\.mp4' -o -iname '*\.mov' | sort > $PHOTO_FILE_LIST
}

ERROR_TOPIC="";

function error_display {
  TTY=/dev/tty0
  echo -en "\e[H" > $TTY # Move tty cursor to beginning (1,1)
  for f in $ERROR_DIR/*.txt; do
    [[ -f $f ]] || continue
    cat $f > $TTY
  done
}

function error_settopic {
  ERROR_TOPIC=$1.txt;
  > $ERROR_DIR/$ERROR_TOPIC
}

function error_write {
  echo $1 >> $ERROR_DIR/$ERROR_TOPIC
}

num_files=0;
file_num=0;

function get_image {
  local rnd_num
  rnd_num=-1
  local counter
  counter=0

  num_files=0
  if [ -f $PHOTO_FILE_LIST ]
  then
    num_files=$(wc -l "$PHOTO_FILE_LIST" | awk '{print $1}')
  fi

  if [ $num_files -gt 0 ]
  then
    if [ "$SHUFFLE" = true ]
    then
      # sed counts from 1 to N (not 0 to N-1)
      rnd_num=$(( ( $RANDOM % $num_files ) + 1 ))
    else
      # sed counts from 1 to N (not 0 to N-1)
      file_num=$((file_num % $num_files));
      file_num=$((file_num+1));
      rnd_num=$file_num
    fi
    IMAGE=$(sed "${rnd_num}q;d" $PHOTO_FILE_LIST)
  fi

  if [ -z "$IMAGE" ]
  then
    if [ $num_files -eq 0 ]
    then
      IMAGE=$NO_IMAGES
    else
      get_image
    fi
  fi
}

function get_previous_image() {
  file_num=$((file_num + $num_files));
  file_num=$((file_num-2));

  get_image
}



function start {
  local IMAGE=$NO_IMAGES
  local AUTO_NEXT_MODE=false # show next file after SLIDESHOW_DELAY
  local IS_IMAGE=false
  local PID=-1 # pid of omxplayer do detect video end
  local LAST_IMAGE_UPDATE=0

  counter=0
  error_settopic 01_Startup
  error_write "Go to http://$(hostname) to configure photOS"

  UPDATE_MEDIA=false
  while true; do
    if [ "$(cat /sys/class/gpio/gpio${GPIO_PIN_NEXT}/value)" -eq "${GPIO_ACTION_VALUE}" ]
    then
      get_image
      UPDATE_MEDIA=true
      read -p "Pausing NEXT" -t 0.5
      continue
    elif [ "$(cat /sys/class/gpio/gpio${GPIO_PIN_PREVIOUS}/value)" -eq "${GPIO_ACTION_VALUE}" ]
    then
      get_previous_image
      UPDATE_MEDIA=true
      read -p "Pausing PREVIOUS" -t 0.5
      continue
    elif [ "$(cat /sys/class/gpio/gpio${GPIO_PIN_PLAY}/value)" -eq "${GPIO_ACTION_VALUE}" ]
    then
      read -p "Pausing PLAY" -t 0.5
      if ${AUTO_NEXT_MODE}
      then
        AUTO_NEXT_MODE=false
      else
        AUTO_NEXT_MODE=true
      fi
      continue
    fi

    if ${AUTO_NEXT_MODE}
    then
      NOW=$(date +%s)
      if [ "$IS_IMAGE" = true ]
      then
        # image was shown for slide show delay
        if [ $(( NOW - LAST_IMAGE_UPDATE )) -gt ${SLIDESHOW_DELAY} ]
        then
          UPDATE_MEDIA=true
          get_image
        fi
      else
        # video has ended
        if ! kill $PID > /dev/null 2>&1; then
          UPDATE_MEDIA=true
          get_image
        fi
      fi
    fi

    if ${UPDATE_MEDIA}
    then
      UPDATE_MEDIA=false
      echo $IMAGE

      IS_IMAGE=false

      if file "$IMAGE" | cut -d':' -f2 |grep -qE 'image|bitmap'
      then
        IS_IMAGE=true
      fi

      if ${IS_IMAGE}
      then
        LAST_IMAGE_UPDATE=$(date +%s)
        fbv $PARAMS_FBV "$IMAGE"
      else
        omxplayer  "$IMAGE" &
        PID=$!
      fi

      if [ "$SHOW_FILENAME" = true ]
      then
        # abuse error reporting to show the path of the current picture
        error_settopic 02_Current
        #don't show the FOLDER_IMAGES prefix
        error_write "$( echo "$IMAGE" | sed -e "s|^${FOLDER_IMAGES}/||" )"
      fi

      error_display

      counter=$((counter+1))
      if [ $counter -eq 10 ]
      then
        error_settopic 01_Startup
      fi
    fi
  done
}


function display {
  case "$1" in
    on)
        vcgencmd display_power 1
        ;;

    off)
        vcgencmd display_power 0
        ;;

    *)
        echo "Usage: $0 display {on|off}"
        exit 1
esac
}


case "$1" in
    start)
        start
        ;;

    stop)
        stop
        ;;

    restart)
        stop
        start
        ;;

    sync)
        sync
        ;;

    prepare)
        prepare
        ;;

    display)
        display $2
        ;;

    test)
        get_image
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|sync|prepare|display on/off}"
        exit 1
esac