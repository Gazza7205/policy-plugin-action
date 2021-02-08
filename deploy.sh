#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# hack to initialize gradle
./gradlew tasks -q >>/dev/null 2>&1
# environment to publish to
environment=$1
gatewayUrl=$2
gatewayUsername=$3
gatewayPassword=$4
apiId=$5
apiSecret=$6
testId=$7

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
            ./gradlew ${projectArr[$i]}:import-bundle -PenvironmentType=$environment -PgatewayURL=$gatewayUrl -PgatewayUsername=$gatewayUsername -PgatewayPassword=$gatewayPassword -q
        fi
    done
}

BuildAndDeployServices() {
    for i in "${!projectArr[@]}"; do
        if [[ "${projectArr[$i]}" != *"-env"* ]] && [[ "${projectArr[$i]}" != "common" ]]; then
            echo "Building: ${projectArr[$i]}"
            ./gradlew ${projectArr[$i]}:build -q
            echo "Publishing: ${projectArr[$i]}"
            ./gradlew ${projectArr[$i]}:import -PenvironmentType=$environment -PgatewayURL=$gatewayUrl -PgatewayUsername=$gatewayUsername -PgatewayPassword=$gatewayPassword -q
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

RemoveExclusions
BuildAndDeployEnv
BuildAndDeployServices
RunFunctionalTests
