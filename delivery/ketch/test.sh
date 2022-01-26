#! /usr/bin/env bash

github_user=${1}
github_token=${2}

this_dir=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
root_dir=$(cd ${this_dir}/../.. && pwd)

if [[ -z "${SKIP_CLUSTER_SETUP}" ]]; then ${this_dir}/setup-cluster.sh; fi

namespace=podtato-ketch
kubectl create namespace ${namespace} --save-config &> /dev/null
kubectl config set-context --current --namespace=${namespace}

if [[ -n "${github_token}" && -n "${github_user}" ]]; then
    # ghcr secret in podtato-ketch
    kubectl delete secret ghcr &> /dev/null
    kubectl create secret docker-registry ghcr \
        --docker-server 'https://ghcr.io/' \
        --docker-username "${github_user}" \
        --docker-password "${github_token}"
    kubectl patch serviceaccount default \
        --patch '{ "imagePullSecrets": [{ "name": "ghcr" }]}'
fi

## get node address and port
INGRESS_PORT=$(kubectl get services -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
INGRESS_HOST=$(kubectl --namespace=ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

## add ketch framework
ketch framework list | grep -q framework1
if [[ $? != 0 ]]; then
    echo "----> ketch framework add:"
    ketch framework add framework1 \
        --namespace podtato-ketch \
        --app-quota-limit '-1' \
        --cluster-issuer selfsigned-cluster-issuer \
        --ingress-class-name nginx \
        --ingress-type nginx \
        --ingress-service-endpoint "${INGRESS_HOST}"
    ketch framework export framework1
fi

## add ketch app
## must login _locally_ for image push, _in cluster_ for image pull
echo "----> ketch app deploy:"
# docker login ghcr.io --username ${github_user} --password "${github_token}"
ketch app deploy podtato-head "${root_dir}/podtato-head-server" \
    --registry-secret ghcr \
    --builder gcr.io/buildpacks/builder:v1 \
    --framework framework1 \
    --ketch-yaml ${this_dir}/ketch.yaml \
    --image ghcr.io/${github_user}/podtato-head/ketch-main:latest \
    --env "STATIC_DIR=/workspace/static/"

echo "----> ketch app info:"
ketch app info podtato-head

echo "----> awaiting deployment available..."
sleep 3
kubectl wait --for=condition=Available deployment --selector 'theketch.io/app-name==podtato-head' --timeout=60s

## test ketch app
INGRESS_HOSTNAME=$(ketch app info podtato-head | grep '^Address' | sed -E 's/.*https?\:\/\/(.*)$/\1/')
echo "----> testing deployment at http://${INGRESS_HOSTNAME}:${INGRESS_PORT}/"
curl http://${INGRESS_HOSTNAME}:${INGRESS_PORT}/
echo ""
# curl http://${INGRESS_HOST}:${INGRESS_PORT}/
