#!/bin/bash
#Incremental backup script
#Takes the latest daily backup set and pushes it to amazon glacier via a tar file

set -eu

. ./lincremental.cfg
. ./lincremental_functions

ORIGINAL="$TRGBASE/daily.0"
UPLOAD="$AWS_UPLOAD_DIR/upload.tar"
READY_LOCK_FILE="$LOCK_DIR/upload.ready"
LINCREMENTAL="lincremental"

lock $LOCK_DIR "glacier"

#create the upload folder if it does not exist
if [ ! -d $AWS_UPLOAD_DIR ] ; then
	$MKDIR -v $AWS_UPLOAD_DIR
fi

#Check to see if we are resuming a partial upload
if [ ! -f $READY_LOCK_FILE ] ; then
    #Starting from scratch, create the upload file

    #if the original dir does not exist, we can't do anything, exit
    if [ ! -d $ORIGINAL ] ; then
            $ECHO "Can't find original backup set at $ORIGINAL, exiting."
        exit 1
    fi

    DESCRIPTION="$LINCREMENTAL $($DATE -r $ORIGINAL)"

    #create a tar from original to upload to glacier
    $TAR $TAR_OPT $UPLOAD -C $TRGBASE "daily.0"

    #encrypt the backup file if desired
    if [ ! -z "$GPG_PUBLIC_KEY" ] ; then
        $GPG -v -r $GPG_PUBLIC_KEY -o "$UPLOAD.gpg" --encrypt $UPLOAD
        $RM -fv $UPLOAD
        UPLOAD="$UPLOAD.gpg"
    fi

    #Indicate that next time we come in, we don't have to create
    #the archive again. Note that we can't just use the upload file as a lock
    #because it may have been created, but not yet finished.
    $TOUCH $READY_LOCK_FILE

    #upload the file
    $GLACIER upload $AWS_VAULT $UPLOAD --description "$DESCRIPTION"
else
    #Resuming a multipart upload
    if [ ! -z "$GPG_PUBLIC_KEY" ] ; then
        UPLOAD="$UPLOAD.gpg"
    fi

    #todo: handle case where lock file was touched, but upload never started
    #todo: handle case where lock file exists, but upload file doesn't

    #Pull the glacier multipart upload id out
    MULTIPART_ID=$GLACIER listmultiparts $AWS_VAULT | $GREP $LINCREMENTAL | $CUT --bytes=3-94
    $GLACIER upload --uploadid $MULTIPART_ID $AWS_VAULT $UPLOAD
fi

#Clean up
$RM -fv $READY_LOCK_FILE
$RM -fv $UPLOAD

#Test plan for this script:
#single run success -done
#dead before touch lockfile, then restart
#dead after upload started, then restart
#dead after upload resumed, then restart
#resume sucess
#dead after touch, but *before* upload started