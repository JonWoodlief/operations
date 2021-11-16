#!/bin/bash

set -e

attempts=1
until ibmcloud login --apikey "$CATALOG_APIKEY" --no-region || [ $attempts -ge 3 ]; do
    ((attempts++))
    echo "Error logging in to IBM Cloud CLI..."
    sleep 3
done
ibmcloud target -g "$CATALOG_VALIDATION_RG"

tgzurl="$1"
version="$2"
catalog="$3"
offering="$4"

versionExists=$(ibmcloud catalog offering get -c "$catalog" -o "$offering" --output json | jq -r --arg version "$version" '.kinds[] | any(.versions[].version; . == $version)')
if [ "$versionExists" == false ]
then
    echo "import new version"
    ibmcloud catalog offering import-version --zipurl "$tgzurl" --target-version "$version" --catalog "$catalog" --offering "$offering" --include-config
fi

echo "get offering json"
ibmcloud catalog offering get -c "$catalog" -o "$offering" --output json > offering.json

versionState=$(jq -r --arg version "$version" '.kinds[] | select(.format_kind=="terraform").versions[] | select(.version==$version).state.current' < offering.json)
if [[ "$versionState" == *"published"* ]]
then
    echo "Version is already published"
    exit 1
fi

echo "edit json to add minimumVersion from previous version to new version"
jq --arg version "$version" --arg minVersion "$TERRAFORM_MIN_VERSION" '.kinds[] | select(.format_kind=="terraform").versions[] | select(.version==$version) += {"required_resources":[{"type":"terraformVersion","value": $minVersion}]} ' <offering.json > versions.json
jq --slurpfile values versions.json '.kinds[] | select(.format_kind=="terraform").versions = $values' <offering.json > kinds.json
jq --slurpfile values kinds.json '.kinds = $values' <offering.json > updatedoffering.json

echo "update offering with patched json"
ibmcloud catalog offering update -c "$catalog" -o "$offering" --updated-offering updatedoffering.json

echo "get updated version"
ibmcloud catalog offering get -c "$catalog" -o "$offering" --output json > offering.json

echo "generate validation override values"
jq --arg version "$version" '[.kinds[] | select(.format_kind=="terraform").versions[] | select(.version==$version).configuration[] | {key: .key, value: .default_value}] | from_entries' <offering.json > defaultValues.json
jq -n --slurpfile default defaultValues.json --slurpfile input catalogValidationValues.json  '$default[0] + $input[0]' > validationValues.json

versionLocator=$(jq -r --arg version "$version" '.kinds[] | select(.format_kind=="terraform").versions[] | select(.version==$version).version_locator' < offering.json)
echo "version locator: $versionLocator"

echo "validate version"
ibmcloud catalog offering validate --vl "$versionLocator" --override-values validationValues.json

echo "publishing to account"
ibmcloud catalog offering account --vl "$versionLocator"

echo "destroying workspace resources"
workspaceID=$(ibmcloud catalog offering get -c "$catalog" -o "$offering" --output json | jq -r --arg version "$version" '.kinds[] | select(.format_kind=="terraform").versions[] | select(.version==$version).validation.target.workspace_id')

echo "workspace id: $workspaceID"
ibmcloud schematics destroy --id "$workspaceID" -f

echo "waiting for resources to be destroyed"
destroyStatus=$(ibmcloud schematics workspace action --id "$workspaceID" --output json | jq -r '.actions[] | select(.name=="DESTROY").status')
while [ "$destroyStatus" != "COMPLETED" ] && [ "$destroyStatus" != "FAILED" ]
do
    sleep 3
    destroyStatus=$(ibmcloud schematics workspace action --id "$workspaceID" --output json | jq -r '.actions[] | select(.name=="DESTROY").status')
done

echo "delete workspace"
ibmcloud schematics workspace delete --id "$workspaceID" -f
