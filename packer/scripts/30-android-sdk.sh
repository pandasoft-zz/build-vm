#!/usr/bin/env bash
# Android SDK. GitHub-hosted runners have it in /usr/local/lib/android/sdk and
# Android builds expect ANDROID_HOME to be set.
set -euo pipefail

: "${ANDROID_CMDLINE_TOOLS_BUILD:?}" "${ANDROID_CMDLINE_TOOLS_SHA256:?}" "${ANDROID_PACKAGES:?}"
sdk=/usr/local/lib/android/sdk
zip=/tmp/cmdline-tools.zip

curl -fsSL -o "$zip" "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip"
echo "${ANDROID_CMDLINE_TOOLS_SHA256}  $zip" | sha256sum -c -

mkdir -p "$sdk/cmdline-tools"
rm -rf "$sdk/cmdline-tools/latest" /tmp/cmdline-tools
unzip -q "$zip" -d /tmp
mv /tmp/cmdline-tools "$sdk/cmdline-tools/latest"
rm -f "$zip"

sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
yes | "$sdkmanager" --sdk_root="$sdk" --licenses >/dev/null
# shellcheck disable=SC2086 # ANDROID_PACKAGES is a space separated list.
"$sdkmanager" --sdk_root="$sdk" $ANDROID_PACKAGES

# The runner user owns the SDK, so Gradle can install missing packages.
chown -R "$RUNNER_USER:$RUNNER_USER" /usr/local/lib/android

cat > /etc/profile.d/android-sdk.sh <<CONF
export ANDROID_HOME=$sdk
export ANDROID_SDK_ROOT=$sdk
export PATH="\$PATH:$sdk/cmdline-tools/latest/bin:$sdk/platform-tools"
CONF
