#!/bin/bash
# Allspot을 지운다: 앱, 색인 저장본, 설정, Claude Code MCP 등록. 사용자의 파일은 건드리지 않는다.
#   scripts/uninstall.sh            → /Applications/Allspot.app
#   scripts/uninstall.sh ~/Applications
set -euo pipefail

DEST="${1:-/Applications}"

osascript -e 'tell application id "com.techkwon.allspot" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do pgrep -x Allspot >/dev/null || break; sleep 0.5; done

if [ -d "$DEST/Allspot.app" ]; then
  rm -rf "$DEST/Allspot.app"
  echo "지움: $DEST/Allspot.app"
fi

DATA="$HOME/Library/Application Support/Allspot"
if [ -d "$DATA" ]; then
  rm -rf "$DATA"
  echo "지움: $DATA (색인 저장본)"
fi

defaults delete com.techkwon.allspot >/dev/null 2>&1 && echo "지움: 설정(com.techkwon.allspot)" || true

if command -v claude >/dev/null 2>&1; then
  claude mcp remove --scope user allspot >/dev/null 2>&1 && echo "지움: Claude Code MCP 등록(allspot)" || true
fi

echo "끝. 전체 디스크 접근 권한 목록에 Allspot이 남아 있으면 시스템 설정에서 빼 주세요."
