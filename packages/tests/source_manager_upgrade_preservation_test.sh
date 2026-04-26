#!/bin/sh
set -eu

OLD_SOURCE_DIR="${OLD_SOURCE_DIR:?Set OLD_SOURCE_DIR}"
NEW_SOURCE_DIR="${NEW_SOURCE_DIR:?Set NEW_SOURCE_DIR}"
INSTALLDIR="${INSTALLDIR:-/tmp/wazuh-manager-source-upgrade-test}"
MARKER="WAZUH_SOURCE_UPGRADE_PRESERVE_MARKER"
OLD_TZDB_MARKER="WAZUH_SOURCE_OLD_TZDB"
OUTSIDE_FILE="/tmp/wazuh-source-upgrade-preserve-outside"

write_preloaded_vars() {
    src_dir="$1"
    cat > "${src_dir}/etc/preloaded-vars.conf" << EOF
USER_LANGUAGE="en"
USER_INSTALL_TYPE="manager"
USER_DIR="${INSTALLDIR}"
USER_DELETE_DIR="y"
USER_ENABLE_EMAIL="n"
USER_ENABLE_AUTHD="y"
USER_GENERATE_AUTHD_CERT="y"
USER_AUTO_START="n"
USER_CREATE_SSL_CERT="n"
EOF
}

append_marker() {
    file="$1"
    [ -f "${file}" ] || { echo "Missing file: ${file}" >&2; exit 1; }
    printf '\n# %s\n' "${MARKER}" >> "${file}"
}

run_install() {
    src_dir="$1"
    update_value="$2"
    write_preloaded_vars "${src_dir}"
    printf 'USER_UPDATE="%s"\n' "${update_value}" >> "${src_dir}/etc/preloaded-vars.conf"
    (cd "${src_dir}" && ./install.sh)
}

run_install "${OLD_SOURCE_DIR}" "n"

append_marker "${INSTALLDIR}/etc/wazuh-manager.conf"
append_marker "${INSTALLDIR}/etc/wazuh-manager-internal-options.conf"
append_marker "${INSTALLDIR}/etc/shared/default/agent.conf"
append_marker "${INSTALLDIR}/etc/outputs/default/indexer.yml"
printf '%s\n' "${MARKER}" > "${INSTALLDIR}/etc/custom-preserve.conf"
printf '%s\n' "${MARKER}" > "${INSTALLDIR}/data/custom_file"
chmod 0600 "${INSTALLDIR}/data/custom_file"
printf 'outside-original\n' > "${OUTSIDE_FILE}"
ln -sf "${OUTSIDE_FILE}" "${INSTALLDIR}/data/custom_link"

rm -f "${INSTALLDIR}/etc/shared/agent-template.conf"

if [ -f "${INSTALLDIR}/data/tzdb/iana/version" ]; then
    printf '%s\n' "${OLD_TZDB_MARKER}" > "${INSTALLDIR}/data/tzdb/iana/version"
fi

run_install "${NEW_SOURCE_DIR}" "y"

for file in \
    "${INSTALLDIR}/etc/wazuh-manager.conf" \
    "${INSTALLDIR}/etc/wazuh-manager-internal-options.conf" \
    "${INSTALLDIR}/etc/shared/default/agent.conf" \
    "${INSTALLDIR}/etc/outputs/default/indexer.yml" \
    "${INSTALLDIR}/etc/custom-preserve.conf" \
    "${INSTALLDIR}/data/custom_file"; do
    grep -F "${MARKER}" "${file}" >/dev/null 2>&1 || { echo "Marker not preserved in ${file}" >&2; exit 1; }
done

[ -f "${INSTALLDIR}/etc/wazuh-manager.conf.new" ] || { echo "Missing source config sidecar" >&2; exit 1; }
[ ! -e "${INSTALLDIR}/etc/shared/agent-template.conf" ] || { echo "Deleted source config was recreated as active file" >&2; exit 1; }
[ -f "${INSTALLDIR}/etc/shared/agent-template.conf.new" ] || { echo "Missing sidecar for deleted source config" >&2; exit 1; }
[ "$(stat -c '%a' "${INSTALLDIR}/data/custom_file")" = "600" ] || { echo "Preserved data file permissions changed" >&2; exit 1; }
[ "$(cat "${OUTSIDE_FILE}")" = "outside-original" ] || { echo "Source upgrade followed data symlink target" >&2; exit 1; }
[ -L "${INSTALLDIR}/data/custom_link" ] || { echo "Data symlink was not preserved" >&2; exit 1; }
[ "$(readlink "${INSTALLDIR}/data/custom_link")" = "${OUTSIDE_FILE}" ] || { echo "Data symlink target changed" >&2; exit 1; }
[ -f "${INSTALLDIR}/data/tzdb/iana/version" ] || { echo "Missing upgraded tzdb" >&2; exit 1; }
! grep -F "${OLD_TZDB_MARKER}" "${INSTALLDIR}/data/tzdb/iana/version" >/dev/null 2>&1 || {
    echo "TZDB was not replaced" >&2
    exit 1
}
