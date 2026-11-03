#!/bin/sh
# =============================================================================
# PostgreSQL PGDG apt 安装（供 build/postgres/*/bookworm/Dockerfile 调用）
# -----------------------------------------------------------------------------
# 策略（PG_PIN_POLICY）：
#   prefer（默认若传入版本）— 优先 postgresql-$PG_MAJOR=$PG_VERSION；缺失则 Candidate
#   exact                     — 必须命中 PG_VERSION
#   latest                    — 忽略钉选，安装通道 Candidate
#
# 环境变量：
#   PG_MAJOR        主版本，如 18
#   PG_VERSION      完整 apt 版本，如 18.4-1.pgdg12+1；空 / latest 视为不钉选
#   PG_PIN_POLICY   prefer | exact | latest
# =============================================================================
set -eu

PG_MAJOR="${PG_MAJOR:-18}"
PG_PIN_POLICY="${PG_PIN_POLICY:-latest}"
PG_VERSION="${PG_VERSION:-}"

pkg="postgresql-${PG_MAJOR}"
want=""
case "${PG_VERSION}" in
	""|latest|LATEST) want="" ;;
	*) want="${PG_VERSION}" ;;
esac

apt_candidate() {
	apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }'
}

apt_has_version() {
	apt-cache show "$1=$2" >/dev/null 2>&1
}

resolve_pkg_ver() {
	_pkg="$1"
	case "${PG_PIN_POLICY}" in
		latest)
			apt_candidate "${_pkg}"
			;;
		exact)
			if [ -z "${want}" ]; then
				echo "ERROR: PG_PIN_POLICY=exact requires PG_VERSION" >&2
				exit 1
			fi
			if ! apt_has_version "${_pkg}" "${want}"; then
				echo "ERROR: ${_pkg}=${want} not in apt index" >&2
				apt-cache policy "${_pkg}" >&2 || true
				exit 1
			fi
			echo "${want}"
			;;
		prefer|*)
			if [ -n "${want}" ] && apt_has_version "${_pkg}" "${want}"; then
				echo "${want}"
			else
				_cand="$(apt_candidate "${_pkg}")"
				if [ -n "${want}" ]; then
					echo "WARNING: ${_pkg}=${want} not in apt index; falling back to Candidate=${_cand}" >&2
				fi
				echo "${_cand}"
			fi
			;;
	esac
}

echo "PostgreSQL apt install: PG_MAJOR=${PG_MAJOR} PG_VERSION=${PG_VERSION:-<empty>} POLICY=${PG_PIN_POLICY}"

pkg_ver="$(resolve_pkg_ver "$pkg")"
if [ -z "${pkg_ver}" ] || [ "${pkg_ver}" = "(none)" ]; then
	echo "ERROR: cannot resolve ${pkg} version from apt" >&2
	apt-cache policy "$pkg" >&2 || true
	exit 1
fi

echo "Installing ${pkg}=${pkg_ver}"
apt-get install -y --no-install-recommends "${pkg}=${pkg_ver}"

mkdir -p /etc/postgresql
printf '%s\n' "${pkg_ver}" > /etc/postgresql/pg_pkg_version
printf 'PG_PKG_VERSION=%s\n' "${pkg_ver}" > /etc/postgresql/pg_pkg_version.env
echo "Installed PostgreSQL package version: ${pkg_ver}"
