#!/bin/sh
set -e

PORT=${PORT:-8080}
echo "✅ Ginagamit na port: $PORT"

# Siguraduhing mapapalitan ang port sa nginx.conf kung kinakailangan
sed -i "s/listen\s*[0-9]*\(.*\);/listen $PORT\1;/g" /usr/local/openresty/nginx/conf/nginx.conf

echo "[+] Preparing SSH host keys..."
ssh-keygen -A >/dev/null 2>&1 || true
mkdir -p /run/sshd /var/run/sshd

echo "[+] Starting SSH daemon..."
/usr/sbin/sshd

echo "[+] Starting BadVPN UDPGW on 127.0.0.1:7300..."
badvpn-udpgw \
    --listen-addr 127.0.0.1:7300 \
    --max-clients 1000 \
    --max-connections-for-client 40 \
    --loglevel warning &
UDPGW_PID=$!

echo "[+] Starting WS-to-SSH bridge..."
cat > /tmp/bridge.py <<'PYEOF'
import base64
import hashlib
import socket
import threading

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 2222
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
BUF_SIZE = 65536
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def tune_socket(sock):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    except OSError:
        pass

def recv_http_headers(client):
    data = b""
    client.settimeout(15)
    while b"\r\n\r\n" not in data and len(data) < 16384:
        chunk = client.recv(4096)
        if not chunk:
            break
        data += chunk
    client.settimeout(None)
    return data

def websocket_handshake(client, request):
    key = None
    for line in request.split(b"\r\n"):
        if line.lower().startswith(b"sec-websocket-key:"):
            key = line.split(b":", 1)[1].strip().decode("ascii", "ignore")
            break

    if not key:
        response = (
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n"
            b"\r\n"
        )
    else:
        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()
        ).decode()
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        ).encode()
    client.sendall(response)

def bridge(src, dst):
    try:
        while True:
            data = src.recv(BUF_SIZE)
            if not data:
                break
            dst.sendall(data)
    except (OSError, ConnectionError):
        pass
    finally:
        try: src.shutdown(socket.SHUT_RD)
        except OSError: pass
        try: dst.shutdown(socket.SHUT_WR)
        except OSError: pass

def handle(client):
    ssh = None
    try:
        tune_socket(client)
        request = recv_http_headers(client)
        if not request:
            client.close()
            return
        websocket_handshake(client, request)
        ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tune_socket(ssh)
        ssh.connect((SSH_HOST, SSH_PORT))
        t1 = threading.Thread(target=bridge, args=(client, ssh), daemon=True)
        t2 = threading.Thread(target=bridge, args=(ssh, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception:
        pass
    finally:
        if ssh:
            try: ssh.close()
            except OSError: pass
        try: client.close()
        except OSError: pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
server.bind((LISTEN_HOST, LISTEN_PORT))
server.listen(256)
print(f"[bridge] listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)

while True:
    client, _ = server.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PYEOF

python3 /tmp/bridge.py &
BRIDGE_PID=$!

echo "🚀 Sinisimulan ang Xray..."
/usr/local/bin/xray run -config /etc/xray.json &
XRAY_PID=$!

sleep 1

echo "🌐 Sinisimulan ang OpenResty sa port $PORT..."
exec /usr/local/openresty/bin/openresty -g "daemon off;"
