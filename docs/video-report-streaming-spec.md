# Lab0 게임 비디오 리포트 스트리밍 명세

문서 상태: Implemented v1 (2026-08-14)
대상: `scripts/test-game.sh --video-report`와 Game 모드 리플레이 캡처

## 1. 목적

비디오 리포트는 모든 시뮬레이션 틱을 PNG 파일로 저장한 뒤 다시 읽어
MP4로 인코딩하지 않는다. Lab0가 정상 GPU 렌더 경로에서 읽은 raw RGBA
프레임을 FFmpeg CLI의 stdin으로 직접 전달하고, FFmpeg가 프레임을 받는
즉시 MP4로 인코딩한다.

이 변경의 목적은 다음과 같다.

1. 긴 리플레이에서 수천 개의 중간 PNG 파일 생성을 제거한다.
2. PNG 압축, 파일 생성, 디렉터리 탐색과 FFmpeg의 PNG 재디코딩 비용을
   제거한다.
3. 고정 60 Hz 리플레이와 실제 GPU 렌더 경로를 그대로 유지한다.
4. 기존의 특정 틱 PNG 결정성 검증과 비디오 리포트의 책임을 분리한다.

## 2. 비목표

다음 항목은 이 변경의 범위에 포함하지 않는다.

- FFmpeg의 C API 또는 서드파티 Odin FFmpeg 바인딩 도입
- 실시간 플레이 세션 녹화
- 오디오 녹음 또는 오디오·비디오 동기화
- MP4 바이트의 결정성 보장
- GPU 하드웨어 인코더 선택 UI
- 네트워크 스트리밍
- Viewer 모드의 영상 녹화
- 기존 PNG 시퀀스 캡처 기능 제거

## 3. 책임 경계

비디오와 회귀 검증은 서로 다른 산출물을 사용한다.

| 목적 | 권위 있는 산출물 | 설명 |
| --- | --- | --- |
| 게임 규칙 재현 | 버전 관리된 리플레이 JSON | 60 Hz 입력 스트림의 원본 |
| 픽셀 결정성 | 동일 틱에서 반복 캡처한 PNG 2장 | 바이트 단위로 비교 |
| 사람의 원격 검토 | 스트리밍으로 생성한 MP4 | 손실 압축된 리뷰 산출물 |
| 빠른 육안 검사 | MP4에서 추출한 contact sheet | 대표 시점 미리보기 |

MP4의 바이트나 해시는 회귀 판정 기준이 아니다. H.264 인코더 버전과
플랫폼에 따라 결과 바이트가 달라질 수 있다. 리플레이 JSON과 고정 틱 PNG
결정성 검사는 계속 권위 있는 테스트 결과로 취급한다.

## 4. 사용자 인터페이스

Game 모드에 다음 옵션을 추가한다.

```text
--game-video-output <path.mp4>
```

예시:

```sh
/tmp/lab0-game-video \
  --mode game \
  --game-replay replays/traversal-dash-smoke.json \
  --game-video-output artifacts/report/game-test.mp4 \
  --capture-case traversal-video-report \
  --capture-target composite
```

### 유효성 규칙

- `--game-video-output`은 `--mode game`, `--game-replay` 및
  `--capture-case`를 요구한다.
- 첫 버전은 `--capture-target composite`만 지원한다.
- 출력 경로의 확장자는 `.mp4`여야 한다.
- `--game-video-output`은 `--game-record-dir`, `--game-capture-tick`,
  `--capture-output`, animation frame/range 옵션과 함께 사용할 수 없다.
- Viewer 모드, `--capture-view`, 비픽셀 capture mode 및 capture model
  옵션은 기존 Game 모드 규칙대로 오류다.
- 잘못된 조합은 GPU 창과 FFmpeg를 시작하기 전에 상태 2로 종료한다.
- 기존 `--game-record-dir`은 명시적으로 전체 PNG 시퀀스가 필요한
  디버깅 용도로 유지한다. 의미와 출력 이름은 바꾸지 않는다.

## 5. 프로세스 구조

Lab0가 셸 파이프나 named pipe를 요구하지 않고 FFmpeg를 직접 자식
프로세스로 실행한다.

```text
고정 60 Hz 리플레이 입력
          │
          ▼
game_fixed_update
          │
          ▼
정상 composite RenderTexture 렌더
          │
          ▼
GPU → CPU RGBA8 readback
          │
          ▼
익명 stdin 파이프 ──────► ffmpeg CLI ──────► 임시 MP4
                                                │
                                        성공 시 최종 이름으로 이동
```

FFmpeg는 Odin `core:os`의 프로세스와 익명 파이프 API로 실행한다. 셸을
거치지 않고 인수 배열을 전달하여 경로 공백과 셸 이스케이프 문제를
피한다. Lab0의 stdout/stderr는 기존 로그용으로 유지하며 raw 프레임은
FFmpeg 전용 stdin 파이프에만 기록한다.

