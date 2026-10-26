# Mr. Tab-D (미스터 탭디)

Mac의 확장 화면을 Android 태블릿에 표시하는 앱입니다. USB와 같은 네트워크의 무선 연결을 지원하며, Mac은 메뉴 막대에서, 태블릿은 전체 화면과 숨김 제어 바에서 조작합니다.

현재 버전은 **Android 0.6.3 / Mac 0.6.2**이며 앱 표시 이름은 Mr. Tab-D입니다. 내부 식별자·설정 저장 위치·통신 방식은 유지합니다. MacBook Pro M4와 Android 16 태블릿에서 개발했습니다. 개인용 개발 빌드이며 앱스토어 배포판이나 공증된 설치 프로그램은 제공하지 않습니다.

## 주요 기능

- 기본 1920×1200 확장 화면과 선택 가능한 3504×2190 모드
- USB·무선에서 같은 영상 및 터치 조작
- 한 번 탭: 왼쪽 클릭 / 빠른 두 번 탭: 더블클릭
- 한 손가락 이동: 드래그 / 약 0.5초 길게 누르기: 오른쪽 클릭
- 두 손가락 위아래 이동: 세로 스크롤
- 태블릿 홈·다른 앱으로 이동하는 동안 가상 화면과 창 배치 유지
- Mac 화면 꺼짐·잠금 후 연결과 영상 복구
- 연결된 상대 기기의 시스템 장치명 표시
- Android 화면 꺼짐 방지는 실제 모니터 화면 표시 중에만 적용. 연결 대기·종료·오류·일시 정지에서는 해제

## 릴리즈 파일로 설치

[Releases](../../releases/latest)에서 Mac용 DMG와 Android용 APK를 받을 수 있습니다.

1. Mac에서 DMG를 열고 **Mr. Tab-D.app을 Applications 폴더로 드래그**한 뒤 실행합니다. 기존 앱이 실행 중이면 먼저 종료합니다.
2. 태블릿에 APK를 내려받아 설치합니다. Android가 요청하면 해당 다운로드 앱의 **알 수 없는 앱 설치**를 허용합니다. 또는 Mac의 Android Platform Tools로 `adb -d install -r Mr-Tab-D-0.6.3-Android.apk`를 실행합니다.
3. 태블릿의 USB 디버깅을 켜고 Mac과 연결한 뒤 컴퓨터 허용 창을 승인합니다. Mac 앱이 USB 페어링을 준비합니다.
4. 아래의 macOS 권한을 허용하고 **화면 연결**을 누릅니다.

DMG는 **Apple Silicon 전용**, 자체 개발 서명·미공증 빌드입니다. macOS가 차단하면 시스템 설정의 개인정보 보호 및 보안에서 직접 확인하여 실행을 허용해야 합니다. USB 연결과 최초 무선 페어링에는 **Android Platform Tools의 adb**가 필요하며 기본 검색 위치는 `$HOME/Library/Android/sdk/platform-tools/adb`입니다. APK도 개인용 debug 서명 빌드입니다. 이전 설치본과 서명이 다르면 Android가 업데이트를 거부할 수 있습니다.

릴리즈 앱은 설정·인증 자료를 사용자별 `~/Library/Application Support/Tab-D/`에 저장합니다. 개발 빌드의 페어링과 별개이므로 처음에는 USB로 다시 페어링합니다. 첨부한 `SHA256SUMS.txt`로 다운로드 파일의 체크섬을 대조할 수 있습니다.

아래는 소스에서 직접 빌드하는 방법입니다.

## 설치 준비

소스에서 Mac 앱과 Android APK를 직접 빌드합니다.

| 항목 | 필요 환경 |
| --- | --- |
| Mac | Apple Silicon, macOS 14 이상을 대상으로 빌드. Xcode Command Line Tools 필요 |
| Android | Android 11(API 30) 이상을 대상으로 빌드. 실제 확인 기기는 Android 16 |
| 공통 도구 | Python 3, macOS 기본 OpenSSL·보안 도구 |
| Android 빌드 | JDK 17, Gradle 8.13, Android SDK Platform 36, Build Tools 35.0.0, Platform Tools |

지원 최소 버전은 빌드 설정 기준이며 모든 OS·기기의 호환성을 검증했다는 뜻은 아닙니다. Android Studio의 SDK Manager에서 위 SDK 항목을 설치할 수 있습니다. SDK 기본 위치는 `$HOME/Library/Android/sdk`입니다.

