#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly ROOT_DIR
readonly PHP_VERSIONS=(7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6)

status=0
for version in "${PHP_VERSIONS[@]}"; do
	for file in Dockerfile hardening.ini; do
		if ! cmp -s \
			"${ROOT_DIR}/build/php/common/${file}" \
			"${ROOT_DIR}/build/php/${version}/${file}"; then
			printf '[FAIL] PHP %s %s 与 common 真源不一致\n' "${version}" "${file}" >&2
			status=1
		fi
	done
done

while read -r expected filename; do
	case "${filename}" in
		php-*.tar.xz) source_file="${ROOT_DIR}/src/php/${filename}" ;;
		openssl-*.tar.gz) source_file="${ROOT_DIR}/src/openssl/${filename}" ;;
		*) continue ;;
	esac
	# src/ 是本地缓存，允许尚未下载；已存在的归档必须与锁定摘要一致。
	if [[ -f "${source_file}" ]]; then
		actual="$(sha256sum "${source_file}" | awk '{print $1}')"
		if [[ "${actual}" != "${expected}" ]]; then
			printf '[FAIL] 源码摘要不匹配: %s\n' "${source_file}" >&2
			status=1
		fi
	fi
done < "${ROOT_DIR}/build/php/checksums.sha256"

if (( status != 0 )); then
	exit "${status}"
fi

printf 'RESULT: PASS（PHP Dockerfile/hardening 无配置漂移）\n'