파이프 쓰기는 동기식이다. FFmpeg가 소비 속도를 늦추면 backpressure로
Lab0 렌더 루프가 기다린다. 프레임을 버리거나 벽시계에 맞추려고
시뮬레이션 틱을 건너뛰지 않는다.

## 6. 프레임 계약

첫 버전의 스트림 포맷은 다음과 같이 고정한다.

| 속성 | 값 |
| --- | --- |
| 캡처 대상 | Game composite RenderTexture |
| 크기 | 1280×720 |
| 프레임률 | 60 fps |
| 입력 픽셀 포맷 | RGBA8, packed, row padding 없음 |
| 프레임 크기 | `1280 * 720 * 4 = 3,686,400` bytes |
| 프레임 순서 | 리플레이의 첫 fixed update 이후 프레임부터 1개씩 |
| 프레임 수 | `Game_Replay.total_ticks`와 정확히 동일 |
| 오디오 | 없음 |

Warmup 렌더는 리플레이 시작 전에 기존처럼 한 번 수행하지만 영상에
기록하지 않는다. 이후 각 리플레이 틱에 대해 다음 순서를 정확히 한 번
실행한다.

1. 다음 `Game_Input`을 읽는다.
2. `game_fixed_update`를 한 번 실행한다.
3. composite를 정상 GPU 파이프라인으로 렌더한다.
4. RenderTexture를 CPU 이미지로 읽는다.
5. 픽셀 포맷을 RGBA8로 보장한다.
6. 정확히 한 프레임 분량을 FFmpeg stdin에 모두 쓴다.

부분 쓰기는 남은 바이트를 계속 쓰는 루프로 처리한다. 0바이트 쓰기,
broken pipe 또는 한 프레임을 모두 전달하지 못한 상태는 캡처 실패다.
POSIX에서는 스트리밍 시작 전에 `SIGPIPE`를 무시하여 조기 종료한 FFmpeg가
Lab0 프로세스를 신호로 끝내지 않게 하고, 파이프 쓰기 오류를 상태 1로
처리한다.

raylib RenderTexture readback의 수직 방향은 기존 PNG 내보내기와 같아야
한다. CPU에서 `ImageFlipVertical`을 호출하지 않고 FFmpeg의 `vflip`
필터로 보정한다. contact sheet에서 UI 글자가 정상 방향인지 확인하여 이
계약을 검증한다.

매 프레임에 생성되는 raylib `Image`는 프레임 쓰기가 끝난 즉시
`UnloadImage`한다. 전체 리플레이 길이에 비례하는 프레임 메모리를
보유하지 않는다.

## 7. FFmpeg 호출 계약

실행 파일은 `PATH`에서 `ffmpeg`를 찾는다. 기본 인수는 다음과 같다.

```sh
ffmpeg \
  -hide_banner \
  -loglevel error \
  -f rawvideo \
  -pixel_format rgba \
  -video_size 1280x720 \
  -framerate 60 \
  -i pipe:0 \
  -vf vflip \
  -an \
  -c:v libx264 \
  -preset medium \
  -crf 18 \
  -pix_fmt yuv420p \
  -movflags +faststart \
  -y \
  <temporary-output.mp4>
```

`-pixel_format rgba`, `-video_size`와 `-framerate`는 header가 없는 rawvideo
입력의 해석에 필수다. `yuv420p`는 일반 플레이어 호환성을 위한 최종
픽셀 포맷이다.

FFmpeg는 최종 경로가 아니라 같은 디렉터리의 고유한
`<name>.partial-<run-id>.mp4`에 쓴다. 다음 조건을 모두 만족한 뒤에만
최종 `<name>.mp4`로 이동한다.

- 모든 리플레이 프레임을 파이프에 기록했다.
- stdin을 닫아 FFmpeg flush를 완료했다.
- FFmpeg가 상태 0으로 종료했다.
- 임시 파일이 존재하고 크기가 0보다 크다.

실패한 임시 파일은 PASS 산출물로 보고하지 않는다. 오류 조사에 필요한
경우 경로를 로그에 남기되 최종 MP4 이름으로 이동하지 않는다.

## 8. 오류와 종료 상태

| 상황 | 종료 상태 | 요구 동작 |
| --- | --- | --- |
| 잘못된 CLI 조합 또는 `.mp4`가 아닌 경로 | 2 | 렌더와 FFmpeg 시작 전 종료 |
| FFmpeg 실행 파일 없음 | 2 | 명확한 설치 오류 출력 |
| GPU 초기화, readback 또는 RGBA 변환 실패 | 1 | 파이프 종료 후 FFmpeg 회수 |
| broken pipe 또는 부분 프레임 쓰기 실패 | 1 | 즉시 렌더 중단, FFmpeg 회수 |
| FFmpeg 비정상 종료 | 1 | 최종 MP4 생성 금지 |
| 출력 파일 검증 또는 rename 실패 | 1 | 임시 경로와 원인 보고 |
| 전체 인코딩 성공 | 0 | 프레임 수와 최종 경로 출력 |

