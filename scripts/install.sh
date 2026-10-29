#!/bin/bash
# Allspot.app을 응용 프로그램 폴더에 설치하고, Claude Code에 MCP 서버를 새 위치로 (다시) 등록한다.
#   scripts/install.sh            → /Applications
#   scripts/install.sh ~/Applications
#   scripts/install.sh --no-mcp   → MCP 등록은 건드리지 않음
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications"
REGISTER_MCP=1
for arg in "$@"; do
  case "$arg" in
    --no-mcp) REGISTER_MCP=0 ;;
    *) DEST="$arg" ;;
  esac
done

scripts/build-app.sh

# 돌고 있는 앱을 끝내고(색인은 끝낼 때 저장된다) 바꿔 넣는다.
osascript -e 'tell application id "com.techkwon.allspot" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Allspot >/dev/null || break; sleep 0.5; done

mkdir -p "$DEST"
rm -rf "$DEST/Allspot.app"
ditto build/Allspot.app "$DEST/Allspot.app"
TOOL="$DEST/Allspot.app/Contents/Helpers/allspot"
echo "설치: $DEST/Allspot.app"

if [ "$REGISTER_MCP" = 1 ] && command -v claude >/dev/null 2>&1; then
  claude mcp remove --scope user allspot >/dev/null 2>&1 || true
  claude mcp add --scope user allspot -- "$TOOL" mcp
  echo "MCP 등록: $TOOL mcp"
fi

open "$DEST/Allspot.app"
