#!/bin/bash

# ==========================================
# YouTube ライブ配信スクリプト (Raspberry Pi 4)
# ==========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 既存の配信プロセスを停止
EXISTING=$(pgrep -f "stream.sh" | grep -v $$)
if [ -n "$EXISTING" ]; then
    echo "既存の配信プロセスを停止します..."
    kill $EXISTING 2>/dev/null
fi
pkill -f "ffmpeg.*rtmp://.*youtube" 2>/dev/null
sleep 1

# 前回のログファイルを削除
rm -f /tmp/stream_output.log

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

# カメラの入力フォーマットに応じた解像度リストを取得
if [ "$INPUT_FORMAT" = "mjpeg" ]; then
    FORMAT_BLOCK=$(echo "$CAMERA_FORMATS" | sed -n '/MJPG/,/^\[/p')
else
    FORMAT_BLOCK=$(echo "$CAMERA_FORMATS" | sed -n '/YUYV/,/^\[/p')
fi

# 優先解像度リスト（高い順）
RESOLUTION_LIST=("1920x1080" "1280x720" "960x720" "960x544" "864x480" "800x600" "640x480" "640x360")

# 指定解像度の最大fpsを取得する関数
get_fps_for_resolution() {
    local res="$1"
    local block
    block=$(echo "$FORMAT_BLOCK" | sed -n "/$res/,/Size:/p")
    if [ -n "$block" ]; then
        local fps
        fps=$(echo "$block" | grep -oP '[0-9.]+(?= fps)' | head -1)
        if [ -n "$fps" ]; then
            echo "${fps%.*}"
            return 0
        fi
    fi
    return 1
}

# 解像度とfpsを決定（VIDEO_SIZE指定時はそれを最優先候補にする）
detect_resolution() {
    local start_index=0

    if [ -n "$VIDEO_SIZE" ]; then
        # 指定解像度のfpsが取得できればそれを使う
        local fps
        fps=$(get_fps_for_resolution "$VIDEO_SIZE")
        if [ $? -eq 0 ]; then
            BEST_RESOLUTION="$VIDEO_SIZE"
            BEST_FPS="$fps"
            return
        fi
        echo "警告: ${VIDEO_SIZE} はこのカメラでサポートされていません。自動検出します..."
    fi

    # 自動検出：優先解像度リストを上から試す
    for RES in "${RESOLUTION_LIST[@]}"; do
        local fps
        fps=$(get_fps_for_resolution "$RES")
        if [ $? -eq 0 ]; then
            BEST_RESOLUTION="$RES"
            BEST_FPS="$fps"
            return
        fi
    done

    BEST_RESOLUTION="640x480"
    BEST_FPS="30"
}

detect_resolution
echo "解像度: $BEST_RESOLUTION"
echo "フレームレート: ${BEST_FPS}fps"

# 解像度に応じたビットレート設定
get_bitrate() {
    case "$1" in
        1920x1080) echo "4500k" ;;
        1280x720)  echo "2000k" ;;
        *)         echo "1000k" ;;
    esac
}
VIDEO_BITRATE=$(get_bitrate "$BEST_RESOLUTION")
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
# 配信実行（負荷が高い場合は品質を自動で下げる）
# ==========================================
FAIL_COUNT=0

while true; do
    echo "YouTubeライブ配信を開始します..."
    echo "  解像度=${BEST_RESOLUTION} fps=${BEST_FPS} bitrate=${VIDEO_BITRATE}"

    START_TIME=$(date +%s)

    # maxrate/bufsizeでビットレートの急変動を抑制
    # -framedrop で処理落ち時にフレームを捨てて追従
    ffmpeg -f v4l2 -input_format "$INPUT_FORMAT" -thread_queue_size 512 -video_size "$BEST_RESOLUTION" -framerate "$BEST_FPS" -i "$VIDEO_DEVICE" \
        -f alsa -ac "$AUDIO_CHANNELS" -thread_queue_size 512 -i "$ALSA_DEVICE" \
        -c:v $VIDEO_ENCODER -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "$VIDEO_BITRATE" -pix_fmt yuv420p \
        -g "$GOP_SIZE" -framedrop \
        -c:a aac -b:a 128k -ar 44100 \
        -f flv "rtmp://a.rtmp.youtube.com/live2/$STREAM_KEY"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    # 30秒以内に落ちた場合は負荷が高すぎる可能性
    if [ "$DURATION" -lt 30 ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "配信が ${DURATION}秒 で停止しました（連続失敗: ${FAIL_COUNT}回）"

        if [ "$FAIL_COUNT" -ge 2 ]; then
            # 現在の解像度より低い解像度にフォールバック
            FOUND_CURRENT=false
            NEW_RESOLUTION=""
            for RES in "${RESOLUTION_LIST[@]}"; do
                if [ "$FOUND_CURRENT" = true ]; then
                    local_fps=$(get_fps_for_resolution "$RES")
                    if [ $? -eq 0 ]; then
                        NEW_RESOLUTION="$RES"
                        NEW_FPS="$local_fps"
                        break
                    fi
                fi
                if [ "$RES" = "$BEST_RESOLUTION" ]; then
                    FOUND_CURRENT=true
                fi
            done

            if [ -n "$NEW_RESOLUTION" ]; then
                echo "品質を下げて再試行します: ${BEST_RESOLUTION} → ${NEW_RESOLUTION}"
                BEST_RESOLUTION="$NEW_RESOLUTION"
                BEST_FPS="$NEW_FPS"
                VIDEO_BITRATE=$(get_bitrate "$BEST_RESOLUTION")
                GOP_SIZE=$((BEST_FPS * 2))
                FAIL_COUNT=0
            else
                echo "これ以上品質を下げられません。10秒後に再試行します..."
            fi
        fi
    else
        # 30秒以上動いていたらカウントリセット
        FAIL_COUNT=0
    fi

    echo "配信が中断されました。10秒後に再接続します..."
    echo "終了するには Ctrl+C を押してください"
    sleep 10
done
