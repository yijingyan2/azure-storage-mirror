#!/bin/bash -e

####################################################################
# Publish the debian mirror by aptly
# 1. Publish gpg public keys in the mirror
# 2. Publish the mirror snapshot
# 3. Publish the full mirror contains the history packages
####################################################################

usage()
{
    echo "Usage:   $0 -n <name> -u <url> -d <distributions> -a <architectures> -c <components>"
    echo "Usage:   $0 -n <name> -u <url> -j <json_config> [-a <architectures>] [-c <components>]"
    echo "Example: $0 -n debian \\"
    echo "         -u \"http://deb.debian.org/debian\" -d bullseye,bullseye-updates,bullseye-backports \\"
    echo "         -a amd64,armhf,arm64 -c contrib,non-free,main \\"
    exit 1
}

FILESYSTEM_NAME=
PUBLISH_ROOT=
DISTRIBUTIONS=
MIRROR_URL=
ARCHITECTURES=
COMPONENTS=
JSON_CONFIG=

while getopts "n:u:d:a:c:b:i:j:f" opt; do
    case $opt in
        n)
            FILESYSTEM_NAME=$OPTARG
            ;;
        u)
            MIRROR_URL=$OPTARG
            ;;
        d)
            DISTRIBUTIONS=$OPTARG
            ;;
        a)
            ARCHITECTURES=$OPTARG
            ;;
        c)
            COMPONENTS=$OPTARG
            ;;
        j)
            JSON_CONFIG=$OPTARG
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "$FILESYSTEM_NAME" ] || [ -z "$MIRROR_URL" ]; then
    echo "Some required options: name, url, not set:" 1>&2
    usage
fi

if [ -z "$DISTRIBUTIONS" ] || [ -z "$ARCHITECTURES" ] || [ -z "$COMPONENTS" ]; then
    if [ -z "$JSON_CONFIG" ]; then
      echo "Some required options not set:" 1>&2
      usage
    fi
fi

[ -z "$COMPONENTS" ] && COMPONENTS="contrib,non-free,main"
[ -z "$ARCHITECTURES" ] && ARCHITECTURES="amd64,armhf,arm64"
[ -z "$NFS_ROOT" ] && NFS_ROOT=/nfs

MIRROR_REL_DIR=v1/sn
PACKAGES_DENY_LIST=debian-packages-denylist.conf

SOURCE_DIR=$(pwd)
WORK_DIR=$SOURCE_DIR/work
NFS_DIR=$NFS_ROOT/$MIRROR_REL_DIR
APT_MIRROR_DIR=$NFS_DIR/work/$FILESYSTEM_NAME
PUBLISH_DIR=$NFS_DIR/publish/$FILESYSTEM_NAME

mkdir -p $WORK_DIR
mkdir -p $APT_MIRROR_DIR
mkdir -p $PUBLISH_DIR
cd $WORK_DIR

append_mirrors()
{
    local config=$1
    local url=$2
    local distributions=$3
    local architectures=$4
    local components=$(echo $5 | tr ',' ' ')
    for dist in $(echo $distributions | tr ',' ' '); do
        for arch in $(echo $architectures | tr ',' ' '); do
            echo "deb-$arch $url $dist $components" >> $config
        done
        echo "deb-src $url $dist $components" >> $config
        echo "" >> $config
    done
}

prepare_workspace()
{
    echo "pwd=$(pwd)"
    mkdir -p $NFS_DIR/publish
    cp $SOURCE_DIR/azure-pipelines/config/debian-packages-denylist.conf $PACKAGES_DENY_LIST
    cat $SOURCE_DIR/azure-pipelines/config/mirror.list.template | sed "s#BASE_PATH_PLACEHOLDER#$APT_MIRROR_DIR#" > mirror.list
    local components=$(echo $COMPONENTS | tr ',' ' ')
    if [ -n "$JSON_CONFIG" ]; then
        echo $JSON_CONFIG | jq -r '.[] | .name + "|" + .distributions + "|" + .architectures + "|" + .components' |
        while IFS= read -r line; do
            local name=$(echo $line | cut -d"|" -f1)
            local distributions=$(echo $line | cut -d"|" -f2)
            local architectures=$(echo $line | cut -d"|" -f3)
            local components=$(echo $line | cut -d"|" -f4)
            [ -z "$architectures" ] && architectures=$ARCHITECTURES
            [ -z "$components" ] && components=$COMPONENTS
            append_mirrors mirror.list "$MIRROR_URL" "$distributions" "$architectures" "$components"
        done
    else
        append_mirrors mirror.list "$MIRROR_URL" "$DISTRIBUTIONS" "$ARCHITECTURES" "$COMPONENTS"
    fi
    echo "The mirror.list:"
    cat mirror.list
}