1. 이 저장소를 내려받고 터미널에서 저장소 폴더로 이동합니다.
2. Xcode 도구가 없다면 `xcode-select --install`로 설치합니다.
3. JDK 17과 Gradle 8.13을 설치하고, 필요하면 도구 위치를 지정합니다.

```sh
export TABD_JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export ANDROID_HOME="$HOME/Library/Android/sdk"
# Gradle이 PATH 또는 기존 8.13 캐시에 없다면 실제 설치 위치를 지정합니다.
# export TABD_GRADLE="/path/to/gradle-8.13/bin/gradle"
```

Mac 앱의 USB 기능은 기본 SDK 위치의 `platform-tools/adb`를 사용합니다. 다른 위치에 SDK를 설치했다면 앱을 실행하는 프로세스에도 `TABD_ADB` 환경 변수를 지정해야 합니다.

## 빌드·설치

### 1. 앱 빌드

```sh
bash scripts/build-mac.sh
TABD_ONLINE=1 bash scripts/build-android.sh
```

처음 Android 빌드에서는 의존성을 받기 위해 온라인 옵션이 필요합니다. 이후 캐시가 준비되면 `bash scripts/build-android.sh`로 오프라인 빌드할 수 있습니다.

결과물은 다음 위치에 생성됩니다.

- Mac: `build/Tab-D.app`
- Android: `android/app/build/outputs/apk/debug/app-debug.apk`

Mac 빌드 과정은 `build/private/signing/`에 이 컴퓨터용 개발 서명을 생성하고 재사용합니다. 서명 시 사용자 Keychain 검색 목록에 개발 Keychain을 잠시 추가한 후 복원합니다. 재빌드 시 macOS 권한을 유지하려면 이 폴더를 보관하세요. 인증서·개인 키·암호를 다른 사람과 공유하거나 저장소에 올리지 마세요.

### 2. Mac 설치

기존 Tab-D가 실행 중이면 메뉴에서 종료한 뒤 설치합니다.

```sh
ditto build/Tab-D.app "/Applications/Mr. Tab-D.app"
open "/Applications/Mr. Tab-D.app"
```

공증되지 않은 개발 빌드이므로 macOS가 실행을 차단하면 **시스템 설정 → 개인정보 보호 및 보안**에서 직접 확인하여 실행을 허용합니다.

### 3. 태블릿 설치와 최초 페어링

1. 태블릿의 개발자 옵션에서 **USB 디버깅**을 켭니다.
2. 데이터 전송 가능한 USB 케이블로 Mac과 연결하고, 태블릿의 컴퓨터 허용 창을 승인합니다. 여러 Android 기기가 연결되어 있다면 사용할 태블릿 하나만 남깁니다.
3. Mac의 Tab-D를 실행한 상태에서 설치·페어링합니다.

```sh
python3 scripts/device.py install
python3 scripts/device.py pair
python3 scripts/device.py launch
```

Mac 앱은 이후 USB 준비와 페어링을 주기적으로 확인합니다. 무선도 최초 페어링은 USB로 진행합니다. APK는 `run-as`를 사용하는 개인용 debug 빌드입니다.

### 4. macOS 권한 허용

**시스템 설정 → 개인정보 보호 및 보안**에서 다음을 허용합니다.

- **화면 및 시스템 오디오 기록**: 확장 화면 영상 전송에 필요합니다. 오디오 전송 기능은 없습니다.
- **손쉬운 사용**: 태블릿의 터치를 Mac 클릭·드래그·스크롤로 전달할 때 필요합니다.

승인 후 macOS가 앱 재실행을 요청하면 따릅니다. 권한 승인은 사용자가 직접 해야 합니다.

## 사용법

### USB 연결

Mac과 태블릿에서 Tab-D를 열고 한쪽에서 **화면 연결**을 누릅니다. 기본 해상도는 1920×1200입니다. USB 디버깅과 컴퓨터 허용이 유지되어 있어야 합니다.

### 무선 연결

1. 두 기기를 같은 네트워크에 연결하고 최초 USB 페어링을 완료합니다.
2. Mac 메뉴의 **화면 설정 → 무선 연결 허용**을 켭니다.
3. 태블릿 **설정**에 Mac의 IPv4 주소를 입력하고 적용합니다.
4. **화면 연결**을 누릅니다. 방화벽이 묻는 경우 로컬 네트워크 연결을 허용합니다.

