#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

readonly IMAGE="${IMAGE:-addon-emqx-upgrade-test:local}"
readonly PLATFORM="${PLATFORM:-linux/amd64}"

tmpdir=$(mktemp -d)
runner="${tmpdir}/run-emqx-startup.sh"

cleanup() {
    rm -rf "${tmpdir}"
}
trap cleanup EXIT

cat > "${runner}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

bashio::log.info() {
    printf '[info] %s\n' "$*"
}

bashio::log.warning() {
    printf '[warning] %s\n' "$*"
}

bashio::log.fatal() {
    printf '[fatal] %s\n' "$*"
}

bashio::info.hostname() {
    printf '%s\n' "${BASHIO_HOSTNAME:-homeassistant}"
}

bashio::config() {
    case "$1" in
        'env_vars|keys')
            if [ -n "${BASHIO_ENV_NAME:-}" ]; then
                printf '0\n'
            fi
            ;;
        'env_vars[0].name')
            printf '%s\n' "${BASHIO_ENV_NAME:-}"
            ;;
        'env_vars[0].value')
            printf '%s\n' "${BASHIO_ENV_VALUE:-}"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

exec() {
    printf 'would exec:'
    printf ' %q' "$@"
    printf '\n'
}

source /etc/s6-overlay/s6-rc.d/emqx/run
EOF

prepare_data_dir() {
    local data_dir="$1"

    mkdir -p \
        "${data_dir}/emqx/data" \
        "${data_dir}/emqx/etc" \
        "${data_dir}/emqx/plugins"
}

run_startup() {
    local data_dir="$1"
    shift

    docker run --rm \
        --platform="${PLATFORM}" \
        -v "${data_dir}:/data" \
        -v "${runner}:/tmp/run-emqx-startup.sh:ro" \
        "$@" \
        --entrypoint /bin/bash \
        "${IMAGE}" \
        /tmp/run-emqx-startup.sh
}

assert_contains() {
    local output="$1"
    local expected="$2"
    local scenario="$3"

    if [[ "${output}" != *"${expected}"* ]]; then
        printf 'Expected output for "%s" to contain:\n%s\n\nActual output:\n%s\n' \
            "${scenario}" \
            "${expected}" \
            "${output}" >&2
        exit 1
    fi
}

assert_file_content() {
    local file="$1"
    local expected="$2"
    local scenario="$3"
    local actual

    actual=$(< "${file}")

    if [[ "${actual}" != "${expected}" ]]; then
        printf 'Expected %s for "%s" to contain "%s", got "%s"\n' \
            "${file}" \
            "${scenario}" \
            "${expected}" \
            "${actual}" >&2
        exit 1
    fi
}

scenario_new_install() {
    local scenario="new install"
    local data_dir="${tmpdir}/new-install"
    local output

    printf 'Running scenario: %s\n' "${scenario}"
    prepare_data_dir "${data_dir}"

    output=$(run_startup "${data_dir}")

    assert_contains "${output}" "Using EMQX node name: emqx@127.0.0.1" "${scenario}"
    assert_file_content "${data_dir}/emqx/etc/node.name" "emqx@127.0.0.1" "${scenario}"
}

scenario_single_legacy_mnesia_dir() {
    local scenario="single legacy Mnesia directory"
    local data_dir="${tmpdir}/single-legacy"
    local output

    printf 'Running scenario: %s\n' "${scenario}"
    prepare_data_dir "${data_dir}"
    mkdir -p "${data_dir}/emqx/data/mnesia/emqx@oldhost.local"

    output=$(run_startup "${data_dir}" -e BASHIO_HOSTNAME=newhost)

    assert_contains "${output}" "Adding oldhost.local to /etc/hosts" "${scenario}"
    assert_contains "${output}" "Using EMQX node name: emqx@oldhost.local" "${scenario}"
    assert_file_content "${data_dir}/emqx/etc/node.name" "emqx@oldhost.local" "${scenario}"
}

scenario_persisted_node_name() {
    local scenario="persisted node name"
    local data_dir="${tmpdir}/persisted-node"
    local output

    printf 'Running scenario: %s\n' "${scenario}"
    prepare_data_dir "${data_dir}"
    printf 'emqx@oldhost.local' > "${data_dir}/emqx/etc/node.name"

    output=$(run_startup "${data_dir}" -e BASHIO_HOSTNAME=newhost)

    assert_contains "${output}" "Adding oldhost.local to /etc/hosts" "${scenario}"
    assert_contains "${output}" "Using EMQX node name: emqx@oldhost.local" "${scenario}"
    assert_file_content "${data_dir}/emqx/etc/node.name" "emqx@oldhost.local" "${scenario}"
}

scenario_ambiguous_mnesia_dirs() {
    local scenario="ambiguous Mnesia directories"
    local data_dir="${tmpdir}/ambiguous"
    local output

    printf 'Running scenario: %s\n' "${scenario}"
    prepare_data_dir "${data_dir}"
    mkdir -p \
        "${data_dir}/emqx/data/mnesia/emqx@first.local" \
        "${data_dir}/emqx/data/mnesia/emqx@second.local"

    output=$(run_startup "${data_dir}" -e BASHIO_HOSTNAME=missing)

    assert_contains "${output}" "Multiple EMQX Mnesia node directories found" "${scenario}"
    assert_contains "${output}" "Using EMQX node name: emqx@127.0.0.1" "${scenario}"
    assert_file_content "${data_dir}/emqx/etc/node.name" "emqx@127.0.0.1" "${scenario}"
}

scenario_invalid_persisted_node_name() {
    local scenario="invalid persisted node name"
    local data_dir="${tmpdir}/invalid-node-name"
    local output
    local status

    printf 'Running scenario: %s\n' "${scenario}"
    prepare_data_dir "${data_dir}"
    printf 'emqx@bad host' > "${data_dir}/emqx/etc/node.name"

    set +e
    output=$(run_startup "${data_dir}" 2>&1)
    status=$?
    set -e

    if [ "${status}" -eq 0 ]; then
        printf 'Expected "%s" to fail, but it passed:\n%s\n' "${scenario}" "${output}" >&2
        exit 1
    fi

    assert_contains "${output}" "Invalid EMQX node name from persisted or discovered node name" "${scenario}"
}

scenario_invalid_configured_node_name() {
    local scenario="invalid configured node name"
    local data_dir="${tmpdir}/invalid-configured-node-name"
    local output
    local status

    printf 'Running scenario: %s\n' "${scenario}"
    prepare_data_dir "${data_dir}"

    set +e
    output=$(run_startup \
        "${data_dir}" \
        -e BASHIO_ENV_NAME=EMQX_NODE__NAME \
        -e "BASHIO_ENV_VALUE=emqx@bad host" 2>&1)
    status=$?
    set -e

    if [ "${status}" -eq 0 ]; then
        printf 'Expected "%s" to fail, but it passed:\n%s\n' "${scenario}" "${output}" >&2
        exit 1
    fi

    assert_contains "${output}" "Invalid EMQX node name from EMQX_NODE__NAME" "${scenario}"
}

scenario_new_install
scenario_single_legacy_mnesia_dir
scenario_persisted_node_name
scenario_ambiguous_mnesia_dirs
scenario_invalid_persisted_node_name
scenario_invalid_configured_node_name

printf 'EMQX upgrade scenarios passed\n'
