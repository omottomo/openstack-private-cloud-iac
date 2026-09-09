# openstack-private-cloud-iac

## Git 작업 — 필수

커밋·브랜치·push·PR 등 모든 git 작업 전에 **git-workflow** 스킬(`/git-workflow`)을 호출하고 그 규칙을 따른다.

- `main` 직접 커밋·push·merge 금지 — 로컬 hook(`.git/hooks/`, `.claude/hooks/git-guard.sh`)이 차단한다.
- 브랜치는 `<type>/<slug>` (type: feat|fix|refactor|docs|chore, slug는 영어 kebab-case 2~4단어).
- 제목은 영어 Conventional Commits, 본문은 한국어로 짧게 — 형식은 `.claude/git-message-template.md`를 따른다.
- 모든 커밋과 PR 본문 마지막 줄에 `Task: <slug>`. 이력 검색 키다 — `git log --grep="Task: <slug>"`.
