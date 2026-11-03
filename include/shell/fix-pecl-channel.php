<?php
/**
 * 修复 PECL 频道注册表 (pecl.php.net)。
 *
 * 背景：
 *   PEAR 1.10.13 自带的 raw-socket HTTP 客户端在解析 CDN(BunnyCDN) 返回的响应时，
 *   会把 ETag 的数字前缀(如 "288-654705e9c691d" 中的 288)混入响应体开头，
 *   导致 channel.xml 解析失败并报：
 *     XML Error: 'Not well-formed (invalid token)' on line '1'
 *   由于 Dockerfile 使用 set -eux，该命令返回非 0 会直接中断镜像构建。
 *
 * 解决办法：
 *   1) 改用 PHP 原生 HTTP 客户端拉取 channel.xml(不受 PEAR 该缺陷影响)；
 *   2) 剥离可能混入的前缀污染；
 *   3) 解析后连同服务端的 ETag / Last-Modified 一起写回 PEAR 频道注册表。
 *      保留 ETag 至关重要：PEAR 后续发 If-None-Match 时服务端返回 304，
 *      从而完全避开其有缺陷的下载路径；缺少 ETag 则会退回 200 + 污染响应体。
 *
 * 失败时以非 0 退出但仅告警，不阻断构建（扩展安装有直接下载 tgz 的主路径）。
 */

$registryDir = "/usr/local/lib/php/.channels";
$regFile = $registryDir . "/pecl.php.net.reg";
$url = "https://pecl.php.net/channel.xml";

$ctx = stream_context_create([
    "http" => ["timeout" => 60, "ignore_user_abort" => true],
]);
$xml = @file_get_contents($url, false, $ctx);
if ($xml === false) {
    fwrite(STDERR, "[pecl-fix] 无法获取 channel.xml: $url\n");
    exit(1);
}

// 剥离 CDN ETag 数字前缀污染
$clean = preg_replace('/^[0-9]+\r?\n/', "", $xml);
if (strpos(ltrim($clean), "<?xml") !== 0) {
    fwrite(STDERR, "[pecl-fix] channel.xml 内容异常, 已跳过\n");
    exit(1);
}

// 从响应头提取 ETag / Last-Modified
$etag = null;
$lastModified = null;
if (isset($http_response_header) && is_array($http_response_header)) {
    foreach ($http_response_header as $h) {
        if (stripos($h, "ETag:") === 0) {
            $etag = trim(substr($h, 5));
        } elseif (stripos($h, "Last-Modified:") === 0) {
            // 注意: "Last-Modified:" 长度为 14，必须从索引 14 开始截取，
            // 否则会多带一个冒号，导致服务端忽略条件请求而返回 200(被污染的响应体)。
            $lastModified = trim(substr($h, 14));
        }
    }
}
// 日期格式非法时直接丢弃: PEAR 会把它放进 If-Modified-Since，
// 非法日期会让服务端忽略条件请求、退回 200 响应，等于没做条件请求。
if (
    $lastModified !== null &&
    !preg_match(
        '/^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/',
        $lastModified,
    )
) {
    $lastModified = null;
}

// 用 PEAR 自身的 ChannelFile 解析并序列化, 保证注册表格式正确
// 优先使用安装目录中的 PEAR 类文件; 缺失时回退到 install-pear phar
$channelFile = "/usr/local/lib/php/PEAR/ChannelFile.php";
if (is_file($channelFile)) {
    require_once $channelFile;
} else {
    $phar = "/usr/local/lib/php/PEAR/install-pear-nozlib.phar";
    if (!is_file($phar)) {
        fwrite(STDERR, "[pecl-fix] 找不到 PEAR ChannelFile, 已跳过\n");
        exit(1);
    }
    Phar::loadPhar($phar, "install-pear-nozlib.phar");
    set_include_path("phar://" . $phar);
    require_once "phar://" . $phar . "/PEAR/ChannelFile.php";
}

$channel = new PEAR_ChannelFile();
if (!$channel->fromXmlString($clean)) {
    $errs = $channel->getErrors(true);
    fwrite(
        STDERR,
        "[pecl-fix] channel.xml 解析失败: " . count($errs) . " 个错误\n",
    );
    exit(1);
}
if (strtolower($channel->getName()) !== "pecl.php.net") {
    fwrite(STDERR, "[pecl-fix] 频道名不匹配: " . $channel->getName() . "\n");
    exit(1);
}

$info = $channel->toArray();
$info["_lastmodified"] = [];
if ($etag !== null) {
    $info["_lastmodified"]["ETag"] = $etag;
}
if ($lastModified !== null) {
    $info["_lastmodified"]["Last-Modified"] = $lastModified;
}
if (empty($info["_lastmodified"])) {
    $info["_lastmodified"] = [
        "Last-Modified" => gmdate("D, d M Y H:i:s", time()) . " GMT",
    ];
}

if (!is_dir($registryDir)) {
    @mkdir($registryDir, 0777, true);
}
if (@file_put_contents($regFile, serialize($info)) === false) {
    fwrite(STDERR, "[pecl-fix] 无法写入注册表: $regFile\n");
    exit(1);
}

echo "[pecl-fix] pecl.php.net 频道注册表已修复 (" .
    strlen($clean) .
    " bytes)\n";
exit(0);
