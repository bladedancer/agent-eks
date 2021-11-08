#!/bin/bash

. ./env.sh

echo ========================
echo === Configure docker ===
echo ========================
kubectl create secret generic regcred \
    --from-file=.dockerconfigjson=$HOME/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson

echo ================================
echo === Creating Service Account ===
echo ================================

openssl genpkey -algorithm RSA -out private_key.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -pubout -in private_key.pem -out public_key.pem -outform pem
axway auth login
axway service-account remove $CLUSTER
ACC=$(axway service-account create --name $CLUSTER --public-key ./public_key.pem --json --role api_central_admin)

CLIENT_ID=$(echo $ACC | jq -r .client.client_id)
ORG_ID=$(echo $ACC | jq -r .org.id)


echo =============================
echo === Creating AmpGw Secret ===
echo =============================
kubectl delete secret ampgw-secret
kubectl create secret generic ampgw-secret \
    --from-file serviceAccPrivateKey=private_key.pem \
    --from-file serviceAccPublicKey=public_key.pem \
    --from-file listenerPrivateKey=star.ampgw.sandbox.axwaytest.net/privkey1.pem  \
    --from-file listenerCertificate=star.ampgw.sandbox.axwaytest.net/fullchain1.pem  \
    --from-literal orgId=$ORG_ID \
    --from-literal clientId=$CLIENT_ID


echo ============================
echo === Installing Dataplane ===
echo ============================
CREDS=$(cat ~/.docker/config.json | jq -r '.auths."axway.jfrog.io".auth' | base64 -d)
IFS=':'
read -a userpass <<< "$CREDS"
helm repo add --force-update ampc-rel https://axway.jfrog.io/artifactory/ampc-helm-release --username ${userpass[0]} --password ${userpass[1]}


cat << EOF > override.yaml
global:
  environment: $CLUSTER
  listenerPort: 8443
  exposeProxyAdminPort: true
  proxyAdminPort: 9001

imagePullSecrets:
  - name: regcred
ampgw-governance-agent:
  imagePullSecrets: 
    - name: regcred
  readinessProbe:
    timeoutSeconds: 5
ampgw-proxy:
  service:
    annotations:
        external-dns.alpha.kubernetes.io/hostname: $CLUSTER.ampgw.sandbox.axwaytest.net
        service.beta.kubernetes.io/aws-load-balancer-type: "external"
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  imagePullSecrets:
    - name: regcred
EOF

helm delete ampgw --wait
helm install ampgw ampc-rel/ampgw -f override.yaml --wait


echo ============================
echo === Waiting for all Pods ===
echo ============================
echo Turn off your VPN
kubectl wait --timeout 10m --for=condition=Complete jobs --all
