#!/usr/bin/env bash
# go-dobby SessionStart 훅 — 안전 훅(pre-bash.sh) 등록 상태 점검·안내
#
# 플러그인 hooks.json의 PreToolUse command 훅은 Claude Code 버그
# (anthropics/claude-code#34573)로 로딩 시 조용히 드랍된다. 그래서 안전 훅은
# dobby-init이 ~/.claude/settings.json에 등록해야만 동작한다(HOOKS.md "전달 경로" 참조).
# 라이프사이클(SessionStart) command 훅은 플러그인에서도 정상 발화하므로, 이 훅이
# 세션 시작마다 아래 두 경우를 감지해 안내 문구를 컨텍스트로 출력한다:
#   (1) config.env는 있는데(=go-dobby 사용자) settings.json에 안전 훅 미등록
#   (2) 등록은 됐지만 복사본이 플러그인 최신 버전과 다름(플러그인 업데이트 후 미반영)
# 그 외에는 조용히 통과(exit 0) — go-dobby를 안 쓰는 환경에는 아무 말도 하지 않는다.

set -u

# go-dobby 사용자가 아니면 침묵
[ -f "$HOME/.config/go-dobby/config.env" ] || exit 0

SETTINGS="$HOME/.claude/settings.json"
INSTALLED="$HOME/.config/go-dobby/hooks/pre-bash.sh"
# 플러그인 쪽 원본은 이 스크립트와 같은 폴더에 있다 (CLAUDE_PLUGIN_ROOT 없이도 동작)
PLUGIN_COPY="$(cd "$(dirname "$0")" && pwd)/pre-bash.sh"

# (1) settings.json에 안전 훅 미등록
if ! { [ -f "$SETTINGS" ] && grep -qF "go-dobby/hooks/pre-bash.sh" "$SETTINGS"; }; then
  cat <<'EOF'
[go-dobby] 안전 훅(pre-bash.sh)이 ~/.claude/settings.json에 등록돼 있지 않다.
플러그인의 PreToolUse 훅은 Claude Code 버그(anthropics/claude-code#34573)로 발화하지 않으므로,
지금은 G1(배포 베이스 보호)·G5(subtree 밖 파괴 차단)·G6(메타 삭제 차단)이 동작하지 않는 상태다.
사용자에게 이 사실을 알리고, /dobby-init 을 실행해 "안전 훅 등록" 단계를 완료하도록 권하라.
EOF
  exit 0
fi

# (2) 복사본이 플러그인 최신본과 다름 (업데이트 미반영)
if [ -f "$PLUGIN_COPY" ] && [ -f "$INSTALLED" ] && ! cmp -s "$PLUGIN_COPY" "$INSTALLED"; then
  cat <<'EOF'
[go-dobby] 등록된 안전 훅(~/.config/go-dobby/hooks/pre-bash.sh)이 플러그인의 최신 버전과 다르다.
플러그인이 업데이트된 뒤 복사본이 갱신되지 않은 상태다. 사용자에게 알리고 /dobby-init 재실행을 권하라.
EOF
fi

exit 0
