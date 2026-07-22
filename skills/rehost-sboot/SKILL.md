---
name: rehost-sboot
description: (이름 변경됨) 트랙 1 실행 명령의 옛 이름. 이제 /sboot-rehost:rehost-bootloader 로 이름이 바뀌었다. 이 명령은 하위 호환을 위해 남아 있으며 동일하게 동작한다 — rehost-bootloader 로 그대로 위임한다.
disable-model-invocation: true
---

# 이 명령은 `/sboot-rehost:rehost-bootloader` 로 이름이 바뀌었습니다

`S-Boot` 은 삼성 Exynos 의 부트로더 **구현체 이름**이라, MediaTek LK·Qualcomm aboot 처럼
같은 단계의 다른 부트로더를 다룰 때 이름이 맞지 않았습니다. 그래서 **단계 이름**인
`rehost-bootloader` 로 바꿨습니다.

```
/sboot-rehost:rehost-bootloader     ← 앞으로 이 이름을 쓰세요
```

## 지금 할 일

1. 사용자에게 한 줄로 알립니다:
   > `rehost-sboot` 은 `rehost-bootloader` 로 이름이 바뀌었습니다. 이번에는 그대로 실행합니다.
2. **`rehost-bootloader` 스킬의 절차를 그대로 수행합니다.** 동작은 완전히 동일합니다
   (`workflows/pipeline.js` 를 `track: 1` 로 호출).
3. JOURNAL 기록의 명령 이름은 실제 수행한 `/sboot-rehost:rehost-bootloader` 로 남깁니다.

이 별칭은 몇 버전 뒤에 제거됩니다.
