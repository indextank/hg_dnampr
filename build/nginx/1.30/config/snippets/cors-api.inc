# API CORS 白名单（依赖 nginx.conf 中 $cors_allow_* map） # 在 *.api.* server 块内：include
/etc/nginx/conf/snippets/cors-api.inc; more_set_headers "Access-Control-Allow-Origin:
$cors_allow_origin"; more_set_headers "Access-Control-Allow-Credentials: $cors_allow_credentials";
more_set_headers "Access-Control-Allow-Methods: $cors_allow_methods"; more_set_headers
"Access-Control-Allow-Headers: $cors_allow_headers"; more_set_headers "Access-Control-Max-Age:
$cors_allow_max_age"; more_set_headers "Vary: Origin"; set $cors_opt ""; if ($request_method =
OPTIONS) { set $cors_opt "${cors_opt}O"; } if ($cors_allow_origin = "") { set $cors_opt
"${cors_opt}E"; } if ($cors_opt = OE) { return 403; } if ($cors_opt = O) { return 204; }
