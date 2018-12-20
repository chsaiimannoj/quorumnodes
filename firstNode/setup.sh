#!/bin/bash

#
# Create all the necessary scripts, keys, configurations etc. to run
# a cluster of N Quorum nodes with Raft consensus.
#
# The nodes will be in Docker containers. List the IP addresses that
# they will run at below (arbitrary addresses are fine).
#
# Run the cluster with "docker-compose up -d"
#
# Run a console on Node N with "geth attach qdata_N/dd/geth.ipc"
# (assumes Geth is installed on the host.)
#
# Geth and Constellation logfiles for Node N will be in qdata_N/logs/
#

# TODO: check file access permissions, especially for keys.


#### Configuration options #############################################
read -p "Please enter public IP of this host machine : " node_ip
ips=("$node_ip")

read -p "Enter Node Number (e.g. 4) : " node_nbr
node_number=("$node_nbr")
# Docker image name
image=quorum

########################################################################

nnodes=${#ips[@]}

./cleanup.sh

uid=`id -u`
gid=`id -g`
pwd=`pwd`

#### Create directories for each node's configuration ##################

echo '[1] Configuring for '$nnodes' nodes.'

n=1
for ip in ${ips[*]}
do
    qd=qdata_$n
    mkdir -p $qd/{logs,keys}
    mkdir -p $qd/dd/{geth,keystore}

    let n++
done


#### Make static-nodes.json and store keys #############################

echo '[2] Creating Enodes and static-nodes.json.'

echo "[" > static-nodes.json
echo "[" > enode-url.json
n=1
for ip in ${ips[*]}
do
    qd=qdata_$n

    # Generate the node's Enode and key
    docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/bootnode -genkey /qdata/dd/nodekey -writeaddress
    key=$(cat $pwd/$qd/dd/nodekey)
    enode=`docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/bootnode -nodekeyhex $key -writeaddress`
    # Add the enode to static-nodes.json
    sep=`[[ $n < $nnodes ]] && echo ","`
    echo '  "enode://'$enode'@'$ip':30303?discport=0&raftport=50400"'$sep >> static-nodes.json

    # Add the enode to enode-url.json
    sep=`[[ $n < $nnodes ]] && echo ","`
    echo '  "enode://'$enode'@'$ip':30303?discport=0&raftport=50400"'$sep >> enode-url.json
    echo '  [*] Login to geth console of any node of existing cluster & run the following command:'
    echo '  raft.addPeer("enode://'$enode'@'$ip':30303?discport=0&raftport=50400")'

    let n++
done
echo "]" >> enode-url.json
echo "]" >> static-nodes.json


#### Create accounts, keys and genesis.json file #######################

echo '[3] Creating Ether accounts and genesis.json.'
touch qdata_1/passwords.txt
cat >> genesis.json <<EOF
{
  "alloc": {
    "e722b5d8affd183b3b26983817a49f84223b39da": {
      "balance": "1000000000000000000000000000"
    }
  },
  "coinbase": "0x0000000000000000000000000000000000000000",
  "config": {
    "homesteadBlock": 0
  },
  "difficulty": "0x0",
  "extraData": "0x",
  "gasLimit": "0x2FEFD800",
  "mixhash": "0x00000000000000000000000000000000000000647572616c65787365646c6578",
  "nonce": "0x0",
  "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "timestamp": "0x00"
}
EOF

cat >> UTC--2018-12-17T14-13-25.726081617Z--e722b5d8affd183b3b26983817a49f84223b39da <<EOF
{
   "address":"e722b5d8affd183b3b26983817a49f84223b39da",
   "crypto":{
      "cipher":"aes-128-ctr",
      "ciphertext":"d50d89c50b371cc5456cae8ff62c7acf3d9125f78a839a9b1b76e1dbe6428a35",
      "cipherparams":{
         "iv":"2be27d9cfed6cd5dfe8dfddc4fb0b83a"
      },
      "kdf":"scrypt",
      "kdfparams":{
         "dklen":32,
         "n":262144,
         "p":1,
         "r":8,
         "salt":"fcc71fd2bb72daf2a6f4a3980991f0076ea2829e8a61b632ad6de052703dc185"
      },
      "mac":"d80bb3e1a4dcb28f36cce5242e480cfde2d41ba95fed45d1eea92ec575fe50fc"
   },
   "id":"755dddfd-88f5-4ba6-99de-dfbc293ad595",
   "version":3
}
EOF

#### Complete each node's configuration ################################

echo '[4] Creating Quorum keys and finishing configuration.'

n=1
for ip in ${ips[*]}
do
    qd=qdata_$n

    cat tm.conf \
        | sed s/_NODELIST_/$ip/g \
        | sed s/_NODEIP_/$ip/g \
              > $qd/tm.conf

    cp genesis.json $qd/genesis.json
    cp static-nodes.json $qd/dd/static-nodes.json
    cp UTC--2018-12-17T14-13-25.726081617Z--e722b5d8affd183b3b26983817a49f84223b39da $qd/dd/keystore/

    # Generate Quorum-related keys (used by Constellation)
    docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/constellation-node --generatekeys=qdata/keys/tm < /dev/null > /dev/null
    echo 'Node '$n' public key: '`cat $qd/keys/tm.pub`

    cat start-node.sh \
        | sed s/_RAFTID_/$node_number/g \
              > $qd/start-node.sh

    chmod 755 $qd/start-node.sh

    let n++
done
rm -rf genesis.json static-nodes.json UTC--2018-12-17T14-13-25.726081617Z--e722b5d8affd183b3b26983817a49f84223b39da


#### Create the docker-compose file ####################################

cat > docker-compose.yml <<EOF
version: '2'
services:
EOF

n=1
for ip in ${ips[*]}
do
    qd=qdata_$n

    cat >> docker-compose.yml <<EOF
  node_$n:
    image: $image
    volumes:
      - './$qd:/qdata'
    ports:
      - 22000:22000
      - 9000:9000
      - 21000:30303
      - 50400:50400
EOF

    let n++
done


echo '[5] Removing temporary containers.'
# Remove temporary containers created for keys & enode addresses - Note this will remove ALL stopped containers
docker container prune -f > /dev/null 2>&1