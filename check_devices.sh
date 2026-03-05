#!/bin/bash

# ==========================================
# 配信前の事前確認スクリプト
# ==========================================

# 必要なコマンドの確認
MISSING=()
command -v ffmpeg &> /dev/null || MISSING+=("ffmpeg")
command -v v4l2-ctl &> /dev/null || MISSING+=("v4l2-utils")
command -v arecord &> /dev/null || MISSING+=("alsa-utils")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "エラー: 以下のパッケージがインストールされていません"
    echo "  sudo apt install ${MISSING[*]}"
    exit 1
fi

echo "=== カメラの対応解像度 ==="
v4l2-ctl --list-formats-ext -d /dev/video0
echo ""

echo "=== マイクのデバイス一覧 ==="
arecord -l
echo ""

echo "=== 利用可能なH.264エンコーダ ==="
ffmpeg -encoders 2>/dev/null | grep h264
