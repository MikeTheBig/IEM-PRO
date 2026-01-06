#!/bin/bash

path=$(dirname "$0")

IEM_NAME=$1

mkdir -p "${path}"/out

openssl genrsa -out "${path}"/out/myCA.key 4096

openssl req -x509 -new -nodes -key "${path}"/out/myCA.key -sha256 -days 825 -out "${path}"/out/myCA.crt -config "${path}"/ca.conf

openssl genrsa -out "${path}"/out/myCert.key 4096

length=${#IEM_NAME}
if [ $length \> 63 ]
then 
    echo "WARNING: string too long for CN, will be adjusted"
    arrCN=(${IEM_NAME//./ })
    IEM_NAME_CN=*.${arrCN[-3]}.${arrCN[-2]}.${arrCN[-1]}
    echo "new CN $IEM_NAME_CN"
else 
    IEM_NAME_CN=$IEM_NAME
fi

openssl req -new -key "${path}"/out/myCert.key -out "${path}"/out/myCert.csr -subj "/C=DE/ST=Dummy/L=Dummy/O=Dummy/CN=$IEM_NAME_CN" -config <(cat "${path}"/cert.conf <(printf "\\n[alt_names]\\nDNS=%s" "${IEM_NAME}"))

openssl x509 -req -in "${path}"/out/myCert.csr -CA "${path}"/out/myCA.crt -CAkey "${path}"/out/myCA.key -CAcreateserial -out "${path}"/out/myCert.crt -days 825 -sha256 -extfile <(cat "${path}"/cert-ext.conf <(printf "\\n[alt_names]\\nDNS=%s" "${IEM_NAME}"))

cat "${path}"/out/myCert.crt "${path}"/out/myCA.crt > "${path}"/out/certChain.crt

rm "${path}"/out/myCert.csr "${path}"/out/myCA.srl
cp "${path}"/out/myCert.crt "${path}"/out/certChain.crt "$(pwd)"/
