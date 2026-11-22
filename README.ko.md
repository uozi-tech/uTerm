# uTerm

[简体中文](README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **한국어**

macOS와 iOS / iPadOS를 위한 서버 작업 도구입니다. SSH 터미널, SFTP 파일 탐색 및 편집, 포트 포워딩, 키 관리, 빠른 명령과 여러 호스트 병렬 실행,
AI 도우미를 제공하며, 휴대폰이나 다른 Mac에서 로컬 네트워크 또는 자체 구축 릴레이를 거쳐 이 Mac의 터미널과 화면을 원격 제어할 수도 있습니다. 터미널 엔진은 [Ghostty](https://ghostty.org)이며,
[libghostty-spm](https://github.com/Lakr233/libghostty-spm)을 통해 Swift 패키지로 연결합니다(패치를 적용한 fork는 `vendor/libghostty-spm`에 있습니다).

## 플랫폼

- macOS 26 이상(Apple 실리콘)
- iOS / iPadOS 18 이상
- 인터페이스 언어: 简体中文, English, 繁體中文, 日本語, 한국어(시스템 설정을 따르며, Mac에서는 ‘설정 › 모양 › 언어’에서 따로 지정할 수 있습니다)

## 소스에서 빌드하기

Xcode 27(또는 이후 버전), Go(호스트에서 세션을 유지하는 프로세스 `holder/` 빌드용), 네트워크 연결이 필요합니다.

```sh
git clone https://github.com/uozi-tech/uTerm.git && cd uTerm
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 자신의 Team ID와 bundle id 접두사를 입력
make engine     # 터미널 엔진: 처음에는 업스트림 소스에서 빌드(약 15분, Zig와 Ghostty 소스를 내려받음)
make build      # 또는 open uTerm.xcodeproj
```

- **서명**: 자신의 팀으로 서명하려면 `Config/Local.xcconfig`에 Team ID를 입력하고 `UTERM_BUNDLE_ID`를 자신의 접두사로 바꾸세요
  (App ID는 Apple 전체에서 고유하므로 `com.uozi.uTerm`은 저희 팀만 사용할 수 있습니다). 각 target의 bundle id, iCloud 컨테이너, 키체인 접근 그룹,
  원격 제어 프로세스의 launchd 작업 이름은 모두 이 접두사에서 파생됩니다. 원격 제어 프로세스, 로컬 터미널 보조 프로세스, holder는 ‘같은 팀 서명’ 여부로 서로를 확인하며,
  팀 번호와 신원은 런타임에 읽으므로 소스 코드를 고칠 필요가 없습니다. 처음 빌드할 때는 Xcode로 프로젝트를 열고 Signing & Capabilities에서 App ID와
  iCloud 컨테이너를 등록하게 하거나, 명령줄에 `-allowProvisioningUpdates`를 추가하세요.
- **엔진**: `vendor/libghostty-spm`은 패치를 적용한 libghostty-spm입니다(패치 내용은 해당 디렉터리의 `UTERM-PATCHES.md` 참고). 두 xcframework는 버전 관리에 포함되지 않으며,
  `make engine`이 `ENGINE.lock`에 따라 가져오거나 직접 빌드합니다.
- **앱 내 업데이트와 릴레이 원클릭 배포**: 소스 빌드에는 기본적으로 포함되지 않습니다(진입점이 자동으로 숨겨집니다). 필요하면 `Config/Local.xcconfig`에 자신의 업데이트 소스와 릴레이
  배포 주소를 설정하세요. `Config/Local.xcconfig.example`을 참고하세요.
- **수정한 버전 배포**: 앱 이름(`INFOPLIST_KEY_CFBundleDisplayName`)과 아이콘(`AppIcon`)을 바꿔야 하며, uTerm이라는 이름으로 배포할 수 없습니다.
  [`TRADEMARK.md`](TRADEMARK.md)(중국어 문서)를 참고하세요. 직접 빌드해 혼자 쓰는 경우에는 바꿀 필요가 없습니다.
- **iCloud 동기화**: 컨테이너는 `iCloud.<bundle id 접두사>`이며 정식 버전과는 동기화되지 않습니다. `Local.xcconfig.example`에서 환경을 Development로 설정하세요.
  새 컨테이너의 Production에는 아직 schema가 없어서 동기화가 아무 오류 없이 실패합니다.

## 테스트

```sh
make test-fast           # macOS: 병렬로 전체 실행, 실패한 항목은 직렬로 재확인
make test-mobile-fast    # iOS 시뮬레이터
make test-holder         # 호스트 세션 유지 프로세스(Go)
cd relay && GOWORK=off go test -race ./...   # 자체 구축 릴레이
```

## 디렉터리

| 경로 | 내용 |
|---|---|
| `uTerm/` | 양쪽 플랫폼이 공유하는 코드와 macOS 앱(iOS에서 빌드하지 않는 파일은 pbxproj의 membership exceptions에 있음) |
| `uTermMobile/` | iOS / iPadOS의 뷰와 플랫폼 브리지 |
| `uTermRemoteHost/`, `uTermShellAgent/`, `uTermHolder/`, `uTermSSH/` | macOS 보조 프로세스: 원격 제어, 로컬 터미널, 세션 유지, SSH 브리지 |
| `holder/` | 호스트의 세션 유지 프로세스(Go, 연결이 끊긴 뒤 다시 연결해 셸에 이어 붙음) |
| `relay/` | 자체 구축 릴레이(Go, TCP 릴레이 + STUN). 프로토콜은 `relay/PROTOCOL.md`, 배포는 `relay/README.md` 참고 |
| `skills/`, `scripts/utermctl` | AI 도구용 명령줄과 스킬 |
| `vendor/` | 패치를 적용한 서드파티 소스. 각자의 `UTERM-PATCHES.md`에 변경 사항이 기록되어 있음 |
| `docs/` | 설계 문서와 조사 기록 |

프로젝트 규칙(공유 코드 배치, 터미널 엔진, 원격 제어 프로세스, holder, CloudKit schema, 버전 번호 등)은 [`CLAUDE.md`](CLAUDE.md)(중국어)에 정리되어 있습니다.
사람이 읽는 문서이자 AI 코딩 도구가 읽는 문서이기도 합니다. 공유 Swift 패키지는 [uAppKit](https://github.com/uozi-tech/uAppKit)에 있습니다.

## 기여하기

[`CONTRIBUTING.md`](CONTRIBUTING.md)(중국어)를 참고하세요. PR이 병합되기 전에 모든 기여자는 [CLA](CLA.md)에 한 번 서명해야 합니다(PR에서 자동으로 확인됩니다).
보안 문제는 [`SECURITY.md`](SECURITY.md)에 따라 비공개로 제보해 주세요.
개인정보 처리방침은 [`PRIVACY.md`](PRIVACY.md)를 참고하세요. 계정이 없고 통계 데이터를 수집하지 않으며, 데이터는 사용자 자신의 기기와 iCloud에 있습니다.

## 라이선스

[AGPL-3.0](LICENSE). 서드파티 구성 요소별 라이선스는 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)를 참고하세요.

라이선스는 코드에만 적용되며 ‘uTerm’ 이름과 아이콘은 포함되지 않습니다. 수정한 버전을 배포하려면 이름과 아이콘을 바꿔야 합니다. [`TRADEMARK.md`](TRADEMARK.md)를 참고하세요.
