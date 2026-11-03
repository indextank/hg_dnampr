# PHP 安全补丁

本目录存放针对 PHP 官方 CVE 的源码补丁，在镜像构建阶段于 PHP 源码解压后、`./configure` 之前通过 `patch -p1` 应用。

## CVE-2026-109618 / CVE-2026-109619

- **GHSA**: [GHSA-w8hw-w9fx-j79w](https://github.com/advisories/GHSA-w8hw-w9fx-j79w) (CVE-2026-109618)、[GHSA-6wmf-4rv5-p3rp](https://github.com/advisories/GHSA-6wmf-4rv5-p3rp) (CVE-2026-109619)
- **主题**: Avoid state corruption via bailout（EOL 版本的最小缓解补丁）
- **官方分支补丁来源**（每版本仅应用与其版本号对应的分支）：

| PHP 版本 | 源码版本 | 补丁文件 | 上游分支 | Commit |
| -------- | -------- | -------- | -------- | ------ |
| 7.4 | 7.4.33 | `php7.4-CVE-2026-109618-109619.patch` | https://github.com/php/php-src/tree/PHP-7.4-CVE-2026-109618-109619 | `712e60f9edfd03f0960fc4fc3c2c375f42b90aa2` |
| 8.0 | 8.0.30 | `php8.0-CVE-2026-109618-109619.patch` | https://github.com/php/php-src/tree/PHP-8.0-CVE-2026-109618-109619 | `82f8f31b16a035c1b67cc253e79f7cc288f4cc20` |
| 8.1 | 8.1.33 | `php8.1-CVE-2026-109618-109619.patch` | https://github.com/php/php-src/tree/PHP-8.1-CVE-2026-109618-109619 | `1d7dec178a094e6e75b229ce22754045f8c6070a` |

补丁通过 `https://github.com/php/php-src/commit/<sha>.patch` 获取，已在对应发布源码包上验证可干净应用（无 fuzz/offset）。

## 应用方式

各版本 Dockerfile（`build/php/<版本>/Dockerfile`）中：

```dockerfile
COPY ./build/php/patches/php<版本>-CVE-2026-109618-109619.patch ${TMP_DIR}/
...
# 源码解压后、configure 前
patch -p1 --forward --directory="php" --input="${TMP_DIR}/php<版本>-CVE-2026-109618-109619.patch";
```

## 升级 PHP 小版本时

若升级 `env/php.env` 中的 `PHP<XX>_VERSION`，需重新验证本补丁能否干净应用到新源码包（`patch -p1 --dry-run`）；若上游分支更新，应同步更新对应补丁文件。
