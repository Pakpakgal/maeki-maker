# 매일의 기도 편집 검토 · Maeki Maker

원본 기도 영상에서 기도 구간을 판별하고, 자막·삭제 후보와 배경을 검토한 뒤 Palmier Pro에 편집 타임라인을 만드는 Apple Silicon macOS 앱입니다.

[최신 DMG 다운로드](https://github.com/Pakpakgal/maeki-maker/releases/latest)
[설치 및 권한 안내](설치%20및%20권한%20안내.txt)

## 시작하기

1. DMG를 열어 앱을 Applications 폴더로 옮깁니다. 첫 릴리스는 ad-hoc 서명으로 배포되므로 macOS에서 실행을 차단한 경우 시스템 설정의 **개인정보 보호 및 보안**에서 앱 열기를 확인합니다.
2. Apple Silicon Mac과 macOS 26 이상, Python 3.10 이상, FFmpeg, Palmier Pro가 필요합니다. 원본 전사는 MLX Whisper, AI 편집 검토는 켜져 있는 Ollama를 사용합니다.
3. **공통 에셋**에서 사용하는 자막 레이아웃 이미지, 로고 이미지, 기본 배경음악을 각각 지정합니다. 미리보기와 최종 합성에서 사용할 김정철명조와 Gmarket Sans 폰트는 로컬에 설치합니다.
4. **새 영상…**에서 원본을 열어 자동 준비를 진행합니다. 자막, 배경 크롭, 날짜와 삭제 후보를 검토한 다음 **Palmier로 보내기**를 눌러 편집 프로젝트를 생성합니다.

기존 작업 폴더의 설정과 검토 작업을 불러올 수 있습니다. 신규 설치의 앱 설정과 검토 작업은 `~/Library/Application Support/MaekiMaker`에 저장됩니다.

자동 준비와 AI 분석이 진행되는 동안 완료된 처리 단계와 시간별 로그가 표시됩니다. 로그 영역을 스크롤하면 이전 단계도 볼 수 있습니다. 설치 및 권한 안내 TXT는 DMG와 앱 메뉴에서 열 수 있습니다.

### 로컬 AI

- MLX Whisper에서 `mlx-community/whisper-large-v3-turbo`를 미리 내려받습니다.
- Ollama에서 `ollama pull gemma4:12b`로 모델을 설치합니다.
- 음성과 전사 데이터는 로컬에서 처리됩니다. 앱은 업데이트 확인을 위해 공개 GitHub Releases에 접속합니다.

## 업데이트와 버전 관리

앱을 실행하면 GitHub의 최신 공개 릴리스를 확인합니다. 새 버전이 있으면 앱 안에서 알리고 설치 DMG를 연결합니다. 앱 메뉴의 **업데이트 확인…**으로 직접 확인할 수도 있습니다.

개발 환경에서 `./ReviewApp/build.sh`로 앱을, `./scripts/release.sh`로 버전이 들어간 DMG를 만듭니다. `VERSION`은 앱 표시 버전·빌드 정보와 DMG 파일 이름에 적용됩니다. `VERSION`과 `CHANGELOG.md`를 갱신한 커밋에 같은 번호의 `vX.Y.Z` 태그를 푸시하면 GitHub Actions가 DMG를 빌드해 Releases에 게시합니다.

배포 저장소에는 앱과 자동편집 소스가 포함됩니다. 영상, 음원, 배경 이미지, 교회 로고, 자막 원문이 담긴 검토본과 개인 작업 경로는 로컬에 보관합니다.
