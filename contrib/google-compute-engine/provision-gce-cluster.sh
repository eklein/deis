#!/usr/bin/env bash

set -e

THIS_DIR=$(cd $(dirname $0); pwd)
CONTRIB_DIR=$(dirname $THIS_DIR)

source $CONTRIB_DIR/utils.sh

if ! which gcloud > /dev/null; then
	echo_red "Please set up the google compute engine toolkit and ensure it is in your \$PATH."
	exit 1
fi

# I like the us-central1-a zone
if [ -z "$GCE_REGION" ]; then
	GCE_REGION="us-central1-a"
fi

# Defaultly use 3 instances
if [ -z "$DEIS_NUM_INSTANCES" ]; then
	DEIS_NUM_INSTANCES=3
fi

# check that the CoreOS user-data file is valid
$CONTRIB_DIR/util/check-user-data.sh

# We need to edit the userdata file :(
USER_DATA_FILE="$$.cloudconfig.yaml"
python ./hack-userdata.py $CONTRIB_DIR/coreos/user-data $USER_DATA_FILE

echo "USER_DATA_FILE = $USER_DATA_FILE"

# Create the cluster
for ((i=1;i<=$DEIS_NUM_INSTANCES;i++))
do
	gcutil adddisk --zone $GCE_REGION --size_gb 32 deis-$i
	gcutil addinstance --image "projects/coreos-cloud/global/images/coreos-alpha-386-1-0-v20140723" --persistent_boot_disk --zone $GCE_REGION --machine_type n1-standard-2 --tags deis --metadata_from_file user-data:$USER_DATA_FILE --disk deis-$i,deviceName=coredocker --authorized_ssh_keys=core:~/.ssh/deis.pub,`whoami`:~/.ssh/google_compute_engine.pub deis$i;
done

rm $USER_DATA_FILE

# Firewall rules
if gcutil addfirewall deis-router --target_tags deis --allowed "tcp:80,tcp:2222,tcp:22" 2>&1 > /dev/null; then
	echo_green "Firewall rules added!"
fi

echo_green "Your Deis cluster has successfully deployed to Google Compute Engine."
echo_green "Please continue to follow the instructions in the README."

