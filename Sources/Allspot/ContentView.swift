import AllspotCore
import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                accessBanner
            }
            if !model.refinements.isEmpty {
                refinementBar
            }
            HStack(spacing: 8) {
                SearchFieldView(model: model)
                    .frame(height: 30)
                Button {
                    model.refineWithinResults()
                } label: {
                    Label("결과 내 검색", systemImage: "line.3.horizontal.decrease.circle")
                }
                .disabled(!model.canRefine)
                .help("지금 검색어를 고정하고, 이 결과 안에서 다시 검색해요 (⌘⇧F 또는 검색창에서 ⇥)")
                Toggle(isOn: $model.fuzzyMode) {
                    Label("유사", systemImage: "wand.and.stars")
                }
                .toggleStyle(.button)
                .help("유사 검색: 오타·빠진 글자·초성(ㅂㄱㅅ)도 찾고 비슷한 순으로 보여 줘요 (⌘U)")
                Menu {
                    Button(model.isCurrentBookmarked ? "지금 검색을 즐겨찾기에서 빼기" : "지금 검색을 즐겨찾기에 넣기") {
                        model.toggleCurrentBookmark()
                    }
                    .disabled(model.currentBookmark == nil)
                    if !model.bookmarks.isEmpty {
                        Divider()
                        ForEach(model.bookmarks) { bookmark in
                            Button(bookmark.title) { model.openBookmark(bookmark) }
                        }
                        Divider()
                        Menu("즐겨찾기 지우기") {
                            ForEach(model.bookmarks) { bookmark in
                                Button(bookmark.title) { model.removeBookmark(bookmark) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: model.isCurrentBookmarked ? "star.fill" : "star")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("즐겨찾기한 검색 (⌘D 넣기·빼기, ⌘1~9 열기)")
                Menu {
                    if model.recentQueries.isEmpty {
                        Text("아직 없어요")
                    }
                    ForEach(model.recentQueries, id: \.self) { text in
                        Button(text) { model.query = text }
                    }
                    if !model.recentQueries.isEmpty {
                        Divider()
                        Button("최근 검색 지우기") { model.clearRecentQueries() }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("최근 검색")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ResultsTableView(model: model)
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private var accessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text("전체 디스크 접근 권한이 없어서 메일·사진 보관함 같은 보호된 폴더는 빠져요. 권한을 준 뒤 앱을 다시 열면 다른 앱의 데이터 폴더까지 모두 색인해요.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("권한 설정 열기") { model.openFullDiskAccessSettings() }
            Button("다시 확인") { model.checkFullDiskAccess() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    /// 결과 내 검색 단계. 단계마다 그때의 결과 수를 보여 주고, ×로 그 단계만 뺄 수 있다.
    private var refinementBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            Text("결과 내 검색")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.refinements.enumerated()), id: \.element.id) { index, refinement in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        RefinementChip(refinement: refinement) { model.removeRefinement(refinement) }
                    }
                }
            }
            Button("모두 지우기") { model.clearRefinements() }
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.resultCount.formatted())개 항목")
                .monospacedDigit()
            if model.fuzzyMode {
                Label("유사 검색", systemImage: "wand.and.stars")
                    .foregroundStyle(Color.accentColor)
            }
            if let error = model.queryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            if model.isSearchingOutside {
                ProgressView().controlSize(.small)
                Text("Spotlight·내용 색인에서 찾는 중…")
            }
            if let line = model.contentStatusLine {
                Label(line, systemImage: "doc.text.magnifyingglass")
                    .monospacedDigit()
            }
            if model.isIndexing {
                ProgressView().controlSize(.small)
            }
            Text(model.statusLine)
                .monospacedDigit()
            if model.resultsVersion > 0 {
                Text(String(format: "%.0f ms", model.searchMillis))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

struct RefinementChip: View {
    let refinement: Refinement
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if refinement.fuzzy {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
            }
            Text(refinement.text)
                .lineLimit(1)
            if refinement.count > 0 {
                Text(refinement.count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("이 단계 빼기")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

/// 검색창. 아래 화살표로 결과 목록에 들어가고, 엔터로 첫 결과를 열고, 빈 칸에서 Esc를 누르면 창을 숨긴다.
/// ⇥는 결과 내 검색, 빈 칸에서 ⌫는 앞 단계 검색어를 다시 꺼낸다.
struct SearchFieldView: NSViewRepresentable {
    @ObservedObject var model: SearchModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = Self.placeholder
        field.font = .systemFont(ofSize: 15)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.focusRingType = .none
        model.searchField = field
        return field
    }

    static let placeholder = "파일 이름 검색   예) 보고서 *.hwp   ext:jpg;png   size:>100mb   dm:today   path:Downloads"

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
        let placeholder = model.refinements.isEmpty ? Self.placeholder : "결과 \(model.resultCount.formatted())개 안에서 다시 검색…   (⌫ 앞 단계로)"
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: SearchModel
        init(model: SearchModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                model.focusResults()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                model.openSelectedOrFirst()
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard model.canRefine else { return false }
                model.refineWithinResults()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard model.query.isEmpty, !model.refinements.isEmpty else { return false }
                model.popRefinement()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if model.query.isEmpty {
                    NSApp.hide(nil)
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}
