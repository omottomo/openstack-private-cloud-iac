#!/bin/sh
# git-workflow-skill
input=$(cat)

block() {
  echo "git-workflow: $1" >&2
  exit 2
}

echo "$input" | grep -q -- '--no-verify' \
  && block "--no-verify 로 hook을 우회할 수 없습니다."

echo "$input" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]](main|master)([[:space:]]|["\]|$)' \
  && block "main/master 로 직접 push할 수 없습니다. 작업 브랜치와 PR을 쓰세요."

branch=$(git symbolic-ref --short HEAD 2>/dev/null)
case "$branch" in
  main|master)
    echo "$input" | grep -Eq 'git[[:space:]]+(commit|merge|push)' \
      && block "'$branch' 에서 commit/merge/push할 수 없습니다. 작업 브랜치를 만드세요."
    ;;
esac
exit 0
