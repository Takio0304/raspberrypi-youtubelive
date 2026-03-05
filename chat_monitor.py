#!/usr/bin/env python3

# ==========================================
# YouTubeライブチャット監視スクリプト (YouTube Data API v3)
# "rec" コメントを検出して直近20分の録画を保存
# ==========================================

import subprocess
import sys
import os
import time
import json
import urllib.request
import urllib.error

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

API_KEY = os.environ.get("YOUTUBE_API_KEY", "")
VIDEO_URL = os.environ.get("YOUTUBE_VIDEO_URL", "")

if not API_KEY:
    print("エラー: YOUTUBE_API_KEY が設定されていません")
    print("  .env にYouTube Data API v3のキーを設定してください")
    sys.exit(1)

if not VIDEO_URL:
    print("エラー: YOUTUBE_VIDEO_URL が設定されていません")
    sys.exit(1)

# URLからビデオIDを抽出
VIDEO_ID = VIDEO_URL.split("v=")[-1].split("&")[0] if "v=" in VIDEO_URL else VIDEO_URL

COOLDOWN_SEC = 120
POLL_INTERVAL = 30  # ポーリング間隔（秒）

API_BASE = "https://www.googleapis.com/youtube/v3"


def api_get(endpoint, params):
    params["key"] = API_KEY
    query = "&".join(f"{k}={v}" for k, v in params.items())
    url = f"{API_BASE}/{endpoint}?{query}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())


def get_live_chat_id():
    """動画IDからライブチャットIDを取得"""
    data = api_get("videos", {"id": VIDEO_ID, "part": "liveStreamingDetails"})
    items = data.get("items", [])
    if not items:
        raise Exception(f"動画が見つかりません: {VIDEO_ID}")
    chat_id = items[0].get("liveStreamingDetails", {}).get("activeLiveChatId")
    if not chat_id:
        raise Exception("ライブチャットが有効ではありません（配信中ですか？）")
    return chat_id


def poll_chat(chat_id, page_token=None):
    """チャットメッセージをポーリング"""
    params = {
        "liveChatId": chat_id,
        "part": "snippet,authorDetails",
    }
    if page_token:
        params["pageToken"] = page_token
    return api_get("liveChat/messages", params)


def main():
    print(f"チャット監視を開始: {VIDEO_URL}")
    print(f"  「rec」コメントで直近20分の録画を保存します")
    print(f"  ポーリング間隔: {POLL_INTERVAL}秒 / クールダウン: {COOLDOWN_SEC}秒")

    last_save_time = 0
    page_token = None

    # ライブチャットIDを取得
    while True:
        try:
            chat_id = get_live_chat_id()
            print(f"ライブチャットID取得: {chat_id}")
            break
        except Exception as e:
            print(f"チャットID取得エラー: {e}")
            print("30秒後に再試行します...")
            time.sleep(30)

    # 初回ポーリング（既存メッセージをスキップ）
    try:
        result = poll_chat(chat_id)
        page_token = result.get("nextPageToken")
        poll_interval = max(result.get("pollingIntervalMillis", 30000) / 1000, POLL_INTERVAL)
        print(f"既存メッセージをスキップしました（{len(result.get('items', []))}件）")
    except Exception as e:
        print(f"初回ポーリングエラー: {e}")
        poll_interval = POLL_INTERVAL

    # メインループ
    while True:
        time.sleep(poll_interval)
        try:
            result = poll_chat(chat_id, page_token)
            page_token = result.get("nextPageToken")
            poll_interval = max(result.get("pollingIntervalMillis", 30000) / 1000, POLL_INTERVAL)

            for item in result.get("items", []):
                snippet = item.get("snippet", {})
                text = snippet.get("textMessageDetails", {}).get("messageText", "").strip().lower()
                author = item.get("authorDetails", {}).get("displayName", "不明")

                if text == "rec":
                    now = time.time()
                    if now - last_save_time < COOLDOWN_SEC:
                        remaining = int(COOLDOWN_SEC - (now - last_save_time))
                        print(f"  クールダウン中（残り{remaining}秒）: {author} からの rec を無視")
                        continue

                    print(f"録画リクエスト検出: {author}")
                    result_proc = subprocess.run(
                        ["bash", os.path.join(SCRIPT_DIR, "save_clip.sh")],
                        capture_output=True, text=True
                    )
                    print(result_proc.stdout.strip())
                    if result_proc.stderr.strip():
                        print(f"  エラー: {result_proc.stderr.strip()}")
                    last_save_time = time.time()

        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.readable() else ""
            print(f"APIエラー ({e.code}): {error_body[:200]}")
            if e.code == 403:
                print("API割り当て超過の可能性。60秒待機します...")
                time.sleep(60)
            elif e.code == 404:
                print("チャットが終了しました。再取得を試みます...")
                time.sleep(30)
                try:
                    chat_id = get_live_chat_id()
                    page_token = None
                except Exception:
                    pass
            else:
                time.sleep(30)
        except KeyboardInterrupt:
            print("\nチャット監視を終了します")
            sys.exit(0)
        except Exception as e:
            print(f"エラー: {e}")
            time.sleep(30)


if __name__ == "__main__":
    main()
