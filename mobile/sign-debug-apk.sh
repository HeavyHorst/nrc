#!/usr/bin/env bash
# Do not expose decrypted credentials even when invoked with bash -x.
set +x
set -euo pipefail
umask 077

mobile_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
encrypted_key="$mobile_root/signing/debug.sops.json"
expected_certificate="b8d67864abd5c79328bba51e8e656048d9a35c1a220c19c13b3ea504f13627ce"

for tool in sops jq keytool base64 sha256sum; do
    command -v "$tool" >/dev/null || { echo "Missing signing tool: $tool" >&2; exit 1; }
done
[[ -f "$encrypted_key" ]] || { echo "Encrypted signing backup is not enrolled yet: $encrypted_key" >&2; exit 1; }

signing_dir="$(mktemp -d "${TMPDIR:-/tmp}/nrc-android-signing.XXXXXX")"
gradle_pid=""
cleanup() {
    if [[ -n "$gradle_pid" ]]; then
        kill -TERM "$gradle_pid" 2>/dev/null || true
    fi
    rm -rf -- "$signing_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sops --decrypt "$encrypted_key" > "$signing_dir/signing.json"
# Decryption is finished; Gradle does not need the age identity in its environment.
unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE SOPS_AGE_KEY_CMD
jq -e '
    type == "object" and
    (.keystore_base64 | type == "string" and length > 0) and
    (.store_password | type == "string" and length > 0) and
    (.key_alias | type == "string" and length > 0) and
    (.key_password | type == "string" and length > 0)
' "$signing_dir/signing.json" >/dev/null
jq -r '.keystore_base64' "$signing_dir/signing.json" | base64 --decode > "$signing_dir/keystore.p12"
jq -jr '.store_password' "$signing_dir/signing.json" > "$signing_dir/store-password"
alias_name="$(jq -r '.key_alias' "$signing_dir/signing.json")"
if ! keytool -exportcert -keystore "$signing_dir/keystore.p12" -storetype PKCS12 \
    -storepass:file "$signing_dir/store-password" -alias "$alias_name" \
    -file "$signing_dir/certificate.der" >/dev/null 2>&1; then
    echo "Cannot read the signing certificate." >&2
    exit 1
fi
certificate="$(sha256sum "$signing_dir/certificate.der" | cut -d ' ' -f 1)"
[[ "$certificate" == "$expected_certificate" ]] || { echo "Signing identity differs from the installed NRC alpha; refusing to build." >&2; exit 1; }
rm -- "$signing_dir/store-password" "$signing_dir/certificate.der"

export NRC_ANDROID_SIGNING_DIRECTORY="$signing_dir"
# No reusable daemon or configuration cache may retain the signing credentials.
# Bash's builtin wait is interruptible; a foreground external wait defers TERM cleanup.
"$mobile_root/gradlew" -p "$mobile_root" :androidApp:assembleDebug "$@" --no-daemon --no-configuration-cache <&0 &
gradle_pid=$!
build_status=0
wait "$gradle_pid" || build_status=$?
gradle_pid=""
if ((build_status != 0)); then
    exit "$build_status"
fi
echo "Debug APK signing certificate: $certificate"