어떤 실패 경로에서도 FFmpeg 자식 프로세스를 고아로 남기지 않는다.
Lab0는 stdin 쓰기 끝을 닫고 자식 종료를 기다린다. 정상 종료를 기다릴 수
없는 오류에서는 프로세스를 종료한 뒤 회수한다.

## 9. `scripts/test-game.sh` 변경

`--video-report`의 외부 사용법은 유지한다.

```sh
scripts/test-game.sh --video-report artifacts/<new-report-directory>
```

내부 동작은 다음처럼 바뀐다.

1. `odin test .`을 실행한다.
2. 새 고유 경로에 바이너리를 빌드한다.
3. 같은 고정 틱 PNG를 두 번 캡처하고 byte-identical을 요구한다.
4. 바이너리를 `--game-video-output "$video_path"`로 한 번 실행한다.
5. `ffprobe`로 MP4 메타데이터를 검증한다.
6. 완성된 MP4에서 contact sheet를 만든다.
7. 보고서와 로그를 기록한다.

비디오 리포트 디렉터리는 더 이상 `frames/` 디렉터리를 만들지 않는다.
보고서에는 다음 항목을 포함한다.

- 스트리밍 인코딩 사용 여부
- 리플레이 경로와 예상 틱 수
- `ffprobe`가 보고한 실제 프레임 수
- 해상도, 프레임률과 재생 시간
- MP4 SHA-256
- 고정 틱 PNG 결정성 결과
- asset image warning 유무

기대 재생 시간은 `total_ticks / 60`초다. `ffprobe`의 실제 프레임 수는
`total_ticks`와 정확히 같아야 하고, 해상도는 1280×720, 프레임률은
60/1이어야 한다. duration은 프레임 수와 프레임률에서 계산한 값과
한 프레임 이내로 일치해야 한다.

## 10. 테스트 요구사항

### 단위 테스트

- 새 CLI 옵션 파싱과 누락된 값
- 유효한 replay/composite 조합
- 금지된 옵션 조합 전부
- FFmpeg 인수 배열 생성 결과
- 예상 프레임 바이트 수 계산
- 부분 쓰기를 끝까지 완료하는 writer
- broken pipe를 실패로 변환하는 writer
- 임시 출력 이름 생성과 성공 시 rename 규칙

### 통합 테스트

1. `odin test .`이 성공해야 한다.
2. 새 바이너리를 빌드해야 한다.
3. 기본 180틱 리플레이로 실제 hidden-window 비디오 리포트를 실행한다.
4. MP4가 H.264, 1280×720, 60 fps, 정확히 180프레임이어야 한다.
5. MP4 재생 시간이 3초여야 한다.
6. report 디렉터리에 전체 프레임 PNG나 `frames/` 디렉터리가 없어야 한다.
7. 고정 틱 PNG 2장은 byte-identical이어야 한다.
8. asset image warning이 없어야 한다.
9. contact sheet를 열어 방향, 색상, UI와 움직임을 확인한다.
10. 리플레이를 다시 실행했을 때 게임의 고정 틱 PNG 해시는 같아야 한다.

긴 리플레이 검증에서는 전체 틱 수와 MP4 프레임 수가 같고, 프로세스
메모리가 리플레이 길이에 비례해 증가하지 않으며, 중간 PNG가 생성되지
않는지 확인한다.

### 실패 테스트

- `ffmpeg`가 없는 PATH에서 상태 2와 설치 안내를 확인한다.
- 프레임을 받다가 종료하는 가짜 encoder로 broken pipe와 상태 1을
  확인한다.
- 쓰기 불가능한 출력 디렉터리에서 최종 MP4가 생기지 않는지 확인한다.
- FFmpeg가 비정상 종료할 때 임시 파일을 PASS로 보고하지 않는지
  확인한다.

## 11. 완료 조건

다음 조건을 모두 만족하면 구현이 완료된 것으로 본다.

- 기존 PNG 단일/시퀀스 캡처와 Game 고정 틱 캡처 동작이 유지된다.
- `scripts/test-game.sh`의 비디오 리포트가 PNG 시퀀스를 만들지 않는다.
- 모든 리플레이 틱이 정확히 하나의 MP4 프레임으로 인코딩된다.
- MP4는 기존 리포트와 같은 1280×720, 60 fps, H.264/yuv420p 형식이다.
- 동일 틱 PNG 결정성 검증과 asset warning 검사가 그대로 통과한다.
- FFmpeg 및 GPU 오류가 성공으로 오인되지 않는다.
- 성공·실패 모든 경로에서 자식 프로세스와 raylib Image가 정리된다.
- README와 AGENTS.md가 새로운 스트리밍 방식과 PNG의 제한된 역할을
  정확히 설명한다.
