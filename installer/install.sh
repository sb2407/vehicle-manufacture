#!/bin/bash
BASEDIR=$(dirname "$0")

if [ $BASEDIR = '.' ]
then
    BASEDIR=$(pwd)
elif [ $BASEDIR:1:2 = './' ]
then
    BASEDIR=$(pwd)${BASEDIR:1}
elif [ $BASEDIR:1:1 = '/' ]
then
    BASEDIR=$(pwd)${BASEDIR}
else
    BASEDIR=$(pwd)/${BASEDIR}
fi

DOCKER_COMPOSE_DIR=$BASEDIR/network/docker-compose
CRYPTO_CONFIG=$BASEDIR/network/crypto-material/crypto-config

echo "################"
echo "# GENERATE CRYPTO"
echo "################"
docker-compose -f $DOCKER_COMPOSE_DIR/docker-compose-cli.yaml up -d

docker exec cli cryptogen generate --config=/etc/hyperledger/config/crypto-config.yaml --output /etc/hyperledger/config/crypto-config
docker exec cli configtxgen -profile ThreeOrgsOrdererGenesis -outputBlock /etc/hyperledger/config/genesis.block
docker exec cli configtxgen -profile ThreeOrgsChannel -outputCreateChannelTx /etc/hyperledger/config/channel.tx -channelID vehiclemanufacture
docker exec cli cp /etc/hyperledger/fabric/core.yaml /etc/hyperledger/config
docker exec cli sh /etc/hyperledger/config/rename_sk.sh

docker-compose -f $DOCKER_COMPOSE_DIR/docker-compose-cli.yaml down --volumes

echo "################"
echo "# SETUP NETWORK"
echo "################"
docker-compose -f $DOCKER_COMPOSE_DIR/docker-compose.yaml -p node up -d

echo "################"
echo "# CHANNEL INIT"
echo "################"
docker exec arium_cli peer channel create -o orderer.example.com:7050 -c vehiclemanufacture -f /etc/hyperledger/configtx/channel.tx --outputBlock /etc/hyperledger/configtx/vehiclemanufacture.block
sleep 5
docker exec arium_cli peer channel join -b /etc/hyperledger/configtx/vehiclemanufacture.block --tls true --cafile /etc/hyperledger/config/crypto/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
docker exec vda_cli peer channel join -b /etc/hyperledger/configtx/vehiclemanufacture.block --tls true --cafile /etc/hyperledger/config/crypto/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
docker exec princeinsurance_cli peer channel join -b /etc/hyperledger/configtx/vehiclemanufacture.block --tls true --cafile /etc/hyperledger/config/crypto/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem

echo "################"
echo "# CHAINCODE INSTALL"
echo "################"
docker exec arium_cli bash -c "apk add nodejs nodejs-npm python make g++"
docker exec arium_cli bash -c 'cd /etc/hyperledger/contract; npm install; npm run build'

read -p "PLEASE SETUP THE CHAINCODE CONTAINER MANUALLY THEN PRESS ENTER"

docker exec arium_cli peer chaincode install -l node -n vehicle-manufacture-chaincode -v 0 -p /etc/hyperledger/contract
docker exec vda_cli peer chaincode install -l node -n vehicle-manufacture-chaincode -v 0 -p /etc/hyperledger/contract
docker exec princeinsurance_cli  peer chaincode install -l node -n vehicle-manufacture-chaincode -v 0 -p /etc/hyperledger/contract

echo "################"
echo "# CHAINCODE INSTANTIATE"
echo "################"
docker exec arium_cli peer chaincode instantiate -o orderer.example.com:7050 -l node -C vehiclemanufacture -n vehicle-manufacture-chaincode -v 0 -c '{"Args":[]}' -P 'AND ("AriumMSP.member", "VDAMSP.member", "PrinceInsuranceMSP.member")'

echo "################"
echo "# BUILD WALLET API"
echo "################"
cd $BASEDIR/../wallet-api
npm install
npm run build
cd $BASEDIR

echo "################"
echo "# BUILD CLI_TOOLS"
echo "################"
cd $BASEDIR/cli_tools
npm install
npm run build
cd $BASEDIR

echo "################"
echo "# SETUP WALLET"
echo "################"
LOCAL_FABRIC=$BASEDIR/vehiclemanufacture_fabric
ARIUM_CONNECTION=$LOCAL_FABRIC/arium_connection.json
VDA_CONNECTION=$LOCAL_FABRIC/vda_connection.json
PRINCE_CONNECTION=$LOCAL_FABRIC/prince_connection.json

