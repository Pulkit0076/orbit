#!/bin/bash

function conan_profile_exists {
  conan profile show $profile >/dev/null 2>&1
  return $?
}


REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../../../" >/dev/null 2>&1 && pwd )"
REPO_ROOT_WIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../../../" >/dev/null 2>&1 && pwd -W 2>/dev/null)"

# Path to script inside the docker container
SCRIPT="/mnt/third_party/conan/scripts/build_and_upload_dependencies.sh"

export CONAN_USE_ALWAYS_SHORT_PATHS=1

if [ "$1" ]; then
  pip3 install conan==1.29.2
  export QT_QPA_PLATFORM=offscreen

  $REPO_ROOT/third_party/conan/configs/install.sh || exit $?
  conan user -r artifactory $ARTIFACTORY_USERNAME -p $ARTIFACTORY_API_KEY || exit $?
  if [ -n "$BINTRAY_USERNAME" -a -n "$BINTRAY_API_KEY" ]; then
    conan remote enable bintray
    conan user -r bintray $BINTRAY_USERNAME -p $BINTRAY_API_KEY || exit $?
    conan remote disable bintray
  fi

  for profile in $@; do
    conan_profile_exists "$profile" || exit 128
    echo "Checking profile $profile..."

    if [ $(uname -s) == "Linux" ]; then
      platform="linux"
    else
      platform="windows"
    fi

    mkdir -p build_$profile/ || exit $?
    conan lock create "$REPO_ROOT/conanfile.py" --user=orbitdeps --channel=stable \
      --build=outdated \
      --lockfile="$REPO_ROOT/third_party/conan/lockfiles/base.lock" -pr $profile \
      --lockfile-out=build_$profile/conan.lock || exit $?

    LOCKFILE="$(pwd)/build_$profile/conan.lock"

    PACKAGES=$(conan info -l $LOCKFILE $REPO_ROOT -j 2>/dev/null \
               | grep build_id \
               | jq '.[] | select(.is_ref) | select(.binary != "Download" and .binary != "Cache" and .binary != "Skip") | .reference + ":" + .id' \
               | grep -v 'llvm/' \
               | grep -v 'ggp_sdk/' \
               | tr -d '"')

    if [ $(echo -n "$PACKAGES" | wc -c) -eq 0 ]; then
      echo -n "No binary packages are missing or outdated for profile $profile."
      echo " Skipping this configuration."
    else
      echo -e "The following binary packages need to be uploaded:\n$PACKAGES"

      conan install -if build_$profile/ --build=outdated -l $LOCKFILE $REPO_ROOT || exit $?
      conan build -bf build_$profile/ $REPO_ROOT || exit $?

      echo "$PACKAGES" | while read package; do
        conan upload -r artifactory -c $package
        if [[ -n "$BINTRAY_USERNAME" && -n "$BINTRAY_API_KEY" ]] && echo "$package" | grep "orbitdeps/stable" > /dev/null; then
          conan remote enable bintray
          conan upload -r bintray -c $package
          conan remote disable bintray
        fi
      done
    fi
  done
else
  if [ $(uname -s) == "Linux" ]; then
    PROFILES=( {clang{7,8,9},gcc{8,9},ggp}_{release,relwithdebinfo,debug} )

    curl -s http://artifactory.internal/ >/dev/null 2>&1
    if [ -z "${ORBIT_OVERRIDE_ARTIFACTORY_URL}" -a $? -ne 0 ]; then
      echo "Note: SSH port forwarding for artifactory set up?"
      export ORBIT_OVERRIDE_ARTIFACTORY_URL="http://localhost:8080/artifactory/api/conan/conan"
    fi

    for profile in ${PROFILES[@]}; do
      docker run --network host --rm -it -v $REPO_ROOT:/mnt \
             -e ARTIFACTORY_USERNAME -e ARTIFACTORY_API_KEY \
             -e BINTRAY_USERNAME -e BINTRAY_API_KEY \
             -e ORBIT_OVERRIDE_ARTIFACTORY_URL \
             gcr.io/orbitprofiler/$profile:latest $SCRIPT $profile || exit $?
    done
  else # Windows
    PROFILES=( msvc{2017,2019}_{release,relwithdebinfo,debug}{,_x86} )

    curl -s http://artifactory.internal/ >/dev/null 2>&1
    if [ -z "${ORBIT_OVERRIDE_ARTIFACTORY_URL}" -a $? -ne 0 ]; then
      echo "Note: SSH port forwarding for artifactory set up?"
      PUBLIC_IP="$(ipconfig | grep -A20 "Ethernet adapter Ethernet:" | grep "IPv4 Address" | head -n1 | cut -d ':' -f 2 | tr -d ' \r\n')"
      export ORBIT_OVERRIDE_ARTIFACTORY_URL="http://${PUBLIC_IP}:8080/artifactory/api/conan/conan"
    fi

    for profile in ${PROFILES[@]}; do
      docker run --isolation=process --rm -v $REPO_ROOT_WIN:C:/mnt \
       --storage-opt "size=50GB" \
       -e ARTIFACTORY_USERNAME -e ARTIFACTORY_API_KEY \
       -e BINTRAY_USERNAME -e BINTRAY_API_KEY \
       -e ORBIT_OVERRIDE_ARTIFACTORY_URL \
       gcr.io/orbitprofiler/$profile:latest "C:/Program Files/Git/bin/bash.exe" \
       -c "/c$SCRIPT $profile" || exit $?
    done
  fi
fi
