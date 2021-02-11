#!/usr/bin/env bash
# set -o errexit
# set -o nounset
# set -o pipefail
set -e
# hack to initialize gradle
./gradlew tasks -q >>/dev/null 2>&1
# environment to publish to
echo "Running.."
type=$1
testId=""
authHeader=""
proxyUUID=""
papi_bundle_uri="/policy-management/0.1/gateway-bundles"
papi_deployment_uri="/deployments/0.1/gateway-bundles"
papi_proxy_uri="/deployments/1.0/proxies"
papi_token_uri="/auth/oauth/v2/token"

projects=$(./gradlew getSubProjects -q --warning-mode none)
projectArr=($(echo $projects | tr ";" "\n"))
exclusions=$(./gradlew getExclusions -q --warning-mode none)
exclusionsArr=($(echo $exclusions | tr ";" "\n"))

RemoveExclusions() {
    for i in "${!exclusions[@]}"; do
        find ./ -type f -iname "${exclusions[$i]}.yml" -delete
    done
}

BuildAndDeployEnv() {
    for i in "${!projectArr[@]}"; do
        echo "${projectArr[$i]} going into env"
        if [[ "${projectArr[$i]}" == *"-env"* ]] || [[ "${projectArr[$i]}" == "common" ]]; then
            echo "${projectArr[$i]} getting built as env"
            # check versions and see if there any updates... but for now build and publish
            echo "Building Environment Bundle: ${projectArr[$i]}"
            ./gradlew ${projectArr[$i]}:build-environment-bundle -q
            echo "Publishing: ${projectArr[$i]}"
            if [[ "$type" == "direct" ]]; then
                ./gradlew ${projectArr[$i]}:import-bundle -PenvironmentType=$1 -PgatewayURL=$2 -PgatewayUsername=$3 -PgatewayPassword=$4 -q
            else
                version=$(./gradlew ${projectArr[$i]}:getCurrentVersion -q)
                preflight=($(PreflightChecks $2 $3 ${projectArr[$i]}))

                IFS=':' read -a preflight <<<"${preflight}"

                if [[ "${preflight[1]}" == *"$version"* ]]; then
                    echo "${projectArr[$i]^^} is already present on ${3^^} @version:$version"
                    # Check where it's deployed... and deploy it if not already deployed...
                else
                    echo "${projectArr[$i]^^} is not present on ${3^^} @version:$version"
                    # If preflight is empty then the bundle does not exist... create it.
                    metadata="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-environment-$version-env.metadata.yml;type=text/yml"
                    installBundle="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-environment-$version-env.install.bundle;type=application/octet-stream"
                    deleteBundle="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-environment-$version-env.delete.bundle;type=application/octet-stream"

                    bundleUUID=$(curl -s -H "$authHeader" -H "accept: application/json;charset=UTF-8" -XPOST ${2%/}/$3$papi_bundle_uri -H "Content-Type: multipart/form-data" -F $metadata -F $installBundle -F $deleteBundle | jq -r .uuid)

                    if [[ ! -z "$preflight" ]] && [[ "${preflight[1]}" != *"$version"* ]]; then
                        # if bundle already exists then we need to update deployment....papi_deployment_uri
                        echo "Updating ${projectArr[$i]^^} on ${3^^} to the latest version"
                        status=$(curl -s -XPUT -H "Content-Type: application/json;charset=UTF-8" -H "$authHeader" "${2%/}/$3$papi_deployment_uri/$bundleUUID/proxies/$proxyUUID" -d '{ "message": "string","status": "PENDING_DEPLOYMENT"}' jq -r .status)
                        echo "${projectArr[$i]^^} $status on ${3^^}"
                    else
                        echo "Deploying ${projectArr[$i]^^} to ${3^^} for the first time"
                        status=$(curl -s -H "$authHeader" -H "Content-Type:application/json" -XPOST "${2%/}/$3$papi_deployment_uri/$bundleUUID/proxies" --data '{ "proxyUuid": "'$proxyUUID'"}' | jq -r .status)
                        echo "${projectArr[$i]^^} $status on ${3^^}"
                    fi

                fi

            fi
        fi
    done
}

