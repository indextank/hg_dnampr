#!/bin/sh
# =============================================================================
# MySQL Community apt 安装（供 build/mysql/*/Dockerfile 调用）
# -----------------------------------------------------------------------------
# 背景：repo.mysql.com 的 dists/*/Packages 索引通常只保留通道「当前」版本
# （旧版 .deb 可能仍在 pool，但 apt 无法按版本号解析）。硬钉 MYSQL_VER 会在
# 上游发版后构建失败（如 8.4.11 → 8.4.13）。
#
# 策略（MYSQL_PIN_POLICY）：
#   latest（默认）— 忽略 MYSQL_VER，始终安装通道 Candidate
#   prefer         — 优先安装 MYSQL_VER-1debian12；索引中不存在则回退 Candidate
#   exact          — 必须命中 MYSQL_VER，否则失败（可复现构建）
#
# 环境变量：
#   MYSQL_VER          上游版本，如 8.4.13；空 / latest 视为不钉选
#   MYSQL_PIN_POLICY   latest | prefer | exact
#   MYSQL_DEB_SUFFIX   包后缀，默认 -1debian12（Debian 12 / bookworm）
# =============================================================================
set -eu

MYSQL_PIN_POLICY="${MYSQL_PIN_POLICY:-latest}"
MYSQL_DEB_SUFFIX="${MYSQL_DEB_SUFFIX:--1debian12}"
MYSQL_VER="${MYSQL_VER:-}"

want=""
case "${MYSQL_VER}" in
	""|latest|LATEST) want="" ;;
	*) want="${MYSQL_VER}${MYSQL_DEB_SUFFIX}" ;;
esac

apt_candidate() {
	apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }'
}

apt_has_version() {
	# show 能解析到该版本即认为索引可用（比 madison 更稳）
	apt-cache show "$1=$2" >/dev/null 2>&1
}

resolve_pkg_ver() {
	_pkg="$1"
	case "${MYSQL_PIN_POLICY}" in
		latest)
			apt_candidate "${_pkg}"
			;;
		exact)
			if [ -z "${want}" ]; then
				echo "ERROR: MYSQL_PIN_POLICY=exact requires MYSQL_VER" >&2
				exit 1
			fi
			if ! apt_has_version "${_pkg}" "${want}"; then
				echo "ERROR: ${_pkg}=${want} not in apt index (Oracle often drops older pins)" >&2
				echo "HINT: set MYSQL_PIN_POLICY=prefer|latest, or update MYSQL_*_VERSION to Candidate:" >&2
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

echo "MySQL apt install: MYSQL_VER=${MYSQL_VER:-<empty>} POLICY=${MYSQL_PIN_POLICY} SUFFIX=${MYSQL_DEB_SUFFIX}"

pkg_ver="$(resolve_pkg_ver mysql-community-server-core)"
if [ -z "${pkg_ver}" ] || [ "${pkg_ver}" = "(none)" ]; then
	echo "ERROR: cannot resolve mysql-community-server-core version from apt" >&2
	apt-cache policy mysql-community-server-core >&2 || true
	exit 1
fi

if ! apt_has_version mysql-community-client "${pkg_ver}"; then
	echo "ERROR: mysql-community-client=${pkg_ver} missing while server-core resolved" >&2
	apt-cache policy mysql-community-client >&2 || true
	exit 1
fi

echo "Installing mysql-community-client=${pkg_ver} mysql-community-server-core=${pkg_ver}"
# 仅在显式允许的降级模式（MYSQL_ALLOW_INSECURE_APT=true → /tmp/mysql-skip-gpg）下跳过包签名校验
apt_auth_opt=""
[ -f /tmp/mysql-skip-gpg ] && apt_auth_opt="--allow-unauthenticated"
apt-get install -y ${apt_auth_opt} \
	"mysql-community-client=${pkg_ver}" \
	"mysql-community-server-core=${pkg_ver}"

mkdir -p /etc/mysql
printf '%s\n' "${pkg_ver}" > /etc/mysql/mysql_pkg_version
# 供运行时/排障读取实际安装版本（ENV MYSQL_VERSION 可能仍是请求值）
printf 'MYSQL_PKG_VERSION=%s\n' "${pkg_ver}" > /etc/mysql/mysql_pkg_version.env
echo "Installed MySQL package version: ${pkg_ver}"
