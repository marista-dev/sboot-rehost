---
name: rehost-bootloader
description: (폐기됨 · v0.19.0) 트랙 1 (부트로더) 실행 명령이었다. 트랙 2종이 통합 체인 하나로 대체되어 이 명령은 더 이상 파이프라인을 호출하지 않는다. /sboot-rehost:rehost-full 로 안내하고 종료한다.
disable-model-invocation: true
---

# ⚠ 이 명령은 폐기됐습니다 (v0.19.0)

**`workflows/pipeline.js` 를 호출하지 마십시오.** 이 명령이 넘기던 `track` 인자는
파이프라인에서 제거됐고, 그대로 호출하면 인자가 무시된 채 다른 의미로 실행됩니다.

## 사용자에게 이렇게 안내하고 종료한다

> `/sboot-rehost:rehost-bootloader` 은 **`/sboot-rehost:rehost-full`** 로 대체됐습니다.
>
> 트랙 2종(부트로더 / 커널)이 **하나의 연속 체인**으로 합쳐졌습니다. 컨테이너를 한 번
> 올리고 첫 스테이지부터 커널 rootfs 까지 갑니다 — 부트로더가 커널을 직접 읽어 적재하므로
> `-kernel Image` 를 쓰지 않습니다.
>
> | 예전 | 지금 |
> |---|---|
> | 트랙 1 (부트로더) | `/sboot-rehost:rehost-full --target F1` |
>
> 등급: **F1** 부트로더 체인 · **F2** 정식 커널 부팅 · **F3** 완주(rootfs).
> 워크스페이스와 `INPUT.md` 는 그대로 재사용됩니다.

## 그리고 확인할 것

이 명령이 아직 목록에 보인다면 **옛 플러그인 버전이 로드돼 있을 수 있습니다.**
`/sboot-rehost:rehost-full` 이 보이지 않으면 갱신이 필요합니다:

```
/plugin marketplace update sboot-rehost-marketplace
/plugin install sboot-rehost@sboot-rehost-marketplace
/reload-plugins        # 또는 Claude Code 재시작
```

자세한 내용: [../rehost-full/SKILL.md](../rehost-full/SKILL.md)