mkdir -p $LOCAL_FABRIC/wallet
sed -e 's/{{LOC_ORG_ID}}/Arium/g' $BASEDIR/network/connection.tmpl > $ARIUM_CONNECTION
sed -e 's/{{LOC_ORG_ID}}/VDA/g' $BASEDIR/network/connection.tmpl > $VDA_CONNECTION
sed -e 's/{{LOC_ORG_ID}}/PrinceInsurance/g' $BASEDIR/network/connection.tmpl > $PRINCE_CONNECTION

echo "################"
echo "# ENROLLING ADMINS"
echo "################"
ARIUM_ADMIN_CERT=$BASEDIR/tmp/arium_cert.pem
ARIUM_ADMIN_KEY=$BASEDIR/tmp/arium_key.pem

VDA_ADMIN_CERT=$BASEDIR/tmp/vda_cert.pem
VDA_ADMIN_KEY=$BASEDIR/tmp/vda_key.pem

PRINCE_ADMIN_CERT=$BASEDIR/tmp/prince_cert.pem
PRINCE_ADMIN_KEY=$BASEDIR/tmp/prince_key.pem

mkdir $BASEDIR/tmp

FABRIC_CA_CLIENT_HOME=/root/fabric-ca/clients/admin

docker exec ca0.example.com bash -c "FABRIC_CA_CLIENT_HOME=$FABRIC_CA_CLIENT_HOME fabric-ca-client enroll -u http://admin:adminpw@ca0.example.com:7054"
docker exec ca0.example.com bash -c "cd $FABRIC_CA_CLIENT_HOME/msp/keystore; find ./ -name '*_sk' -exec mv {} key.pem \;"
docker cp ca0.example.com:$FABRIC_CA_CLIENT_HOME/msp/signcerts/cert.pem $BASEDIR/tmp
docker cp ca0.example.com:$FABRIC_CA_CLIENT_HOME/msp/keystore/key.pem $BASEDIR/tmp

mv $BASEDIR/tmp/cert.pem $ARIUM_ADMIN_CERT
mv $BASEDIR/tmp/key.pem $ARIUM_ADMIN_KEY

docker exec ca1.example.com bash -c "FABRIC_CA_CLIENT_HOME=$FABRIC_CA_CLIENT_HOME fabric-ca-client enroll -u http://admin:adminpw@ca1.example.com:7054"
docker exec ca1.example.com bash -c "cd $FABRIC_CA_CLIENT_HOME/msp/keystore; find ./ -name '*_sk' -exec mv {} key.pem \;"
docker cp ca1.example.com:$FABRIC_CA_CLIENT_HOME/msp/signcerts/cert.pem $BASEDIR/tmp
docker cp ca1.example.com:$FABRIC_CA_CLIENT_HOME/msp/keystore/key.pem $BASEDIR/tmp

mv $BASEDIR/tmp/cert.pem $VDA_ADMIN_CERT
mv $BASEDIR/tmp/key.pem $VDA_ADMIN_KEY

docker exec ca2.example.com bash -c "FABRIC_CA_CLIENT_HOME=$FABRIC_CA_CLIENT_HOME fabric-ca-client enroll -u http://admin:adminpw@ca2.example.com:7054"
docker exec ca2.example.com bash -c "cd $FABRIC_CA_CLIENT_HOME/msp/keystore; find ./ -name '*_sk' -exec mv {} key.pem \;"
docker cp ca2.example.com:$FABRIC_CA_CLIENT_HOME/msp/signcerts/cert.pem $BASEDIR/tmp
docker cp ca2.example.com:$FABRIC_CA_CLIENT_HOME/msp/keystore/key.pem $BASEDIR/tmp

mv $BASEDIR/tmp/cert.pem $PRINCE_ADMIN_CERT
mv $BASEDIR/tmp/key.pem $PRINCE_ADMIN_KEY

echo "################"
echo "# ENROLLING VEHICLE MANUFACTURE USERS"
echo "################"

CLI_DIR=$BASEDIR/cli_tools

ARIUM_USERS=$BASEDIR/users/arium.json
VDA_USERS=$BASEDIR/users/vda.json
PRINCE_USERS=$BASEDIR/users/prince-insurance.json

node $CLI_DIR/dist/index.js import -w $LOCAL_FABRIC/wallet -m AriumMSP -n admin -c $ARIUM_ADMIN_CERT -k $ARIUM_ADMIN_KEY -o Arium
node $CLI_DIR/dist/index.js import -w $LOCAL_FABRIC/wallet -m VDAMSP -n admin -c $VDA_ADMIN_CERT -k $VDA_ADMIN_KEY -o VDA
node $CLI_DIR/dist/index.js import -w $LOCAL_FABRIC/wallet -m PrinceInsuranceMSP -n admin -c $PRINCE_ADMIN_CERT -k $PRINCE_ADMIN_KEY -o PrinceInsurance

