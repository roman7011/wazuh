#!/bin/sh
set -eu

MODE="$1"
SYSTEM="$2"
PACKAGE_PATH="$3"
EXPECTED_VERSION="$4"
WAZUH_DIR="/var/wazuh-manager"
MARKER="WAZUH_UPGRADE_RULES_PRESERVE_MARKER"
OLD_TZDB_MARKER="WAZUH_UPGRADE_RULES_OLD_TZDB"
OUTSIDE_FILE="/tmp/wazuh-upgrade-rules-outside"
EXTRACT_DIR="/tmp/wazuh-upgrade-rules-extract"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "Required file not found: $1"
}

append_marker() {
    require_file "$1"
    printf '\n# %s %s\n' "${MARKER}" "$2" >> "$1"
}

prepare() {
    append_marker "${WAZUH_DIR}/etc/wazuh-manager.conf" "wazuh-manager.conf"
    append_marker "${WAZUH_DIR}/etc/wazuh-manager-internal-options.conf" "internal-options"
    append_marker "${WAZUH_DIR}/etc/shared/default/agent.conf" "shared-default"
    append_marker "${WAZUH_DIR}/etc/outputs/default/indexer.yml" "indexer-output"

    printf '%s\n' "${MARKER} custom etc" > "${WAZUH_DIR}/etc/custom-preserve.conf"
    mkdir -p "${WAZUH_DIR}/data"
    printf '%s\n' "${MARKER} custom data" > "${WAZUH_DIR}/data/custom_file"
    chmod 0600 "${WAZUH_DIR}/data/custom_file"

    if [ -f "${WAZUH_DIR}/data/tzdb/iana/version" ]; then
        printf '%s\n' "${OLD_TZDB_MARKER}" > "${WAZUH_DIR}/data/tzdb/iana/version"
    fi

    printf 'outside-original\n' > "${OUTSIDE_FILE}"
    ln -sf "${OUTSIDE_FILE}" "${WAZUH_DIR}/data/custom_link"

    require_file "${WAZUH_DIR}/bin/wazuh-manager-control"
    sha256sum "${WAZUH_DIR}/bin/wazuh-manager-control" > "${WAZUH_DIR}/tmp/upgrade_rules_old_bin.sha256"
}

extract_package() {
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"

    case "${SYSTEM}" in
        deb)
            command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb is required to validate DEB packages"
            dpkg-deb -x "${PACKAGE_PATH}" "${EXTRACT_DIR}"
            ;;
        rpm)
            command -v rpm2cpio >/dev/null 2>&1 || fail "rpm2cpio is required to validate RPM packages"
            if ! command -v cpio >/dev/null 2>&1; then
                if command -v yum >/dev/null 2>&1; then
                    yum --setopt=retries=5 --setopt=timeout=30 install -y cpio >/dev/null 2>&1 || fail "Unable to install cpio"
                elif command -v dnf >/dev/null 2>&1; then
                    dnf --setopt=retries=5 --setopt=timeout=30 install -y cpio >/dev/null 2>&1 || fail "Unable to install cpio"
                else
                    fail "cpio is required to validate RPM packages"
                fi
            fi
            rpm2cpio "${PACKAGE_PATH}" > "${EXTRACT_DIR}/package.cpio"
            (cd "${EXTRACT_DIR}" && cpio -idm --quiet < package.cpio)
            rm -f "${EXTRACT_DIR}/package.cpio"
            ;;
        *)
            fail "Unsupported package system: ${SYSTEM}"
            ;;
    esac
}

validate_marker() {
    require_file "$1"
    grep -F "${MARKER}" "$1" >/dev/null 2>&1 || fail "Marker not preserved in $1"
}

validate() {
    require_file "${PACKAGE_PATH}"
    extract_package

    validate_marker "${WAZUH_DIR}/etc/wazuh-manager.conf"
    validate_marker "${WAZUH_DIR}/etc/wazuh-manager-internal-options.conf"
    validate_marker "${WAZUH_DIR}/etc/shared/default/agent.conf"
    validate_marker "${WAZUH_DIR}/etc/outputs/default/indexer.yml"
    validate_marker "${WAZUH_DIR}/etc/custom-preserve.conf"
    validate_marker "${WAZUH_DIR}/data/custom_file"

    if [ "$(stat -c '%a' "${WAZUH_DIR}/data/custom_file")" != "600" ]; then
        fail "Preserved data file permissions changed"
    fi

    if [ "$(cat "${OUTSIDE_FILE}")" != "outside-original" ]; then
        fail "Restore followed a data symlink and modified ${OUTSIDE_FILE}"
    fi

    if [ ! -L "${WAZUH_DIR}/data/custom_link" ]; then
        fail "Data symlink was not preserved as a symlink"
    fi

    if [ "$(readlink "${WAZUH_DIR}/data/custom_link")" != "${OUTSIDE_FILE}" ]; then
        fail "Data symlink target changed"
    fi

    case "${SYSTEM}" in
        deb)
            require_file "${WAZUH_DIR}/etc/wazuh-manager.conf.dpkg-dist"
            ;;
        rpm)
            require_file "${WAZUH_DIR}/etc/wazuh-manager.conf.rpmnew"
            ;;
    esac

    require_file "${WAZUH_DIR}/data/tzdb/iana/version"
    if grep -F "${OLD_TZDB_MARKER}" "${WAZUH_DIR}/data/tzdb/iana/version" >/dev/null 2>&1; then
        fail "Timezone database was not replaced"
    fi

    if [ -f "${EXTRACT_DIR}${WAZUH_DIR}/data/tzdb/iana/version" ]; then
        cmp "${WAZUH_DIR}/data/tzdb/iana/version" "${EXTRACT_DIR}${WAZUH_DIR}/data/tzdb/iana/version" >/dev/null 2>&1 || \
            fail "Installed timezone database does not match package"
    fi

    require_file "${WAZUH_DIR}/bin/wazuh-manager-control"
    if [ -f "${EXTRACT_DIR}${WAZUH_DIR}/bin/wazuh-manager-control" ]; then
        cmp "${WAZUH_DIR}/bin/wazuh-manager-control" "${EXTRACT_DIR}${WAZUH_DIR}/bin/wazuh-manager-control" >/dev/null 2>&1 || \
            fail "Installed manager control binary does not match package"
    fi

    if ! "${WAZUH_DIR}/bin/wazuh-manager-control" info -v 2>/dev/null | grep -F "${EXPECTED_VERSION}" >/dev/null 2>&1; then
        fail "Installed manager does not report expected version ${EXPECTED_VERSION}"
    fi
}

case "${MODE}" in
    prepare)
        prepare
        ;;
    validate)
        validate
        ;;
    *)
        fail "Unsupported mode: ${MODE}"
        ;;
esac