BuildAndDeployServices() {
    for i in "${!projectArr[@]}"; do
        if [[ "${projectArr[$i]}" != *"-env"* ]] && [[ "${projectArr[$i]}" != "common" ]]; then
            echo "Building: ${projectArr[$i]}"
            ./gradlew ${projectArr[$i]}:build -q
            echo "Publishing: ${projectArr[$i]}"
            if [[ "$type" == "direct" ]]; then
                ./gradlew ${projectArr[$i]}:import -PenvironmentType=$1 -PgatewayURL=$2 -PgatewayUsername=$3 -PgatewayPassword=$4
            else

                #echo "deploy to portal..."
                version=$(./gradlew ${projectArr[$i]}:getCurrentVersion -q)
                preflight=($(PreflightChecks $2 $3 ${projectArr[$i]}))

                IFS=':' read -a preflight <<<"${preflight}"

                if [[ "${preflight[1]}" == *"$version"* ]]; then
                    echo "${projectArr[$i]^^} is already present on ${3^^} @version:$version"
                    # Check where it's deployed... and deploy it if not already deployed...
                else
                    echo "${projectArr[$i]^^} is not present on ${3^^} @version:$version"
                    # If preflight is empty then the bundle does not exist... create it.
                    echo "${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-$version.metadata.yml;type=text/yml"
                    metadata="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-$version.metadata.yml;type=text/yml"
                    installBundle="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-$version.install.bundle;type=application/octet-stream"
                    deleteBundle="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-$version.delete.bundle;type=application/octet-stream"

                    bundleUUID=$(curl -s -H "$authHeader" -H "accept: application/json;charset=UTF-8" -XPOST ${2%/}/$3$papi_bundle_uri -H "Content-Type: multipart/form-data" -F $metadata -F $installBundle -F $deleteBundle) # | jq -r .uuid)
                    echo $bundleUUID
                    if [[ ! -z "$preflight" ]] && [[ "${preflight[1]}" != *"$version"* ]]; then
                        # if bundle already exists then we need to update deployment....papi_deployment_uri
                        echo "Updating ${projectArr[$i]^^} on ${3^^} to the latest version"
                        status=$(curl -s -XPUT -H "Content-Type: application/json;charset=UTF-8" -H "$authHeader" "${2%/}/$3$papi_deployment_uri/$bundleUUID/proxies/$proxyUUID" -d '{ "message": "string","status": "PENDING_DEPLOYMENT"}' | jq -r .status)
                        echo "${projectArr[$i]^^} $status on ${3^^}"
                    else
                        echo "Deploying ${projectArr[$i]^^} to ${3^^} for the first time"
                        status=$(curl -s -H "$authHeader" -H "Content-Type:application/json" -XPOST "${2%/}/$3$papi_deployment_uri/$bundleUUID/proxies" --data '{ "proxyUuid": "'$proxyUUID'"}' | jq -r .status)
                        echo "${projectArr[$i]^^} $status on ${3^^}"
                    fi

                fi

            fi

        fi
    done
}

# Test
RunFunctionalTests() {
    result=""
    #Running Test
    test=$(curl -s "https://a.blazemeter.com/api/v4/tests/$testId/start" -X POST -H 'Content-Type: application/json' --user "$apiId:$apiSecret")
    mId=$(echo $test | jq -r .result.id)
    testName=$(echo $test | jq -r .result.name)
    echo "Test: $testName started"
    echo "Waiting for results.."
    sleep 10

    # Try the results API 10 times then fail...
    for i in {1..10}; do
        result=$(curl -s "https://a.blazemeter.com/api/v4/masters/${mId}/reports/functional/groups" --user "$apiId:$apiSecret")
        resultArr=$(echo $result | jq -r .result)
        if [ "$resultArr" == "[]" ]; then
            echo "Results not ready yet, retrying in 10 seconds.."
            sleep 10
        else
            break
        fi
    done

    if [ -z "$resultArr" ]; then
        echo "Unable to retrieve test results after 10 attempts."
        exit 1
    else
        assertionCount=$(echo $result | jq -r '.result[0].summary.assertions.count')
        assertionPassed=$(echo $result | jq -r '.result[0].summary.assertions.passed')

        if [ $assertionCount == $assertionPassed ]; then
            echo "All tests have passed, continuing.."
            exit 0
        else
            echo "There are $assertionCount assertions and only $assertionPassed have passed.. this is considered a failure."
            exit 1
        fi

    fi
}

