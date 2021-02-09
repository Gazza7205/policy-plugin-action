#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
# hack to initialize gradle
./gradlew tasks -q >>/dev/null 2>&1
# environment to publish to
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
        if [[ "${projectArr[$i]}" == *"-env"* ]] || [[ "${projectArr[$i]}" == "common" ]]; then
            # check versions and see if there any updates... but for now build and publish
            echo "Building Environment Bundle: ${projectArr[$i]}"
            ./gradlew ${projectArr[$i]}:build-environment-bundle -q
            echo "Publishing: ${projectArr[$i]}"
            if [[ "$type" == "direct" ]]; then
                ./gradlew ${projectArr[$i]}:import-bundle -PenvironmentType=$environment -PgatewayURL=$gatewayUrl -PgatewayUsername=$gatewayUsername -PgatewayPassword=$gatewayPassword -q
            else
                echo "deploy to portal..."
                version=$(./gradlew ${projectArr[$i]}:getCurrentVersion -q)

                metadata="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-environment-$version-env.metadata.yml;type=text/yml"
                installBundle="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-environment-$version-env.install.bundle;type=application/octet-stream"
                deleteBundle="files=@./${projectArr[$i]}/build/gateway/bundle/${projectArr[$i]}-environment-$version-env.delete.bundle;type=application/octet-stream"

                bundleUUID=$(curl -s -H "$authHeader" -H "accept: application/json;charset=UTF-8" -XPOST ${2%/}/$3$papi_bundle_uri -H "Content-Type: multipart/form-data" -F $metadata -F $installBundle -F $deleteBundle | jq -r .uuid)
                echo $bundleUUID
                curl -s -H "$authHeader" -H "Content-Type:application/json" -XPOST "${2%/}/$3$papi_deployment_uri/$bundleUUID/proxies" --data '{ "proxyUuid": "'$proxyUUID'"}'
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
                ./gradlew ${projectArr[$i]}:import -PenvironmentType=$environment -PgatewayURL=$gatewayUrl -PgatewayUsername=$gatewayUsername -PgatewayPassword=$gatewayPassword -q
            else
                echo "deploy to portal..."
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

#RemoveExclusions

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
        BuildAndDeployEnv $type $papiUrl $tenantId $environment
        #BuildAndDeployServices $type
        #DeployToProxy
    else
        environment=$1
        gatewayUrl=$2
        gatewayUsername=$3
        gatewayPassword=$4
        apiId=$5
        apiSecret=$6
        testId=$7
        BuildAndDeployEnv $type
        BuildAndDeployServices $type
        RunFunctionalTests
    fi
}

SetEnvironmentDetails $2 $3 $4 $5 $6 $7 $8 $9