USB로 돌아갈 때는 태블릿 설정의 Mac 주소를 비웁니다. 주소·연결 경로·해상도 변경은 화면 연결을 종료한 뒤 진행합니다. 자동 검색과 사용 중 경로 자동 전환은 지원하지 않습니다.

### 제어 바와 화면 유지

- **뒤로가기 제스처 또는 Back**으로 제어 바를 표시하거나 숨깁니다. 열린 바 바깥을 탭하면 바만 닫습니다.
- **태블릿으로 돌아가기**를 누르면 영상 전송을 일시 정지하고 Android 화면으로 돌아갑니다. 홈·다른 앱으로 이동해도 가상 화면과 Mac 창 배치를 유지합니다.
- Tab-D로 돌아오면 같은 가상 화면에서 영상을 재개합니다.
- 제어 바 **맨 오른쪽의 연결 종료**, 또는 Mac 메뉴의 **연결 종료**는 가상 화면을 제거합니다. 화면 유지와 달리 창이 다른 모니터로 이동할 수 있습니다.
- Mac 메뉴의 **Tab-D 종료**는 앱과 가상 화면을 함께 종료합니다.

Mac이 잠기거나 화면이 꺼졌다면 평소 방식으로 깨우고 잠금을 해제합니다. 이전에 화면을 사용 중이었다면 연결과 영상을 복구합니다. 태블릿에서 다른 앱을 쓰고 있었다면 Tab-D로 돌아온 뒤 재개합니다. 복구에 실패하면 안내에 따라 다시 연결합니다.

## 연결 문제 확인

- USB가 연결되지 않으면 케이블의 데이터 전송 지원, USB 디버깅, 태블릿의 컴퓨터 허용 상태를 확인합니다.
- 무선이 연결되지 않으면 같은 네트워크인지, Mac 주소가 바뀌지 않았는지, 무선 허용과 방화벽 설정을 확인합니다.
- 영상은 나오지만 터치가 작동하지 않으면 Mac의 손쉬운 사용 권한을 확인합니다.
- Mac 앱을 종료하면 가상 화면을 유지할 수 없습니다. Mac 빌드 폴더를 이동·삭제하면 개발용 상태 저장 경로에 영향을 줄 수 있으므로 소스 폴더를 유지하세요.

## 개발 및 제한

Mac은 SwiftUI·AppKit, ScreenCaptureKit, VideoToolbox를 사용하고, Android는 Kotlin·SurfaceView·MediaCodec을 사용합니다. USB는 ADB reverse, 무선은 LAN을 거치며 두 경로 모두 인증서 pin과 페어링 토큰으로 인증한 TLS 통신을 사용합니다. 자세한 메시지 형식은 [프로토콜 문서](protocol/PROTOCOL.md)를 참고하세요.

가상 화면 생성에는 macOS 비공개 API를 사용하므로 OS 업데이트에 따른 호환성을 보장하지 않습니다. 기본 모드와 원본 모드는 non-HiDPI이며, HDR·오디오·가로/관성 스크롤·120/144Hz는 제공하지 않습니다. 60Hz 설정이 실제 60fps나 특정 지연을 보장하지는 않습니다.

0.6.0에서 USB·무선 영상과 입력 회귀, 화면 유지·복귀, 짧은 USB 화면 절전 후 복구를 확인했습니다. 장시간 화면 꺼짐·전체 시스템 절전·무선 절전 복귀는 검증하지 않았습니다. 0.6.1의 장치명·메뉴 변경은 빌드·설치까지만 확인했습니다.

선택적으로 아래 코드 검사를 실행할 수 있습니다. 실제 기기 검사 스크립트는 화면·앱·입력을 조작하므로 평소 사용 중에는 실행하지 마세요.

```sh
bash scripts/test-core.sh --hardware
bash scripts/build-android.sh :app:protocolCheck :app:lintDebug
```

## 릴리즈 패키지 생성

양쪽 빌드를 완료한 후 `bash scripts/package-release.sh`를 실행하면 `build/releases/` 아래에 DMG·APK·체크섬을 생성합니다. DMG는 앱·Applications 바로가기·설치 안내를 패키징하며, 개발 환경의 상태 경로를 제거하고 다시 서명합니다. 서명 키·페어링 정보는 포함하지 않습니다.