RetrieveAccessToken() {
    echo "Retrieving PAPI Access Token"
    access_token=$(curl -s --user $1:$2 -H "Content-Type:application/x-www-form-urlencoded" ${3%/}$papi_token_uri --data 'grant_type=client_credentials' | jq -r .access_token)
    authHeader="Authorization: Bearer ${access_token}"
}

RetrieveProxyUUID() {
    echo "Retrieving Proxy UUID"
    #echo $authHeader
    proxyUUID=$(curl -s -H "$authHeader" -XGET ${1%/}/$2$papi_proxy_uri | jq -r --arg proxyName $3 '.[] | select(.name==$proxyName).uuid')
    #echo $proxyUUID # | jq -r --arg proxyName $3 '.[] | select(.name==$proxyName).uuid'
}

PreflightChecks() {
    bundle=$(curl -sk --header "$authHeader" --request GET ${1%/}/$2$papi_bundle_uri?name=$3)
    bundleUUID=$(echo $bundle | jq -r --arg moduleName $3 '.results[] | select(.moduleName==$moduleName).uuid')

    if [[ ! -z "$bundleUUID" ]]; then
        version=$(echo $bundle | jq -r --arg moduleName $3 '.results[] | select(.moduleName==$moduleName).version')
    else
        bundle=""
    fi

    if [[ ! -z $bundle ]]; then
        echo "$bundleUUID:$version"
    fi
}

PreflightChecks1() {
    bundle=$(curl -sk --header "$authHeader" --request GET ${1%/}/$2$papi_bundle_uri?name=$3)
    bundleUUID=$(echo $bundle | jq -r --arg moduleName $3 '.results[] | select(.moduleName==$moduleName).uuid')

    if [[ ! -z "$bundleUUID" ]]; then
        version=$(echo $bundle | jq -r --arg moduleName $3 '.results[] | select(.moduleName==$moduleName).version')
    else
        bundle=""
    fi

    if [[ ! -z $bundle ]]; then
        echo "$bundleUUID:$version"
    fi
}

RemoveExclusions

SetEnvironmentDetails() {
    if [[ "$type" == "portal" ]]; then
        environment=$1
        tenantUrl=$2
        papiUrl=$3
        clientId=$4
        secret=$5
        apiId=$6
        apiSecret=$7
        testId=$8
        RetrieveAccessToken $clientId $secret $papiUrl
        tenantId=${tenantUrl#https://}
        tenantId=${tenantId%%.*}
        RetrieveProxyUUID $papiUrl $tenantId $environment
        PreflightChecks1 $papiUrl $tenantId "banking"
        #BuildAndDeployEnv $type $papiUrl $tenantId $environment
        BuildAndDeployServices $type $papiUrl $tenantId $environment
        #DeployToProxy
    else
        environment=$1
        gatewayUrl=$2
        gatewayUsername=$3
        gatewayPassword=$4
        apiId=$5
        apiSecret=$6
        testId=$7
        BuildAndDeployEnv $type $gatewayUrl $gatewayUsername $gatewayPassword
        BuildAndDeployServices $type $gatewayUrl $gatewayUsername $gatewayPassword
        RunFunctionalTests
    fi
}

SetEnvironmentDetails $2 $3 $4 $5 $6 $7 $8 $9
