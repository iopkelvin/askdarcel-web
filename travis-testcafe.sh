#!/bin/bash

set -ex

cleanup() {
  docker stop $(docker ps -a -q)
  if [[ $WEB_PID != "" ]]; then
    kill $WEB_PID
  fi
}

trap cleanup EXIT

# Use master branch credentials so that build status badges are tied to only the
# master branch.
if [[ $TRAVIS_BRANCH = "master" ]]; then
  export SAUCE_ACCESS_KEY=$SAUCE_MASTER_ACCESS_KEY
  export SAUCE_USERNAME=$SAUCE_MASTER_USERNAME
fi

export SAUCE_JOB="all"
export SAUCE_BUILD="build-$TRAVIS_JOB_NUMBER"

docker network create --driver bridge askdarcel
docker run -d -e POSTGRES_PASSWORD=password --network=askdarcel --name=db postgres:9.5
# 1) rake db:populate refuses to run in the production environment, so we
#    override RAILS_ENV to development.
# 2) rake will fail to run on the development environment unless if the
#    development gems are installed, so we install the development gems into the
#    production image.
docker run -d \
  -e DATABASE_URL=postgres://postgres:password@db/askdarcel_development \
  -e TEST_DATABASE_URL=postgres://postgres:password@db/askdarcel_test \
  -e SECRET_KEY_BASE=notasecret \
  -e ALGOLIA_APPLICATION_ID=$ALGOLIA_APPLICATION_ID \
  -e ALGOLIA_API_KEY=$ALGOLIA_API_KEY \
  -e ALGOLIA_INDEX_PREFIX=$ALGOLIA_INDEX_PREFIX \
  -e RAILS_ENV=development \
  --network=askdarcel \
  --name=api \
  -p 3000:3000 \
  sheltertechsf/askdarcel-api:latest bash -c 'bundle install --with=development && bundle exec rake db:setup db:populate && bundle exec rails server --binding=0.0.0.0'
npm run build
TESTCAFE_RUNNING=true npm run dev &
WEB_PID=$!

# Wait long enough for npm run dev to finish compiling and for Rails to start
# running.
sleep 60

# Check that containers did exit unexpectedly
if [[ $(docker inspect -f '{{.State.Running}}' db) == false ]]; then
  # Print out container logs
  docker logs db
  echo "askdarcel-api DB container unexpectedly failed; Aborting tests."
  exit 1
fi

if [[ $(docker inspect -f '{{.State.Running}}' api) == false ]]; then
  # Print out container logs
  docker logs api
  echo "askdarcel-api API container unexpectedly failed; Aborting tests."
  exit 1
fi

# Note: The version number needs to be periodically updated as new versions come
# out.
# TODO: SauceLabs does seem to allow for the version string "latest" to be an
# alias for the latest stable release, but it appears that the TestCafe
# plugin doesn't seem to support it. See
# https://github.com/DevExpress/testcafe-browser-provider-saucelabs/issues/42
npm run testcafe -- 'saucelabs:Chrome@76.0:Windows 10' \
  --quarantine-mode \
  --skip-js-errors \
  --assertion-timeout 50000 \
  --page-load-timeout 15000 \
  --selector-timeout 15000 \
  testcafe/*.js
