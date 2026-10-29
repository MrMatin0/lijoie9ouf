#!/bin/sh
set -e

# خواندن متغیرهای محیطی از داشبورد Back4app (یا استفاده از مقادیر پیش‌فرض)
PORT=${PORT:-8080}
UUID=${UUID:-"d342d11e-d424-4583-b36e-524ab1f0afa4"}
WS_PATH=${WS_PATH:-"api-ws"}
XHTTP_PATH=${XHTTP_PATH:-"api-xhttp"}
GRPC_SERVICE=${GRPC_SERVICE:-"api-grpc"}

# ۱. ایجاد صفحه وب پوششی مینیمال (Fallback) برای مخفی‌سازی تانل
cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>Service Status</title>
<style>body{font-family:system-ui,sans-serif;background:#0f172a;color:#94a3b8;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.box{border:1px solid #1e293b;padding:2rem;border-radius:12px;background:#1e293b40}h3{color:#10b981;margin:0 0 .5rem 0}</style>
</head>
<body><div class="box"><h3>● Edge Node Operational</h3><p>All upstream microservices are healthy. Latency: 12ms</p></div></body>
</html>
EOF

# ۲. تولید کانفیگ هسته Xray با ۵ ورودی همزمان (VLESS & Trojan روی WS, XHTTP, gRPC)
cat << EOF > /etc/xray/config.json
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/${WS_PATH}-vless" } }
    },
    {
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "${UUID}" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/${WS_PATH}-trojan" } }
    },
    {
      "port": 10003,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/${XHTTP_PATH}", "mode": "auto" } }
    },
    {
      "port": 10004,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "${GRPC_SERVICE}-vless" } }
    },
    {
      "port": 10005,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "${UUID}" }] },
      "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "${GRPC_SERVICE}-trojan" } }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

# ۳. تولید کانفیگ Nginx با غیرفعال‌سازی کامل بافرینگ (X-Accel-Buffering: no)
cat << EOF > /etc/nginx/http.d/default.conf
server {
    listen ${PORT};
    http2 on;
    server_name _;

    root /var/www/html;
    index index.html;

    # غیرفعال کردن بافرینگ در لایه پروکسی معکوس Back4app
    add_header X-Accel-Buffering "no" always;
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # ۱. مسیر VLESS WebSocket
    location /${WS_PATH}-vless {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # ۲. مسیر Trojan WebSocket
    location /${WS_PATH}-trojan {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # ۳. مسیر VLESS XHTTP (SplitHTTP)
    location /${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # ۴. مسیر VLESS gRPC
    location /${GRPC_SERVICE}-vless {
        client_max_body_size 0;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
        grpc_pass grpc://127.0.0.1:10004;
    }

    # ۵. مسیر Trojan gRPC
    location /${GRPC_SERVICE}-trojan {
        client_max_body_size 0;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
        grpc_pass grpc://127.0.0.1:10005;
    }
}
EOF

# اجرای Xray در پس‌زمینه و بالا آوردن Nginx
/usr/local/bin/xray run -c /etc/xray/config.json &
exec nginx -g "daemon off;"
