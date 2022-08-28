#!/bin/sh

# Assume there's no `nim` installed - install one locally instead
nimble install -l -y nim@1.6.14

# Put nim itself in development mode
nimble develop -y -p:vendor nim

[ -f vendor/Nim/bin/nim ] || {
  cd vendor/Nim
  git checkout v1.6.14 # nimble at the time of writing clones the wrong version :/
  sh ./build_all.sh
  mv bin/nimble bin/nimble_upstream;
  cd ../..
}

nimble develop -y --withDependencies -p:vendor

nimble setup -l

# The below snipped is experimental and *should* place the dependencies themselves in mutual development mode - there are issues however.
DEVELOP="{\"version\": 1, \"includes\": [\"$PWD/nimble.develop\"], \"dependencies\": []}"

cd vendor

for a in *; do
[[ -d $a ]] && {
  echo "$DEVELOP" > $a/nimble.develop
  cd $a
  # disabled because it breaks nimble lock
  # nimble setup
  cd ..
} ;

done
