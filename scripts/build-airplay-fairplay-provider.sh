#!/bin/sh
set -eu

log() {
    printf '[AirPlayFairPlayProviderBuild] %s\n' "$*"
}

fail() {
    log "branch=FAILED reason=$*"
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
SOURCE_DIR="${ROOT_DIR}/ThirdParty/AirPlayFairPlay"
UXPLAY_DIR="${SOURCE_DIR}/UxPlay"
SPECCHIO_DIR="${SOURCE_DIR}/Specchio"
OUTPUT_DIR="${ROOT_DIR}/SupportingFiles/AirPlayFairPlay"
OUTPUT_DYLIB="${OUTPUT_DIR}/libfairplay.dylib"
BUILD_DIR="${TMPDIR:-/tmp}/specchio-airplay-fairplay-provider"
ARCHS_TO_BUILD=${SPECCHIO_FAIRPLAY_ARCHS:-"arm64 x86_64"}
MIN_MACOS=${MACOSX_DEPLOYMENT_TARGET:-12.0}
CLANG=${SPECCHIO_FAIRPLAY_CLANG:-$(xcrun --sdk macosx --find clang)}
SDKROOT_PATH=${SPECCHIO_FAIRPLAY_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}

log "branch=START root=${ROOT_DIR}"
log "branch=CONFIG archs=${ARCHS_TO_BUILD} minMacOS=${MIN_MACOS} clang=${CLANG} sdkroot=${SDKROOT_PATH}"

[ -d "${UXPLAY_DIR}/lib/playfair" ] || fail "missing upstream playfair source at ${UXPLAY_DIR}/lib/playfair"
[ -f "${UXPLAY_DIR}/lib/fairplay_playfair.c" ] || fail "missing upstream fairplay source"
[ -f "${SPECCHIO_DIR}/specchio_fairplay_provider.c" ] || fail "missing Specchio provider adapter"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

slice_paths=""
for arch in ${ARCHS_TO_BUILD}; do
    case "${arch}" in
        arm64|x86_64)
            log "branch=ARCH_INCLUDED arch=${arch}"
            ;;
        *)
            fail "unsupported architecture ${arch}"
            ;;
    esac

    slice_path="${BUILD_DIR}/libfairplay-${arch}.dylib"
    log "branch=COMPILE_START arch=${arch} output=${slice_path}"
    "${CLANG}" \
        -dynamiclib \
        -arch "${arch}" \
        -isysroot "${SDKROOT_PATH}" \
        -mmacosx-version-min="${MIN_MACOS}" \
        -I"${UXPLAY_DIR}/lib" \
        -I"${UXPLAY_DIR}/lib/playfair" \
        -Wno-unused-variable \
        -Wno-unused-function \
        -Wl,-install_name,@rpath/libfairplay.dylib \
        -o "${slice_path}" \
        "${SPECCHIO_DIR}/specchio_fairplay_provider.c" \
        "${UXPLAY_DIR}/lib/fairplay_playfair.c" \
        "${UXPLAY_DIR}/lib/playfair/hand_garble.c" \
        "${UXPLAY_DIR}/lib/playfair/modified_md5.c" \
        "${UXPLAY_DIR}/lib/playfair/omg_hax.c" \
        "${UXPLAY_DIR}/lib/playfair/playfair.c" \
        "${UXPLAY_DIR}/lib/playfair/sap_hash.c" \
        -lm
    /usr/bin/lipo "${slice_path}" -verify_arch "${arch}" >/dev/null 2>&1 || fail "compiled slice missing ${arch}"
    log "branch=COMPILE_OK arch=${arch}"
    slice_paths="${slice_paths} ${slice_path}"
done

log "branch=LIPO_START output=${OUTPUT_DYLIB}"
/usr/bin/lipo -create ${slice_paths} -output "${BUILD_DIR}/libfairplay.dylib"
install -m 0644 "${BUILD_DIR}/libfairplay.dylib" "${OUTPUT_DYLIB}"
log "branch=LIPO_OK info=$(/usr/bin/lipo -info "${OUTPUT_DYLIB}")"

for arch in ${ARCHS_TO_BUILD}; do
    /usr/bin/lipo "${OUTPUT_DYLIB}" -verify_arch "${arch}" >/dev/null 2>&1 || fail "output missing ${arch}"
    log "branch=VERIFY_ARCH_OK arch=${arch}"
done

for symbol in \
    _specchio_airplay_fairplay_setup_reply \
    _specchio_airplay_fairplay_key_message_reply \
    _specchio_airplay_fairplay_decrypt_key \
    _fairplay_init \
    _fairplay_setup \
    _fairplay_handshake \
    _fairplay_decrypt \
    _fairplay_destroy
do
    if nm -gU "${OUTPUT_DYLIB}" | /usr/bin/grep -q " ${symbol}$"; then
        log "branch=VERIFY_SYMBOL_OK symbol=${symbol}"
    else
        fail "missing symbol ${symbol}"
    fi
done

log "branch=DONE output=${OUTPUT_DYLIB}"
