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

# 必要なコマンドの確認
if ! command -v ffmpeg &> /dev/null; then
    echo "エラー: ffmpeg がインストールされていません"
    echo "  sudo apt install ffmpeg"
    exit 1
fi

# ==========================================
# デバイス自動検出
# ==========================================
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
AUDIO_DEVICE="${AUDIO_DEVICE:-hw:3,0}"

# hw:X,Y → plughw:X,Y に変換（ALSAが自動でフォーマット変換してくれる）
ALSA_DEVICE="${AUDIO_DEVICE/hw:/plughw:}"

echo "=== デバイス自動検出 ==="

# カメラの存在確認
if [ ! -e "$VIDEO_DEVICE" ]; then
    echo "エラー: カメラが見つかりません ($VIDEO_DEVICE)"
    exit 1
fi

# カメラの入力フォーマット検出（MJPEG優先、なければYUYV）
CAMERA_FORMATS=$(v4l2-ctl --list-formats-ext -d "$VIDEO_DEVICE" 2>/dev/null)
if echo "$CAMERA_FORMATS" | grep -q "MJPG"; then
    INPUT_FORMAT="mjpeg"
else
    INPUT_FORMAT="yuyv422"
fi
echo "入力フォーマット: $INPUT_FORMAT"

# カメラの最適な解像度とフレームレートを検出
if [ "$INPUT_FORMAT" = "mjpeg" ]; then
    FORMAT_BLOCK=$(echo "$CAMERA_FORMATS" | sed -n '/MJPG/,/^\[/p')
else
    FORMAT_BLOCK=$(echo "$CAMERA_FORMATS" | sed -n '/YUYV/,/^\[/p')
fi

if [ -n "$VIDEO_SIZE" ]; then
    # .envで解像度が指定されている場合、そのfpsを取得
    BEST_RESOLUTION="$VIDEO_SIZE"
    RES_BLOCK=$(echo "$FORMAT_BLOCK" | sed -n "/$VIDEO_SIZE/,/Size:/p")
    BEST_FPS=$(echo "$RES_BLOCK" | grep -oP '[0-9.]+(?= fps)' | head -1)
    BEST_FPS="${BEST_FPS%.*}"
    BEST_FPS="${BEST_FPS:-30}"
else
    # 自動検出：優先解像度リスト（高い順）
    BEST_RESOLUTION=""
    BEST_FPS=0
    for RES in "1920x1080" "1280x720" "960x720" "960x544" "864x480" "800x600" "640x480" "640x360"; do
        RES_BLOCK=$(echo "$FORMAT_BLOCK" | sed -n "/$RES/,/Size:/p")
        if [ -n "$RES_BLOCK" ]; then
            FPS=$(echo "$RES_BLOCK" | grep -oP '[0-9.]+(?= fps)' | head -1)
            if [ -n "$FPS" ]; then
                BEST_RESOLUTION="$RES"
                BEST_FPS="${FPS%.*}"
                break
            fi
        fi
    done
    BEST_RESOLUTION="${BEST_RESOLUTION:-640x480}"
    BEST_FPS="${BEST_FPS:-30}"
fi

echo "解像度: $BEST_RESOLUTION"
echo "フレームレート: ${BEST_FPS}fps"

# 解像度に応じたビットレート設定
case "$BEST_RESOLUTION" in
    1920x1080) VIDEO_BITRATE="4500k" ;;
    1280x720)  VIDEO_BITRATE="2000k" ;;
    *)         VIDEO_BITRATE="1000k" ;;
esac
echo "ビットレート: $VIDEO_BITRATE"

# キーフレーム間隔（2秒分）
GOP_SIZE=$((BEST_FPS * 2))

# マイクのチャンネル数を自動検出
AUDIO_CHANNELS=$(arecord -D "$AUDIO_DEVICE" --dump-hw-params 2>&1 | grep -oP 'CHANNELS: \K[0-9]+' | head -1)
AUDIO_CHANNELS="${AUDIO_CHANNELS:-1}"
echo "マイク: ${AUDIO_DEVICE} → ${ALSA_DEVICE} (${AUDIO_CHANNELS}ch)"

# エンコーダ検出（HWエンコーダ優先）
if ffmpeg -encoders 2>/dev/null | grep -q h264_v4l2m2m; then
    VIDEO_ENCODER="h264_v4l2m2m"
elif ffmpeg -encoders 2>/dev/null | grep -q h264_omx; then
    VIDEO_ENCODER="h264_omx"
else
    VIDEO_ENCODER="libx264 -preset ultrafast"
fi
echo "エンコーダ: $VIDEO_ENCODER"

echo "========================="

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

    ffmpeg -f v4l2 -input_format "$INPUT_FORMAT" -thread_queue_size 512 -video_size "$BEST_RESOLUTION" -framerate "$BEST_FPS" -i "$VIDEO_DEVICE" \
        -f alsa -ac "$AUDIO_CHANNELS" -thread_queue_size 512 -i "$ALSA_DEVICE" \
        -c:v $VIDEO_ENCODER -b:v "$VIDEO_BITRATE" -pix_fmt yuv420p \
        -g "$GOP_SIZE" \
        -c:a aac -b:a 128k -ar 44100 \
        -f flv "rtmp://a.rtmp.youtube.com/live2/$STREAM_KEY"

    echo "配信が中断されました。10秒後に再接続します..."
    echo "終了するには Ctrl+C を押してください"
    sleep 10
done
