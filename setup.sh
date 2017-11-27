#!/bin/bash

status_check_timeout=20

# Check for kubeconfig
if [[ ! -s $HOME/.kube/config ]]; then
	echo "cannot find kube config"
	exit 1
fi

# Check if oc client is installed
which oc &>/dev/null
if [[ $? != 0 ]]; then
	echo "oc client is not installed"
	echo "installing oc client"
 	curl -L https://github.com/openshift/origin/releases/download/v1.2.1/openshift-origin-client-tools-v1.2.1-5e723f6-linux-64bit.tar.gz | tar -zx && \
    	mv openshift*/oc /usr/local/bin && \
	rm -rf openshift-origin-client-tools-*
fi

# pod status check
function pod_status_check() {
	namespace=$1
	counter=1
	echo "checking the pod status"
	for pod in $(kubectl get pods --namespace=$namespace | awk 'NR > 1 {print $1}'); do
        	while [ $(kubectl --namespace=$namespace get pods $pod -o json | jq -r ".status.phase") != "Running" ]; do
        		sleep 1
			counter=$((counter+1))
			if [[ $counter > $status_check_timeout ]]; then
				echo "$pod is not in running state after waiting for $counter seconds, please check the pod logs and events"
				exit 1
			fi
        	done
        	echo "$pod is up and running"
	done
}

# cleanup
function cleanup() {
        oc delete -f openshift_templates/performance_monitoring/pbench/pbench-agent-daemonset.yml
	# sleep for 20 seconds for the pods to get terminated
	echo "Waiting for 20 seconds for the pods to get terminated" 
	sleep 20
}

# Create a service account and add it to the privileged scc
function create_service_account() {
        oc create serviceaccount useroot
        oc adm policy add-scc-to-user privileged -z useroot
}

# get the jump host, collectd credentials
# Check for credentials as environment variables
if [[ -z $GRAPHITE_HOST ]]; then
	echo "GRAPHITE_HOST is not defined, please define it as env variable"
	exit 1
fi
if [[ -z $GRAPHITE_PREFIX ]]; then
	echo "GRAPHITE_PREFIX is not defined, please define it as env variable"
        exit 1
if
if [[ -z $COLLECTD_INTERVAL ]]; then
        echo "COLLECTD_INVERVAL is not defined, please define it as env variable"
	exit 1
if
	
pushd /root/svt

# Setup collecd in collectd namespace
oc new-project collectd
create_service_account

# Set the variables in configmap
sed -i "/host/c \  Host \"${GRAPHITE_HOST}\"" openshift_templates/performance_monitoring/collectd/collectd-config.yml
sed -i "/prefix/c \  prefix  \"${graphite_PREFIX}\"" openshift_templates/performance_monitoring/collectd/collectd-config.yml
sed -i "/interval/c \  interval \"${COLLECTD_INTERVAL}\"" openshift_templates/performance_monitoring/collectd/collectd-config.yml

# Create configmap to feed credentials in to collectd pod
oc create -f openshift_templates/performance_monitoring/collectd/collectd-config.yml

# Create collectd pods and patch it
oc create -f openshift_templates/performance_monitoring/collectd/collectd-daemonset.yml
oc patch daemonset collectd --patch \ '{"spec":{"template":{"spec":{"serviceAccountName": "useroot"}}}}'


# Setup pbench-agent in pbench namespace
oc new-project pbench
create_service_account

# Create pbench-agent pods and patch it
oc create -f openshift_templates/performance_monitoring/pbench/pbench-agent-daemonset.yml
oc patch daemonset pbench-agent --patch \ '{"spec":{"template":{"spec":{"serviceAccountName": "useroot"}}}}'

popd

echo "Checking if jq is installed"
if ! jq &> /dev/null; then
        echo "jq not installed"
        echo "Downloading jq"
        wget http://stedolan.github.io/jq/download/linux64/jq
        chmod +x jq
        mv jq /usr/bin/
        echo "jq installed successfully"
else
        echo "jq already present"
fi

# Check if the pbench pods are running
pod_status_check pbench

# Check if the collectd pods are running
pod_status_check collectd
