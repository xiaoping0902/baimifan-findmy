#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 dist/ 里的 IPA 用局域网 HTTP 服务出去，方便 iPad 直接下载 → TrollStore 安装。

用法：
    python scripts/serve_ipa.py            # 默认 8000 端口
    python scripts/serve_ipa.py 8080

然后在 iPad 上用 Safari 打开提示的地址（同一 Wi-Fi 下），点下载即可。
"""
import http.server
import os
import socket
import socketserver
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")

PAGE = """<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FindMy IPA 分发</title>
<style>
  :root { color-scheme: light dark; }
  body { font: -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
         background: #f2f2f7; color: #1c1c1e; }
  @media (prefers-color-scheme: dark) { body { background:#000; color:#fff; } }
  h1 { font-size: 22px; margin: 0 0 4px; }
  p.sub { color:#8e8e93; margin: 0 0 20px; font-size: 14px; }
  a.card { display:block; background:#fff; border-radius:14px; padding:16px 18px;
           margin-bottom:12px; text-decoration:none; color:inherit;
           box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  @media (prefers-color-scheme: dark) { a.card { background:#1c1c1e; } }
  .t { font-weight:600; font-size:17px; }
  .d { color:#8e8e93; font-size:13px; margin-top:4px; }
  .empty { color:#8e8e93; padding:32px 0; text-align:center; }
</style></head><body>
<h1>FindMy · IPA 分发</h1>
<p class="sub">在 iPad 上点下面的文件 → 用 TrollStore 安装</p>
{items}
</body></html>
"""


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=DIST, **kw)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            files = []
            if os.path.isdir(DIST):
                for fn in sorted(os.listdir(DIST)):
                    if fn.lower().endswith(".ipa"):
                        p = os.path.join(DIST, fn)
                        mb = os.path.getsize(p) / 1024 / 1024
                        files.append(
                            f'<a class="card" href="/{fn}" download>'
                            f'<div class="t">{fn}</div>'
                            f'<div class="d">{mb:.2f} MB · 点击下载</div></a>'
                        )
            body = PAGE.replace("{items}", "".join(files) or
                                '<div class="empty">dist/ 里还没有 .ipa<br>先跑一次云构建</div>')
            data = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    os.makedirs(DIST, exist_ok=True)
    ip = local_ip()

    print("=" * 60)
    print("  FindMy IPA 分发服务")
    print("=" * 60)
    print(f"  目录: {DIST}")
    print()
    print(f"  iPad 上打开 Safari，访问：")
    print(f"      http://{ip}:{port}/")
    print()
    print("  前提：iPad 与电脑在同一个 Wi-Fi / 局域网")
    print("  Ctrl+C 停止")
    print("=" * 60)

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("0.0.0.0", port), Handler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止。")


if __name__ == "__main__":
    main()
