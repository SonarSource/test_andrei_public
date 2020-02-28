#!/bin/bash

set -euo pipefail

#### TRAVIS UTILS

function installTravisTools {
  mkdir -p ~/.local
  curl -sSL https://github.com/SonarSource/travis-utils/tarball/v57 | tar zx --strip-components 1 -C ~/.local
  source ~/.local/bin/install
}

# configures the global variables used by this script
function setupEnvironment {
  installTravisTools

  export PROJECT_NAME="test_andrei_public" # ${CIRRUS_REPO_NAME}
  export GITHUB_REPO=${TRAVIS_REPO_SLUG} # CIRRUS_REPO_FULL_NAME
  export GITHUB_BRANCH=${TRAVIS_BRANCH} #$CIRRUS_BRANCH
  export BUILD_NUMBER=${TRAVIS_BUILD_NUMBER} # cirrusBuildNumber() in cirrus-env script...
  export PULL_REQUEST=${TRAVIS_PULL_REQUEST} # ${CIRRUS_PR:-false}
  export GIT_SHA1=${TRAVIS_COMMIT} # $CIRRUS_CHANGE_IN_REPO
  export PIPELINE_ID=${TRAVIS_BUILD_ID} # CIRRUS_BUILD_ID
  export ARTIFACT_URL="$ARTIFACTORY_URL/webapp/#/builds/$PROJECT_NAME/$BUILD_NUMBER"

  # get current version from pom
  export CURRENT_VERSION=`maven_expression "project.version"`
  export ARTIFACTID=`maven_expression "project.artifactId"`

  if [[ $CURRENT_VERSION =~ "-SNAPSHOT" ]]; then
    echo "======= Found SNAPSHOT version ======="
    # Do not deploy a SNAPSHOT version but the release version related to this build
    . set_maven_build_version $TRAVIS_BUILD_NUMBER
  else
    export PROJECT_VERSION=`maven_expression "project.version"`
    echo "======= Found RELEASE version ======="
  fi

  #for a pull request, we send the pr_number, not the branch name
  PRBRANCH=branch
  if [[ $GITHUB_BRANCH == "PULLREQUEST-"* ]]
  then
    PRBRANCH=pr_number
    GITHUB_BRANCH=$(echo $GITHUB_BRANCH | cut -d'-' -f 2)
  fi
}

# Burgr notifications

function callBurgr {
  HTTP_CODE=$(curl --silent --output out.txt --write-out %{http_code} \
    -d @$1 \
    -H "Content-type: application/json" \
    -X POST \
    -u"${BURGRX_USER}:${BURGRX_PASSWORD}" \
    $2)

  if [[ "$HTTP_CODE" != "200" ]] && [[ "$HTTP_CODE" != "201" ]]; then
    echo ""
    echo "Burgr did not ACK notification ($HTTP_CODE)"
    echo "ERROR:"
    cat out.txt
    echo ""
    echo "The payload sent to burgr was:"
    cat $1
    echo ""
    exit -1
  else  
    echo ""
    echo "Burgr ACKed notification for call to $2"
    echo ""
  fi
}

function notifyBurgr {

  BURGR_FILE=burgr
  cat > $BURGR_FILE <<EOF1 
  {
    "repository": "$GITHUB_REPO",
    "pipeline": "$PIPELINE_ID",
    "name": "$1",
    "system": "travis",
    "type": "$2",
    "number": "$PIPELINE_ID",
    "branch": "$GITHUB_BRANCH",
    "sha1": "$GIT_SHA1",
    "url":"$3",
    "status": "passed",
    "started_at": "$4",
    "finished_at": "$5"
  }
EOF1

  BURGR_STAGE_URL="$BURGRX_URL/api/stage"
  callBurgr $BURGR_FILE $BURGR_STAGE_URL
}

function buildAndPromote {
  START_ISO8601=`date --utc +%FT%TZ`

  export MAVEN_OPTS="-Xmx1536m -Xms128m"
  mvn deploy \
    -Pdeploy-sonarsource,release \
    -B -e -V

  # Google Cloud Function to do the promotion
  GCF_PROMOTE_URL="$PROMOTE_URL/$GITHUB_REPO/$GITHUB_BRANCH/$BUILD_NUMBER/$PULL_REQUEST"
  echo "GCF_PROMOTE_URL: $GCF_PROMOTE_URL"

  curl -sfSL -H "Authorization: Bearer $GCF_ACCESS_TOKEN" "$GCF_PROMOTE_URL"

  # Notify Burgr

  END_DATE_ISO8601=`date --utc +%FT%TZ`
  # $TRAVIS_JOB_WEB_URL is defined by Travis

  notifyBurgr "build" "promote" "$TRAVIS_JOB_WEB_URL" "$START_ISO8601" "$END_DATE_ISO8601"
  notifyBurgr "artifacts" "promotion" "$ARTIFACT_URL" "$END_DATE_ISO8601" "$END_DATE_ISO8601"

  BURGR_VERSION_FILE=burgr_version
  cat > $BURGR_VERSION_FILE <<EOF1
  {
    "version": "$PROJECT_VERSION",
    "build": "$BUILD_NUMBER",
    "url":  "$ARTIFACT_URL"
  }
EOF1

  BURGR_VERSION_URL="$BURGRX_URL/api/promote/$GITHUB_REPO/$PIPELINE_ID"

  callBurgr $BURGR_VERSION_FILE $BURGR_VERSION_URL
}

function doRelease {
  if [[ $CURRENT_VERSION =~ "-build" ]] || [[ $CURRENT_VERSION =~ "-SNAPSHOT" ]]; then   
    echo "This is a dev build, not releasing"
    exit 0
  else
    echo "About to release $ARTIFACTID"
  fi

  # from the old Jenkins promote-release.sh script

  STATUS='released'
  OP_DATE=$(date +%Y%m%d%H%M%S)
  TARGET_REPOSITORY="sonarsource-private-releases"
  DATA_JSON="{ \"status\": \"$STATUS\", \"properties\": { \"release\" : [ \"$OP_DATE\" ]}, \"targetRepo\": \"$TARGET_REPOSITORY\", \"copy\": false }"

  RELEASE_URL="$ARTIFACTORY_URL/api/build/promote/$PROJECT_NAME/$BUILD_NUMBER"
  echo "RELEASE_URL: $RELEASE_URL"
  echo "DATA_JSON: $DATA_JSON"

  HTTP_CODE=$(curl -s -o /dev/null -w %{http_code} \
    -H "X-JFrog-Art-Api:${ARTIFACTORY_API_KEY}" \
    -H "Content-type: application/json" \
    -X POST \
    "$RELEASE_URL" \
    -d "$DATA_JSON")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "Cannot release build ${PROJECT_NAME} #${BUILD_NUMBER}: ($HTTP_CODE)"
    exit 1
  else
    echo "Build ${PROJECT_NAME} #${BUILD_NUMBER} promoted to ${TARGET_REPOSITORY}"
  fi

  # Notify Burgr

  RELEASE_ISO8601=`date --utc +%FT%TZ`
  notifyBurgr "release" "release" "$ARTIFACT_URL" "$RELEASE_ISO8601" "$RELEASE_ISO8601"
}

setupEnvironment

# Build, promote, release if necessary
buildAndPromote

doRelease
