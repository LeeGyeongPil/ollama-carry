# 보안 정책 / Security policy

보안 취약점을 발견하셨다면 **공개 이슈 대신** 이 레포의 **Security → Report a vulnerability**(비공개 취약점 신고)로 알려 주세요. 확인 후 답변드리고, 고친 버전을 릴리스하면서 함께 안내합니다.

If you find a security issue, please **do not open a public issue**. Use **Security → Report a vulnerability** in this repository to report it privately. We will reply after checking and announce the fix with a release.

신고 대상 예: 악의적으로 만든 묶음(.carry.tar)을 가져올 때 대상 폴더 밖에 파일이 써지거나(경로 탐색·심볼릭 링크), 해시 검증을 우회해 손상된 블롭이 설치되는 경우.
Examples: a crafted bundle that makes `import` write outside the target folder (path traversal, links), or that gets a damaged blob installed despite the hash check.

이 도구는 오프라인 전용입니다. 네트워크 포트를 열지 않고 서버도 없으며, 인자로 넘긴 폴더·파일만 읽고 씁니다. / This tool is offline-only: it opens no network ports, runs no server, and reads/writes only the folders and files you pass.
