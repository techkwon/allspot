import AllspotCore
import SwiftUI

struct SettingsView: View {
    // 이 SDK의 명령줄 도구에는 @State 매크로 플러그인이 없어, 편집 중인 글은 모델에 둔다.
    @EnvironmentObject private var model: SearchModel

    private var contentSummary: String {
        let s: ContentIndexStatus = model.contentStatus
        guard model.indexDocumentContents else { return "꺼져 있어요. content:는 Spotlight 색인으로만 찾아요." }
        guard s.total > 0 || s.cloudSkipped > 0 else { return "파일 이름 색인이 끝나면 시작해요." }
        var line = s.isRunning ? "읽는 중 \(s.indexed.formatted())/\(s.total.formatted())개" : "\(s.total.formatted())개 문서의 내용을 읽어 뒀어요"
        if s.cloudSkipped > 0 { line += " · 클라우드에만 있는 \(s.cloudSkipped.formatted())개는 건너뜀" }
        return line
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $model.excludedDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                HStack {
                    Button("기본값으로") {
                        model.excludedDraft = IndexConfiguration.defaultExcludedPaths.joined(separator: "\n")
                    }
                    Spacer()
                    Button("저장하고 색인 다시 만들기") {
                        let paths = model.excludedDraft.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { $0.hasPrefix("/") }
                        UserDefaults.standard.set(paths, forKey: SearchModel.excludedPathsKey)
                        model.rebuildIndex()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("색인에서 뺄 폴더 (한 줄에 하나)")
            } footer: {
                Text("외장 디스크를 넣으려면 /Volumes 줄을 지우세요. 바꾼 뒤에는 디스크를 처음부터 다시 훑어요.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("검색 창 열기/숨기기")
                    Spacer()
                    Button(model.isRecordingHotKey ? "새 단축키를 누르세요… (Esc 취소)" : model.hotKey.display) {
                        model.startRecordingHotKey()
                    }
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    Button("기본값") { model.resetHotKey() }
                        .disabled(model.hotKey == .standard && !model.isRecordingHotKey)
                }
                if let error = model.hotKeyError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("전역 단축키")
            } footer: {
                Text("버튼을 누른 뒤 원하는 조합(예: ⌃⌥Space, ⌥F, F5)을 누르세요. 다른 앱을 쓰는 중에도 이 키로 창을 불러와요.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("문서 내용 색인 (hwp·hwpx·pdf·docx·pptx·xlsx·txt·md)", isOn: $model.indexDocumentContents)
                Toggle("클라우드에만 있는 문서도 내려받아 읽기", isOn: $model.includeCloudDocuments)
                    .disabled(!model.indexDocumentContents)
                Text(contentSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } header: {
                Text("문서 내용 검색")
            } footer: {
                Text("Spotlight은 한글 문서 내용을 읽지 못해서 Allspot이 직접 읽어 둬요. 다른 형식도 Spotlight 결과와 함께 찾아요. 시스템·앱 내부 파일은 빼고, txt·md는 1MB 이하이면서 개발 폴더(~/Developer, node_modules 등) 밖의 것만 넣어요. 클라우드 파일을 켜면 Google Drive·iCloud에서 문서를 내려받으므로 디스크와 데이터를 많이 쓸 수 있어요.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $model.aiExcludedDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                HStack {
                    Button("기본값으로") {
                        model.aiExcludedDraft = AIAccessPolicy.defaultExcludedPaths.joined(separator: "\n")
                    }
                    Spacer()
                    Button("저장") {
                        let paths = model.aiExcludedDraft.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { $0.hasPrefix("/") || $0.hasPrefix("~") || $0.hasPrefix("*") }
                        UserDefaults.standard.set(paths, forKey: AIAccessPolicy.excludedPathsKey)
                    }
                }
            } header: {
                Text("AI 도구에서 더 숨길 폴더 (한 줄에 하나, ~ = 홈, * 가능)")
            } footer: {
                Text("명령줄 도구 Allspot.app/Contents/Helpers/allspot 과 MCP 서버(allspot mcp)는 이 폴더 안을 검색 결과와 개수에서 빼고 읽지 않아요. 이 목록과 상관없이 홈의 숨김 폴더(~/.ssh, ~/.config 등), 저장소의 .git 폴더, ~/Library(iCloud Drive·클라우드 드라이브·앱 문서 폴더만 빼고), .env·키·auth.json·비밀번호 파일 같은 비밀 파일은 늘 숨겨요. 앱의 검색 결과에는 영향이 없어요.")
                    .foregroundStyle(.secondary)
            }

            Section("검색 문법") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("공백 = 그리고, | = 또는, ! = 제외, \"따옴표\" = 구절")
                    Text("*.pdf  보고서?.hwp  ext:jpg;png  path:Downloads  regex:^IMG_\\d+")
                    Text("file:  folder:  size:>100mb  size:1mb..1gb  dm:today  dm:7d  dm:>2026-01-01")
                    Text("유사 검색: ~repotr 또는 fuzzy:repotr (낱말 하나만), ⌘U로 전체 켜기 · 초성: ㅂㄱㅅ, 보ㄱㅅ")
                    Text("결과 내 검색: 검색 후 ⇥ 또는 ⌘⇧F → 이어서 입력 · 빈 칸에서 ⌫ 앞 단계로")
                    Text("내용: content:예산 (내용:예산) · 메타데이터: tag:빨강  author:홍길동  taken:2026-05")
                    Text("종류: kind:image|video|audio|doc|archive|code|folder (kind:사진) · spotlight:kMDItemPixelHeight>4000")
                    Text("결과에서: 엔터 열기 · ⌘R Finder · 스페이스 훑어보기 · ⌘⇧C 경로 복사 · ⌘⌫ 휴지통")
                }
                .font(.callout)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 700)
        .frame(width: 560)
        .onAppear {
            let saved = UserDefaults.standard.stringArray(forKey: SearchModel.excludedPathsKey) ?? IndexConfiguration.defaultExcludedPaths
            model.excludedDraft = saved.joined(separator: "\n")
            let hidden = UserDefaults.standard.stringArray(forKey: AIAccessPolicy.excludedPathsKey) ?? AIAccessPolicy.defaultExcludedPaths
            model.aiExcludedDraft = hidden.joined(separator: "\n")
        }
    }
}
