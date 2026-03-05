#!/usr/bin/env python3

# ==========================================
# YouTubeライブチャット監視スクリプト
# "rec" コメントを検出して直近20分の録画を保存
# ==========================================

import subprocess
import sys
import os
import time

try:
    from chat_downloader import ChatDownloader
except ImportError:
    print("エラー: chat_downloader がインストールされていません")
    print("  pip3 install chat-downloader")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# .envファイルの読み込み
env_path = os.path.join(SCRIPT_DIR, ".env")
if os.path.exists(env_path):
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                value = value.strip().strip('"').strip("'")
                os.environ.setdefault(key.strip(), value)

VIDEO_URL = os.environ.get("YOUTUBE_VIDEO_URL", "")

if not VIDEO_URL:
    print("エラー: YOUTUBE_VIDEO_URL が設定されていません")
    print("  .env に配信のURLを設定してください")
    print('  例: YOUTUBE_VIDEO_URL="https://www.youtube.com/watch?v=XXXXX"')
    sys.exit(1)

COOLDOWN_SEC = 120  # 連続保存を防ぐクールダウン（秒）

print(f"チャット監視を開始: {VIDEO_URL}")
print(f"  「rec」コメントで直近20分の録画を保存します")
print(f"  クールダウン: {COOLDOWN_SEC}秒")

last_save_time = 0

while True:
    try:
        chat = ChatDownloader().get_chat(VIDEO_URL)
        for message in chat:
            text = message.get("message", "").strip().lower()
            if text == "rec":
                now = time.time()
                author = message.get("author", {}).get("name", "不明")

                if now - last_save_time < COOLDOWN_SEC:
                    remaining = int(COOLDOWN_SEC - (now - last_save_time))
                    print(f"  クールダウン中（残り{remaining}秒）: {author} からの rec を無視")
                    continue

                print(f"録画リクエスト検出: {author}")
                result = subprocess.run(
                    ["bash", os.path.join(SCRIPT_DIR, "save_clip.sh")],
                    capture_output=True, text=True
                )
                print(result.stdout.strip())
                if result.stderr.strip():
                    print(f"  エラー: {result.stderr.strip()}")
                last_save_time = time.time()

    except KeyboardInterrupt:
        print("\nチャット監視を終了します")
        sys.exit(0)
    except Exception as e:
        print(f"チャット監視エラー: {e}")
        print("30秒後に再試行します...")
        time.sleep(30)
