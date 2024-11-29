#!/bin/bash
#set -x -e

echo "###################### WARNING!!! ###################################"
echo "###   This script will perform the following operations:          ###"
echo "###   * check cluster and actual version                          ###"
echo "###   * download validator binaries                               ###"
echo "###   * wait for validator restart window                         ###"
echo "###   * restart validator service                                 ###"
echo "###   * wait for catchup                                          ###"
echo "###                                                               ###"
echo "###   *** Script provided by MAX_BLOK (Thank Margus)              ###"
echo "#####################################################################"
echo

PATH="/root/.local/share/solana/install/active_release/bin:$PATH"

#### Check current version 
identity=$(solana address)
validators=$(solana validators --output json)
while [ "$validators" == "" ];do
validators=$(solana validators --output json)
done
currentValidatorInfo=$(jq -r '.validators[] | select(.identityPubkey == '\"$identity\"')' <<<$validators)
delinquentValidatorInfo=$(jq -r '.validators[] | select(.identityPubkey == '\"$identity\"' and .delinquent == true)' <<<$validators)
current_version=$(jq -r '.version' <<<$currentValidatorInfo | sed 's/ /-/g')
if [ "$current_version" = "" ];then current_version="$(jq -r '.version' <<<$delinquentValidatorInfo | sed 's/ /-/g')"
fi
local_version=$(solana --version | awk '{ print $2 }')
if [ "$current_version" = "" ];then current_version="$local_version"
fi

networkrpcURL=$(cat $HOME/.config/solana/cli/config.yml | grep json_rpc_url | grep -o '".*"' | tr -d '"')
if [ "$networkrpcURL" == "" ];then
networkrpcURL=$(cat /root/.config/solana/cli/config.yml | grep json_rpc_url | awk '{ print $2 }')
fi

if [ $networkrpcURL = https://api.testnet.solana.com ];then
version="$(wget -q -4 -O- https://api.margus.one/solana/version/?cluster=testnet)"
maxdelinq=14
mintime=10
elif [ $networkrpcURL = https://api.mainnet-beta.solana.com ];then
version="$(wget -q -4 -O- https://api.margus.one/solana/version/?cluster=mainnet)"
maxdelinq=5
mintime=100
fi	

restart_validator() {
service_file=/root/solana/solana.service
LEDGER=$(cat $service_file | grep "\--ledger" | awk '{ print $2 }' )
SNAPSHOTS=$(cat $service_file | grep "\--snapshots" | awk '{ print $2 }' )
if [ "$SNAPSHOTS" == "" ]; then SNAPSHOTS=$LEDGER
fi
  if [ -d "$LEDGER" ];then
    agave-validator --ledger $LEDGER wait-for-restart-window --max-delinquent-stake $maxdelinq --min-idle-time $mintime
  fi
  systemctl restart solana
}

catchup_info() {
  while true; do
    rpcPort=$(ps aux | grep agave-validator | grep -Po "\-\-rpc\-port\s+\K[0-9]+")
    sudo -i -u root solana catchup --our-localhost $rpcPort
    status=$?
    if [ $status -eq 0 ];then
      exit 0
    fi
    echo "waiting next 30 seconds for rpc"
    sleep 30
  done
}

if [ "$current_version" != "$version" ];then
  if [ "$local_version" != "$version" ];then
    echo "Updating to version $version"
    sudo -i -u root agave-install init "$version"
  fi
fstrim -av >> /dev/null & \
restart_validator
else
  echo "We are already on version ${version}, doing nothing..."
fi
catchup_info
echo "Node successfully updated"


