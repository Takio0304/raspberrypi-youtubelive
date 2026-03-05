#!/bin/bash

# ==========================================
# YouTube ライブ配信スクリプト (Raspberry Pi 4)
# ==========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# .envファイルの読み込み
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# ストリームキーの確認
if [ -z "$STREAM_KEY" ] || [ "$STREAM_KEY" = "xxxx-xxxx-xxxx-xxxx" ]; then
    echo "エラー: STREAM_KEY が設定されていません"
    echo "  .env ファイルにYouTubeのストリームキーを記載してください"
    exit 1
fi

# マイクデバイスのデフォルト値
AUDIO_DEVICE="${AUDIO_DEVICE:-hw:3,0}"

# 必要なコマンドの確認
if ! command -v ffmpeg &> /dev/null; then
    echo "エラー: ffmpeg がインストールされていません"
    echo "  sudo apt install ffmpeg"
    exit 1
fi

# Ctrl+Cで確実に終了するためのシグナル処理
cleanup() {
    echo ""
    echo "配信を終了します"
    exit 0
}
trap cleanup SIGINT SIGTERM

# ==========================================
# 配信実行（切断時に自動再接続）
# ==========================================
while true; do
    echo "YouTubeライブ配信を開始します..."

    ffmpeg -f v4l2 -input_format mjpeg -thread_queue_size 512 -video_size 1280x720 -framerate 30 -i /dev/video0 \
        -f alsa -thread_queue_size 512 -i "$AUDIO_DEVICE" \
        -c:v h264_v4l2m2m -b:v 2000k -pix_fmt yuv420p \
        -g 60 \
        -c:a aac -b:a 128k -ar 44100 \
        -f flv "rtmp://a.rtmp.youtube.com/live2/$STREAM_KEY"

    echo "配信が中断されました。10秒後に再接続します..."
    echo "終了するには Ctrl+C を押してください"
    sleep 10
done
