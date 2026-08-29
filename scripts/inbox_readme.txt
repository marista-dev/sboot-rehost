[sboot-rehost] 여기에 펌웨어를 넣으세요:
  .zip / BL_*.tar.md5 / AP_*.tar.md5   (또는 이미 푼 sboot.bin / boot.img / super.img)

그 다음 Claude Code 에서:
  /sboot-rehost:start            (목표 등급 기본 F2)
  /sboot-rehost:start F1         (부트로더 표면까지만)

- 이 한 명령이 인식·언팩·도출·빌드·회차 루프·검증까지 끝까지 진행합니다.
- 워크스페이스는 rehost_workspaces/<model>_<build>/ 로 격리 생성됩니다.
- 여러 펌웨어를 넣어도 서로 덮어쓰지 않습니다. 멈춘 곳에서 다시 start 하면 이어서 갑니다.
- 상태 확인: /sboot-rehost:status,  재현 키트: /sboot-rehost:export