update_mirrors()
{
    set -x
    SNAPSHOT_TIME=$(date +%Y%m%dT%H%M%SZ)
    ENDPOINT=$(echo $MIRROR_URL | awk -F'://' '{print $2}')
    SNAPSHOT_TMP=$PUBLISH_DIR/tmp
    SNAPSHOT_POINT=$PUBLISH_DIR/$SNAPSHOT_TIME
    SNAPSHOT_LATEST=$PUBLISH_DIR/latest
    DISTS=$APT_MIRROR_DIR/mirror/$ENDPOINT/dists

    # Update the mirrors
    sudo apt-mirror mirror.list
    if [[ "$ENDPOINT" == 'deb.debian.org/debian' ]]; then
      ls -al $APT_MIRROR_DIR/mirror/$ENDPOINT/pool/main/n/net-snmp
      ls -al $APT_MIRROR_DIR/mirror/$ENDPOINT/pool/main/a/activemq
    else
      ls -al $APT_MIRROR_DIR/mirror/$ENDPOINT/pool/updates/main/n/net-snmp
      ls -al $APT_MIRROR_DIR/mirror/$ENDPOINT/pool/updates/main/a/activemq
    fi
    
    # Create snapshot and links
    sudo rm -rf $SNAPSHOT_TMP
    sudo mkdir -p $SNAPSHOT_TMP/dists
    echo $SNAPSHOT_TIME | sudo tee $SNAPSHOT_TMP/timestamp
    sudo ln -sf "../../../work/$FILESYSTEM_NAME/mirror/$ENDPOINT/pool" $SNAPSHOT_TMP/pool
    NOW_IN_SECONDS=$(date +%s)

    for dist in `ls $DISTS`
    do
      dist_updates=$dist
      if [ -e $DISTS/$dist/updates ]; then
        dist_updates=$dist/updates
      fi
      cursha256=$(sha256sum $DISTS/$dist_updates/Release  | cut -d " " -f1)
      snsha256=
      elapsedseconds=0
      dist_snapshot=
      if [ -e $SNAPSHOT_LATEST/dists/$dist_updates/Release ]; then
        snsha256=$(sha256sum $SNAPSHOT_LATEST/dists/$dist_updates/Release | cut -d " " -f1)
        dist_snapshot=$(realpath $SNAPSHOT_LATEST/dists/$dist |  awk -F'/' '{print  $(NF-2)}')
        timestamp=$(date --date="$(echo $dist_snapshot | cut -dT -f1)" +%s)
        elapsedseconds=$(($NOW_IN_SECONDS - $timestamp))
      fi
      # Refresh the index if more than 30 days (2592000 seconds), make sure the old indexes can be removed safely
      if [ "$cursha256" == "$snsha256" ] && [ "$elapsedseconds" -lt 2592000 ] && [ "$FORCE_REFRESH" != "y" ]; then
        sudo ln -s ../../$dist_snapshot/dists/$dist $SNAPSHOT_TMP/dists/$dist
      else
        sudo cp -r $DISTS/$dist $SNAPSHOT_TMP/dists/
        if [ "$FILESYSTEM_NAME" == "debian-security" ]; then
          [ ! -d $SNAPSHOT_TMP/dists/$dist/updates ] && sudo ln -s . $SNAPSHOT_TMP/dists/$dist/updates
          if [ "$dist" == "jessie" ] || [ "$dist" == "stretch" ] || [ "$dist" == "buster" ]; then
            sudo ln -nsf $dist/updates $SNAPSHOT_TMP/dists/${dist}_updates
            sudo ln -nsf $dist/updates $SNAPSHOT_TMP/dists/${dist}-security
          fi
        fi
      fi
    done

    sudo mv $SNAPSHOT_TMP $SNAPSHOT_POINT
    sudo ln -nsf $SNAPSHOT_TIME $SNAPSHOT_LATEST
    echo $SNAPSHOT_TIME | sudo tee -a $PUBLISH_DIR/timestamps
    
    # Save pool and mirror indexes
    # Not necessary to save the workspace, the apt-mirror workspace only to accelerate the download speed
    echo $SNAPSHOT_TIME > latest
}

main()
{
    prepare_workspace
    update_mirrors
}

main
