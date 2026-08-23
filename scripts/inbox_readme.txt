[sboot-rehost] 여기에 펌웨어를 넣으세요:
  .zip / BL_*.tar.md5 / AP_*.tar.md5   (또는 이미 푼 sboot.bin / boot.img / super.img)

그 다음 Claude Code 에서:
  /sboot-rehost:rehost-setup <이름> model=SM-XXXX target=<F1 | F2 | F3>

- 워크스페이스는 rehost_workspaces/<model>_<build>/ 로 격리 생성됩니다.
- 여러 펌웨어를 넣어도 서로 덮어쓰지 않습니다.
- 실행: /sboot-rehost:rehost-full,  상태: /sboot-rehost:rehost-status
