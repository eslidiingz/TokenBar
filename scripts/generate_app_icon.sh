#!/bin/bash
# วิธีใช้: ./scripts/generate_app_icon.sh /path/to/icon-1024.png
# ต้องการไฟล์ PNG สี่เหลี่ยมจัตุรัส ขนาดอย่างน้อย 1024x1024

set -e

SRC="$1"
DEST="$(dirname "$0")/../TokenBar/Assets.xcassets/AppIcon.appiconset"

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "ใช้งาน: $0 /path/to/icon-1024.png"
  exit 1
fi

declare -a SIZES=(16 32 128 256 512)

for size in "${SIZES[@]}"; do
  double=$((size * 2))
  sips -z "$size" "$size" "$SRC" --out "$DEST/icon_${size}x${size}.png" > /dev/null
  sips -z "$double" "$double" "$SRC" --out "$DEST/icon_${size}x${size}@2x.png" > /dev/null
  echo "สร้าง icon_${size}x${size}.png และ icon_${size}x${size}@2x.png แล้ว"
done

echo "เสร็จแล้ว! เปิด Xcode แล้ว build ใหม่ได้เลย"
