#!/bin/zsh
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
cd -- "${0:A:h}" || exit 1
if (( $# )); then
    recipe=$1
else
    print '편집할 날짜를 입력하세요 (예: 1204). JSON 파일을 이 창으로 드래그해도 됩니다.'
    IFS= read -r recipe
    case "$recipe" in
        [0-9][0-9][0-9][0-9]) recipe="$recipe.json" ;;
        *) recipe="${(Q)recipe}" ;;
    esac
fi
if [[ ! -f "$recipe" ]]; then
    print -u2 "입력 파일을 찾을 수 없습니다. $recipe"
    exit 1
fi
if ! open -b io.palmier.pro 2>/dev/null; then
    [[ -f "설치 및 권한 안내.txt" ]] && open "설치 및 권한 안내.txt"
    print -u2 'Palmier Pro를 찾지 못했습니다. 설치 및 권한 안내를 확인하세요.'
    exit 1
fi
for attempt in {1..20}; do
    if curl --silent --output /dev/null --max-time 1 http://127.0.0.1:19789/mcp; then
        exec python3 build_prayer.py "$recipe"
    fi
    sleep 1
done
print -u2 'Palmier Pro MCP에 연결할 수 없습니다. 앱이 열린 상태에서 다시 실행하세요.'
exit 1