node $CLI_DIR/dist/index.js enroll -w $LOCAL_FABRIC/wallet -c $ARIUM_CONNECTION -u $ARIUM_USERS -a admin -o Arium
node $CLI_DIR/dist/index.js enroll -w $LOCAL_FABRIC/wallet -c $VDA_CONNECTION -u $VDA_USERS -a admin -o VDA
node $CLI_DIR/dist/index.js enroll -w $LOCAL_FABRIC/wallet -c $PRINCE_CONNECTION -u $PRINCE_USERS -a admin -o PrinceInsurance

echo "################"
echo "# STARTUP APPS"
echo "################"

APPS_DIR=$BASEDIR/../apps2

INSURER_DIR=$APPS_DIR/insurer
CAR_BUILDER_DIR=$APPS_DIR/car_builder
MANUFACTURERER_DIR=$APPS_DIR/manufacturer

cd $APPS_DIR/common
npm install
# npm run build
cd $BASEDIR

echo "#######################"
echo "# STARTUP CAR_BUILDER #"
echo "#######################"

cd $CAR_BUILDER_DIR
cd client
npm install
npm run build
cd ../server
npm install
npm run build
# npm start > $BASEDIR/tmp/car_builder.log 2>&1 &
nodemon > $BASEDIR/tmp/car_builder.log 2>&1 &

cd $BASEDIR

echo "###################"
echo "# STARTUP INSURER #"
echo "###################"

cd $INSURER_DIR
npm install
npm run build
# npm start > $BASEDIR/tmp/insurer.log 2>&1 &
nodemon > $BASEDIR/tmp/insurer.log 2>&1 &

echo "########################"
echo "# STARTUP MANUFACTURER #"
echo "########################"

cd $MANUFACTURERER_DIR
npm install
npm run build
# npm start > $BASEDIR/tmp/manufacturer.log 2>&1 &
nodemon > $BASEDIR/tmp/manufacturer.log 2>&1 &

CAR_BUILD_PORT=8100
ARIUM_REST_PORT=6001
VDA_REST_PORT=6002
PRINCE_REST_PORT=4200

cd $BASEDIR
for PORT in $ARIUM_REST_PORT $PRINCE_REST_PORT $CAR_BUILDER_PORT #$VDA_REST_PORT 
do
    printf "WAITING FOR REST SERVER ON PORT $PORT"
    until $(curl --output /dev/null --silent --head --fail http://localhost:$PORT);
    do
        printf '.'
        sleep 2
    done
    printf '\n'
done

echo "##################################"
echo "# REGISTER EVERYONE IN CHAINCODE #"
echo "##################################"

VDA_REGISTER="$VDA_REST_PORT|regulator|$VDA_USERS"
PRINCE_REGISTER="$PRINCE_REST_PORT|insurer|$PRINCE_USERS"
ARIUM_REGISTER="$ARIUM_REST_PORT|manufacturer|$ARIUM_USERS"

for REGISTRATION in $PRINCE_REGISTER $ARIUM_REGISTER #$VDA_REGISTER
do
    PORT="$(cut -d'|' -f1 <<<"$REGISTRATION")"
    TYPE="$(cut -d'|' -f2 <<<"$REGISTRATION")"
    USER_LIST="$(cut -d'|' -f3 <<<"$REGISTRATION")"

    echo "REGISTERING TYPE $TYPE"
    if [ "$TYPE" == "manufacturer" ]; then # Special case for manufacturer
        curl -X POST -H "Content-Type: application/json" -d '{"originCode": "S", "manufacturerCode": "G"}' -u registrar:registrarpw http://localhost:$PORT/api/users/registrar/register
    else
        curl -X POST -H "Content-Type: application/json" -d '{}' -u registrar:registrarpw http://localhost:$PORT/api/users/registrar/register
    fi

    for row in $(jq -r ".[] | .name" $USER_LIST); do # GET ALL OF TYPE PEOPLE FROM JSON
        if [ "$row" != "registrar" ]; then

            echo "REGISTERING USER $row"

            ATTRS="["

            for attr in $(jq -r '[.[] | select(.name == "'"$row"'") | .attrs[] | select(.name | contains("vehicle_manufacture.role."))] | .[] | .name' $USER_LIST); do
                ATTRS="$ATTRS\"$attr\","
            done

            if [ "$ATTRS" != "[" ]; then
                ATTRS=${ATTRS%?}
            fi

            ATTRS="$ATTRS]"

            curl -X POST -H "Content-Type: application/json" -d '{"name":"'"$row"'", "roles": '"$ATTRS"'}' -u registrar:registrarpw http://localhost:$PORT/api/users/task/register
        fi
    done
done

echo "################"
echo "# DONE"
echo "################"
