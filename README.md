# Allspot — 맥용 "Everything" 방식 파일 이름 검색기

Windows용 [Everything](https://www.voidtools.com)(voidtools)을 맥에서 쓰듯이 만든 앱이에요.
디스크 전체의 파일·폴더 이름을 메모리에 색인해 두고, 글자를 칠 때마다 즉시 걸러 보여 줘요.
Everything은 공식 맥 버전이 없어요. 이 앱은 Everything의 코드를 쓰지 않고 같은 원리로 새로 만들었어요.

## Everything과 대응하는 부분

| Everything (Windows) | Allspot (macOS) |
| --- | --- |
| NTFS MFT를 직접 읽어 수초 만에 색인 | `getattrlistbulk`로 여러 스레드가 디렉터리를 한꺼번에 읽음 |
| USN 저널로 변경 실시간 반영 | FSEvents로 바뀐 폴더만 다시 읽어 반영 |
| 다음 실행 때 저널을 이어 읽음 | 색인 저장본 + 저장 시점 FSEvents 번호부터 놓친 변경을 다시 받음 |
| 검색 문법 (공백·`|`·`!`·와일드카드·`ext:`·`size:`·`dm:`·`regex:`) | 같은 문법 지원 |
| 전역 단축키 | ⌥Space (설정에서 바꿀 수 있음) |

## 받아서 쓰기

완성된 앱 파일을 나눠 주지 않고, 각자 자기 맥에서 소스로 빌드해요.
자기 맥에서 만든 앱은 인터넷에서 받은 파일로 취급되지 않아서, Apple 개발자 서명 없이도 Gatekeeper에 막히지 않아요.

**필요한 것**

- macOS 14 이상 (macOS 27에서 만들고 확인했어요)
- Xcode 명령줄 도구(Swift 6). Xcode 앱 전체는 필요 없어요. 없으면 터미널에서 설치해요.

```bash
xcode-select --install
```

**설치**

```bash
git clone https://github.com/techkwon/allspot.git
cd allspot
./scripts/install.sh
```

`install.sh`는 빌드한 뒤 `/Applications/Allspot.app`에 넣고 실행해요.
Claude Code(`claude` 명령)가 있으면 MCP 서버도 그 위치로 등록해요.

- `./scripts/install.sh ~/Applications`: 다른 곳에 설치
- `./scripts/install.sh --no-mcp`: MCP 등록은 건드리지 않음

**처음 실행**

- 처음 실행할 때만 디스크 전체를 훑어요(약 400만 개 기준 35~45초).
- 그다음부터는 저장본을 불러오고(약 0.2초), 꺼져 있던 동안 바뀐 폴더만 다시 읽어요.
- 문서 내용 색인은 이름 색인이 끝난 뒤 뒤에서 이어서 만들어요(문서 7천여 개 기준 30초~수 분).
- 메일·사진 보관함처럼 보호된 폴더까지 넣으려면 **시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한**에 Allspot을 추가하고 다시 실행하세요.
- ⌥Space로 어디서든 검색 창을 불러와요(설정에서 바꿀 수 있어요).

**업데이트**

```bash
cd allspot
git pull
./scripts/install.sh
```

**지우기**

```bash
./scripts/uninstall.sh
```

앱, 색인 저장본(`~/Library/Application Support/Allspot`), 설정, Claude Code MCP 등록을 지워요. 원래 파일은 건드리지 않아요.

**개인정보**

- Allspot은 인터넷으로 아무것도 보내지 않아요. 색인과 설정은 모두 이 맥 안에만 있어요.
- 문서 내용 색인은 `~/Library/Application Support/Allspot/content.v1.bin`에 문서 글자를 그대로 담아요. 이 맥을 같이 쓰는 사람이 있으면 설정에서 '문서 내용 색인'을 끌 수 있어요.
- AI 도구(MCP)를 등록하면, 그 AI가 이 맥의 파일 이름과 문서 내용을 볼 수 있게 돼요. 무엇을 숨기는지는 아래 'AI와 함께 쓰기'를 보세요.

## 개발

```bash
./scripts/build-app.sh                 # build/Allspot.app 만들기
open build/Allspot.app --args -s "보고서 *.hwp"   # 검색어를 넘겨 실행
swift build -c release --product allspot-cli
.build/release/allspot-cli docs        # 문서 읽기·AI 접근 규칙·내용 색인 저장본 확인
```

`build-app.sh`는 새 앱을 옆에서 다 만든 뒤 한 번에 바꿔 끼워서, 빌드하는 동안에도 돌고 있는 앱과 MCP 서버가 도우미를 잃지 않아요.
색인 설정(⌘,의 '뺄 폴더')을 바꾸거나 '색인 다시 만들기'를 누를 때만 다시 전체를 훑어요.

## 검색 문법

| 입력 | 뜻 |
| --- | --- |
| `보고서 2026` | 두 낱말이 모두 이름에 든 항목 (공백 = 그리고) |
| `jpg\|png` | 둘 중 하나 (또는) |
| `!tmp` | tmp가 들어간 항목 빼기 |
| `"여름 방학"` | 공백이 든 구절 그대로 |
| `*.pdf`, `IMG_????.jpg` | 와일드카드 (이름 전체와 비교) |
| `Downloads/ 계획`, `path:문서/2026` | `/`가 있으면 전체 경로와 비교 |
| `ext:hwp;hwpx` | 확장자 |
| `file:` / `folder:` | 파일만 / 폴더만 |
| `size:>100mb`, `size:1mb..1gb`, `size:empty` | 크기 |
| `dm:today`, `dm:yesterday`, `dm:thisweek`, `dm:7d`, `dm:>2026-01-01` | 수정한 날짜 |
| `regex:^IMG_\d+` | 정규식 (느린 편: 400만 개에 약 2초) |
| `ㅂㄱㅅ`, `보ㄱㅅ` | 초성 검색 (자음만, 또는 음절과 섞어서) |
| `~repotr`, `fuzzy:수업게획서` | 이 낱말만 유사 검색 (오타·빠진 글자 허용) |
| `kind:image`, `kind:사진`, `kind:doc` | 종류 (image·video·audio·doc·archive·code·folder) |
| `content:예산`, `내용:"수업 나눔"` | 파일 내용 (아래 '내용·메타데이터 검색') |
| `tag:빨강`, `author:홍길동`, `taken:2026-05` | Finder 태그, 작성자, 사진·영상 촬영일 |
| `spotlight:kMDItemPixelHeight>4000` | Spotlight 질의를 그대로 |

대소문자를 가리지 않고, 맥 파일 이름의 한글 자모 분리(NFD)도 자동으로 맞춰 찾아요.

## 유사 검색

검색창 오른쪽 **유사** 버튼(⌘U)을 켜면 검색어 전체를 유사 검색으로 찾아요. 켜 둔 상태는 다음 실행에도 남아요.

- 오타: 글자 1~2개가 바뀌거나 빠지거나 더해져도 찾아요 (`repotr` → report, `보고소` → 보고서)
- 건너뛰기: 글자가 순서대로만 있으면 찾아요 (`rptpdf` → report.pdf)
- 초성: `ㅂㄱㅅ` → 보고서 (유사 검색을 끄고도 돼요)
- 이름순 정렬일 때는 비슷한 순서로 늘어놓아요: 그대로 든 것 → 초성 → 오타 → 건너뛰기, 같으면 이름이 짧은 것 먼저

## 내용·메타데이터 검색

`content:`(또는 `내용:`)로 파일 안의 글자를 찾아요. 이름 조건과 섞어 쓸 수 있어요: `content:학생 ext:hwpx dm:thisyear`

- **자체 내용 색인 (hwp·hwpx·pdf·docx·pptx·xlsx·txt·md)**: Allspot이 직접 읽어 둬요. Spotlight 결과도 함께 보여 줘요.
  - 한글 문서는 Spotlight이 읽지 못해서 이 색인으로만 찾을 수 있어요.
    - hwp 5.x, hwpx, 배포용 문서를 읽어요.
    - 아주 옛 형식인 hwp 3.x도 읽어요.
    - 암호 걸린 문서는 미리보기 글자만 찾아요.
  - 글자 층이 거의 없는 스캔본 PDF는 macOS Vision으로 글자를 인식해요(한국어·영어, 앞 20쪽까지).
  - 넣는 범위:
    - 사용자 폴더(`/Users`) 아래만 넣어요.
    - `~/Library` 안에서는 iCloud Drive·Google Drive(CloudStorage)와 앱이 받은 문서(Containers)만 넣어요.
    - 숨김 폴더와 앱 묶음(.app) 안은 빼요.
    - txt·md는 1MB 이하이면서 개발 폴더(`~/Developer`, `node_modules`, `build` 등) 밖의 것만 넣어요.
  - 개발한 맥에서는 로컬 문서 7,610개(본문 약 104MB)를 처음에 약 33초에 읽었어요. 그 뒤로는 바뀐 문서만 다시 읽어요.
  - 저장본은 `~/Library/Application Support/Allspot/content.v1.bin`이에요.
    - 문서 수가 절반 아래로 줄어드는 저장(클라우드 드라이브가 끊겼을 때 등)이면 이전 저장본을 `content.v1.bin.bak`으로 남겨요.
    - 이름 색인처럼 파일을 그대로 비춰(mmap) 써서 본문이 커져도 앱 메모리는 거의 늘지 않아요(다 읽은 뒤 181MB).
  - 문서는 앱 안의 도우미(`Helpers/allspot index-worker`)가 16개씩 맡아 읽고 끝나요.
    - 큰 PDF 하나를 읽는 데 수백 MB가 드는데, 그 메모리는 도우미가 끝날 때 바로 돌아가요.
    - 망가진 문서 때문에 도우미가 죽거나 2분 넘게 멈추면 그 문서만 건너뛰어요.
- **클라우드에만 있는 파일**: Google Drive·iCloud에만 있는 문서는 기본으로 건너뛰어요(읽으면 내려받게 돼요).
  - 설정(⌘,)의 '클라우드에만 있는 문서도 내려받아 읽기'를 켜면 내려받아 읽어요.
- **메타데이터**: `tag:`(Finder 태그), `author:`(작성자, 한글 문서는 Allspot이 직접 읽음), `taken:`(사진·영상 촬영일)은 Spotlight 정보를 써요.
  - `taken:`은 `dm:`과 같은 날짜 문법을 써요. `2026-05`는 5월 한 달, `2026`은 한 해 전체예요.
- **속도**:
  - 자체 내용 색인 결과를 먼저 바로 보여 주고, Spotlight 결과는 답이 오는 대로 더해요.
  - Spotlight 몫까지 다 오는 데는 Spotlight가 답하는 시간만큼 걸려요. 결과가 1만 개 넘으면 1~2초예요.
  - 같은 조건에 다른 조건을 덧붙이는 검색은 20ms 안팎이에요. Spotlight 답을 30초 동안 기억해 두기 때문이에요.

## 결과 내 검색

한 번 검색한 뒤 **⇥**(또는 ⌘⇧F, '결과 내 검색' 버튼)를 누르면 지금 검색어가 위 줄에 고정되고 검색창이 비어요.
이어서 치는 검색어는 앞 결과 안에서만 찾아요. 몇 단계든 이어 갈 수 있어요.

- 고정된 단계마다 그때의 결과 수가 보이고, ×로 그 단계만 뺄 수 있어요
- 빈 검색창에서 ⌫를 누르면 마지막 단계를 검색창으로 다시 꺼내 고칠 수 있어요
- 실행할 때 `-s`를 여러 번 주면 앞의 것들이 단계가 돼요: `open -a Allspot --args -s 보고서 -s 2026`

## 결과 목록 단축키

엔터 열기 · ⌘엔터/⌘R Finder에서 보기 · 스페이스 훑어보기(Quick Look) · ⌘C/⌘⇧C 경로 복사 · ⌘⌫ 휴지통으로 이동 ·
결과에서 글자를 치면 검색창으로 돌아가 이어서 입력 · 맨 위에서 ↑ 누르면 검색창 · 열 머리를 눌러 정렬 · 파일을 끌어다 다른 앱에 놓기

- 폴더의 크기 칸에는 안에 든 파일 크기의 합이 보여요(보이는 줄만 뒤에서 셈해요).
- 검색창 옆 시계 단추에 최근 검색어 20개가 남아요. 골라서 다시 찾거나 기록을 지울 수 있어요.
- 즐겨찾기: ⌘D(또는 별 단추)로 지금 검색을 결과 내 검색 단계까지 통째로 넣고 빼요. '즐겨찾기' 메뉴에서 고르거나 ⌘1~9로 다시 열어요.

## 구조

- `Sources/AllspotCore/` — 색인 엔진
  - `FileIndex.swift`: 필드별 배열로 담은 색인, 경로 계산, 압축
  - `Scanner.swift`: 병렬 디렉터리 읽기
  - `Query.swift` / `Search.swift`: 검색 문법 해석, 모든 코어로 나눠 거르기, 정렬
  - `Fuzzy.swift`: 유사 검색(초성, 비트 병렬 근사 일치, 건너뛰기)과 점수
  - `ContentIndex.swift`: 문서 내용 색인(뒤에서 읽기, mmap 저장, 병렬 검색)
  - `ContentWorker.swift`: 문서 읽기를 도우미 프로세스에 맡기고 결과 받기
  - `DocumentText.swift`: 형식 고르기, docx·pptx·xlsx(zip+XML)·pdf(PDFKit)·txt·md(UTF-8·UTF-16·CP949) 본문 꺼내기
  - `HwpText.swift` / `Hwp3Text.swift` / `HwpxText.swift`: hwp 5.x(OLE·배포용 문서 포함)·hwp 3.x·hwpx 본문과 작성자 꺼내기
  - `AIAccess.swift`: AI 도구에서 숨길 폴더, 내용을 읽지 않을 비밀 파일
  - `ExternalSearch.swift`: `content:`·`tag:`·`author:`·`taken:`·`spotlight:` 조건을 Spotlight·내용 색인에 묻기
  - `IndexController.swift`: 저장본 읽기 → 전체 훑기 → FSEvents 반영 → 주기 저장
  - `Persistence.swift`: 색인 저장 형식
- `Sources/Allspot/` — 앱 화면 (SwiftUI + 결과 목록은 NSTableView)
- `Sources/AllspotTool/` — AI용 명령줄 도구·MCP 서버 (아래 'AI와 함께 쓰기')
- `Sources/allspot-cli/` — 확인용 명령줄 도구
  - `allspot-cli bench <폴더> [검색어...]`: 훑기·검색 속도, 저장·불러오기 왕복 확인
  - `allspot-cli watch <폴더>`: 파일 생성·이름 바꾸기·삭제가 실시간 반영되는지 확인
  - `allspot-cli fuzzy <빈 폴더>`: 유사 검색·초성·결과 내 검색 확인
  - `allspot-cli cache [검색어...]`: 앱이 저장한 실제 색인으로 일반·유사 검색 속도 재기
  - `allspot-cli list <검색어>`: 실제 색인에서 찾은 전체 경로 찍기
  - `allspot-cli content [검색어...]`: 문서 내용 색인을 임시로 만들고 `content:`·`tag:` 등 시험
  - `allspot-cli worker <allspot-tool 경로> <문서...>`: 문서 읽기 도우미가 죽거나 엉뚱한 것을 내보내도 버티는지 확인
  - `allspot-cli docs`: 내용 색인 저장본(줄어들 때 .bak 남기기 포함)과 시험용 문서(docx·pptx·xlsx·hwpx·PDF·스캔본 PDF·여러 인코딩 글자 파일·망가진 파일)를 만들어 본문 읽기와 AI 접근 규칙·내용 색인 범위를 한꺼번에 확인

  - `Helpers/allspot self-test`: 본문 도우미가 멈추거나(시간 제한) 죽거나 엉뚱한 것을 내보낼 때 서버가 버티는지 확인

색인 저장본 위치: `~/Library/Application Support/Allspot/index.v2.bin` (파일 이름은 그대로지만 안의 형식은 3)

저장본은 메모리로 복사하지 않고 파일을 그대로 비춰 써요(mmap).
- 바뀌지 않은 부분은 macOS가 필요할 때 디스크에서 다시 읽는 메모리라서 앱 몫으로 세지 않아요.
- 개발한 맥(약 420만 개)에서 활성 상태 보기의 메모리가 531MB에서 183MB로 줄었어요.
- 불러오는 시간도 약 150ms에서 12ms로 줄었어요.
- 1MB 넘는 배열은 malloc 대신 mmap으로 잡아요. 이 맥의 할당기는 크게 잡았다 해제한 malloc 메모리를 프로세스 몫으로 계속 세지만, munmap한 메모리는 바로 돌려줘요.

## AI와 함께 쓰기 (명령줄 도구·MCP)

`build-app.sh`가 앱 안에 `Allspot.app/Contents/Helpers/allspot`을 넣어요. 결과는 JSON 한 줄이라 AI 에이전트가 바로 읽어요.

```bash
allspot search 보고서 ext:hwp dm:thisweek --limit 20 --sort modified --desc
allspot search content:예산 kind:doc --paths
allspot search content:예산 --no-spotlight
allspot text "/Users/me/Documents/계획서.hwpx" --max-chars 20000 --offset 0
allspot info "/Users/me/Downloads/a.pdf"
allspot status
allspot mcp
```

- 앱이 저장한 색인을 읽기 전용으로 비춰 읽어요. 저장한 뒤 바뀐 파일은 FSEvents 기록으로 따라잡아요.
  - 한 번 부르는 데 1초 안팎이 걸려요.
  - `--quick`을 붙이면 따라잡기를 건너뛰고 0.4초쯤에 답해요.
  - `content:`·`author:`는 기본으로 Spotlight에도 물어요. `--no-spotlight`(MCP는 `include_spotlight: false`)면 자체 내용 색인만 보고 바로 답해요.
- 앱을 한 번은 실행해 색인을 만들어 둬야 해요. 앱이 꺼져 있어도 쓸 수 있어요.
- `allspot mcp`는 MCP 서버예요(표준 입출력, 한 줄에 JSON-RPC 하나).
  - 도구: `search_files`, `read_document_text`, `file_info`, `index_status`
  - 처음 따라잡은 뒤에는 FSEvents로 계속 최신을 유지해요.
  - Claude Code에 등록하는 명령: `claude mcp add --scope user allspot -- /Applications/Allspot.app/Contents/Helpers/allspot mcp` (`scripts/install.sh`가 대신 해 줘요)
- Claude Code용 스킬 문서: `integrations/claude-skill/allspot/SKILL.md`
- 지키는 것:
  - 읽기만 해요. 파일을 만들거나 고치거나 지우지 않아요.
  - 클라우드에만 있는 파일은 `--download`(MCP는 `allow_download`)를 줄 때만 읽어요. 읽으면 내려받게 돼요.
  - 늘 숨기는 곳(설정에서 끌 수 없음): 홈의 숨김 폴더·파일(`~/.ssh`, `~/.config`, `~/.codex`, `~/.claude.json` 등), 저장소의 `.git` 폴더, `~/Library` 전체.
    - `~/Library` 안에서는 iCloud Drive(Mobile Documents), 클라우드 드라이브(CloudStorage), 앱 컨테이너의 Documents만 보여요.
  - 설정의 'AI 도구에서 더 숨길 폴더'(기본은 비어 있음)도 함께 숨겨요. `*`를 쓸 수 있고 대소문자는 가리지 않아요.
  - `.env`, `id_rsa`, `*.pem`·`*.key`, `auth.json`, `settings.local.json`, 이름에 credential·secret·password가 든 글자 파일, 브라우저의 `Login Data` 같은 비밀 파일은 어디에 있든 검색 결과에서 숨기고 읽지 않아요(한글·워드·PDF 같은 문서는 이름만 보고 막지 않아요).
  - 숨긴 항목은 결과 개수에도 넣지 않아요. 그래서 `content:` 검색으로 숨긴 문서의 내용을 떠볼 수 없어요.
  - 경로는 파일을 열어 커널이 아는 실제 위치로 판정해요. `/System/Volumes/Data/…`, `/.vol/…`, 대소문자 바꾸기, 심볼릭 링크로 규칙을 비켜 갈 수 없어요.
  - 본문은 따로 띄운 도우미(`allspot text-worker`)가 읽어요. 2분 넘게 걸리면 끊어서 망가진 문서가 MCP 서버를 멈추지 못해요.
    - 도우미 명령(`text-worker`, `index-worker`)을 직접 불러도 같은 규칙을 다시 검사해요.
  - 숨긴 곳을 물으면 받은 경로 그대로 거절해서, 그 이름의 파일이 있는지 없는지 알 수 없어요.
  - 검색 결과는 1,000개, 본문은 한 번에 20만 자까지만 돌려줘요. 결과 개수는 10만 개까지 세고, 그보다 많으면 `total_is_lower_bound`를 붙여요.

## 기본으로 빼는 폴더

`/System/Volumes`(/Users 등과 겹침), `/Volumes`(외장·네트워크 디스크), `/dev`, `/private/var/folders`(임시 파일) 등.
설정(⌘,)에서 바꿀 수 있어요. 외장 디스크를 넣으려면 `/Volumes` 줄을 지우세요.

전체 디스크 접근 권한이 없으면 `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Daemon Containers`도 건너뛰어요.
이 폴더를 열면 macOS가 "다른 앱의 데이터에 접근" 허용 창을 띄우는데, 답할 때까지 훑기 전체가 멈추기 때문이에요.
권한을 준 뒤 다시 실행하면 저장본은 그대로 쓰고 이 폴더만 더 읽어요(개발한 맥에서 약 6초).

## 아직 없는 것

- 한글 문서 속 수식·차트·글자겹침 글자, hwp 2.x, 암호 걸린 문서 본문, 사진(jpg·png) 속 글자 인식
- HTTP/ETP 서버, 네트워크 색인
- Developer ID 서명·공증한 완성 앱 배포(그래서 지금은 각자 소스로 빌드해요)

## 라이선스

MIT 라이선스예요(`LICENSE`). 누구나 쓰고, 고치고, 다시 나눠 줄 수 있어요.

- 한글 3.x 읽기(`Hwp3Text.swift`)는 LibreOffice의 변환 표를 옮겨 와서 그 파일만 MPL-2.0이에요. 그 파일을 고쳐 배포하면 고친 소스도 공개해야 해요.
- 본 제품은 한글과컴퓨터의 한글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다.
- 자세한 것은 `THIRD_PARTY_NOTICES.md`를 보세요(앱 안 `Contents/Resources`에도 들어가요).
- Everything은 voidtools의 제품이에요. Allspot은 voidtools와 관계없고, Everything의 코드를 쓰지 않았어요.
