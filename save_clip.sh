#!/bin/bash

# ==========================================
# 直近20分のセグメントを結合して保存
# ==========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEGMENTS_DIR="$SCRIPT_DIR/recordings/segments"
REC_DIR="$SCRIPT_DIR/recordings"

# ロックファイルで同時実行を防止
LOCK_FILE="/tmp/save_clip.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "別の保存処理が実行中です"
    exit 0
fi
trap "rm -f $LOCK_FILE" EXIT
touch "$LOCK_FILE"

# 直近25分以内のセグメントを取得（20分 + セグメント境界のバッファ）
SEGMENTS=$(find "$SEGMENTS_DIR" -name "seg_*.ts" -mmin -25 -type f 2>/dev/null | sort)

if [ -z "$SEGMENTS" ]; then
    echo "保存するセグメントがありません"
    exit 1
fi

# concat リストを作成
CONCAT_FILE=$(mktemp /tmp/concat_XXXXXX.txt)
for seg in $SEGMENTS; do
    echo "file '$seg'" >> "$CONCAT_FILE"
done

# MP4として保存
OUTPUT="$REC_DIR/clip_$(date +%Y%m%d_%H%M%S).mp4"
ffmpeg -f concat -safe 0 -i "$CONCAT_FILE" -c copy "$OUTPUT" 2>/dev/null

rm -f "$CONCAT_FILE"

if [ -f "$OUTPUT" ]; then
    SIZE=$(du -h "$OUTPUT" | cut -f1)
    echo "録画を保存しました: $OUTPUT ($SIZE)"
else
    echo "録画の保存に失敗しました"
fi
