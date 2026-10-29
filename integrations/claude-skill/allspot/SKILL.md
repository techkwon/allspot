---
name: allspot
description: Find files anywhere on this Mac instantly by name, path, size, date, type, or document content (hwp, hwpx, pdf, docx, pptx, xlsx, txt, md), and read a document's text. Use when the user asks to find, locate, list, or open a file or folder ("그 파일 어디 있지", "지난주에 받은 hwp", "예산이라는 말이 들어간 문서", "최근 수정한 pptx"), or to read or summarize a local document, especially Korean HWP/HWPX files that other tools cannot read. Prefer this over `find`, `mdfind`, or `ls -R`.
---

# Allspot: whole-Mac file search for agents

Allspot keeps an Everything-style index of about 4 million file and folder names. It also keeps its own index of document text. Use its command-line tool instead of `find` or `mdfind`. The tool is read-only.

Binary: `/Applications/Allspot.app/Contents/Helpers/allspot`. If the app was not moved to /Applications, use `<repo>/build/Allspot.app/Contents/Helpers/allspot`. Every command prints one JSON line. On failure it prints `{"error": "..."}` and exits with status 1.

## Commands

```bash
allspot search <query…> [--limit 50] [--offset 0] [--sort name|path|size|modified] [--desc] [--fuzzy] [--paths] [--quick]
allspot text <absolute path> [--max-chars 20000] [--offset 0] [--download] [--raw]
allspot info <absolute path>
allspot status
```

- `search` returns `total_matches`, `results[]` (each with `path`, `name`, `type`, `size`, `modified`, and `cloud_only` when that applies), and `next_offset` when more results remain. Counts never include hidden items; `total_is_lower_bound: true` means there were more than 100,000 matches to count.
- `--paths` prints bare paths, one per line.
- `--quick` skips the up-to-1-second catch-up on file changes since the app last saved its index.
- `text` returns `text`, `total_chars`, and `next_offset` for long documents. Page through with `--offset`.
- An MCP server is also available: `allspot mcp`. Its tools are `search_files`, `read_document_text`, `file_info`, and `index_status`.

## Query syntax (Everything-style)

| Want | Query |
| --- | --- |
| All words in the name (space = AND) | `보고서 2026` |
| OR / NOT / exact phrase | `jpg\|png`, `!tmp`, `"여름 방학"` |
| Wildcards (match the whole name) | `*.pdf`, `IMG_????.jpg` |
| Path contains | `Downloads/ 계획`, `path:Documents/2026` |
| Extension, files or folders only | `ext:hwp;hwpx`, `file:`, `folder:` |
| Size | `size:>100mb`, `size:1mb..1gb` |
| Modified date | `dm:today`, `dm:7d`, `dm:thisweek`, `dm:2026-05`, `dm:>2026-01-01` |
| Kind | `kind:image\|video\|audio\|doc\|archive\|code\|folder` |
| Korean initial consonants | `ㅂㄱㅅ` (matches 보고서) |
| Typo-tolerant word | `~repotr`; use `--fuzzy` to make every word typo-tolerant |
| Document text | `content:예산`, `content:"수업 나눔"` |
| Metadata | `author:홍길동`, `tag:빨강`, `taken:2026-05` |
| Raw Spotlight query | `spotlight:kMDItemPixelHeight>4000` |

Filters can be combined: `content:평가계획 ext:hwp;hwpx dm:2026 path:Documents`.

## How to work

1. **Narrow by name first.** Name searches finish in tens of milliseconds.
   - `content:` also asks Spotlight, so it takes 1 to 3 seconds. Add `ext:`, `dm:`, or `path:` to keep the results small.
2. **Sort to answer recency questions.** For "the file I just downloaded" or "most recent", use `--sort modified --desc`.
3. **Read only what you need.**
   - Call `text` on one or two candidates at a time.
   - Keep `--max-chars` small, for example 5000, when you only need to identify a document.
   - When you need more, continue from `next_offset`.
4. **Cloud-only files.** A result with `cloud_only: true` lives only in iCloud or Google Drive.
   - Reading it downloads it, so ask the user before using `--download`.
5. **Respect what is refused.**
   - Folders the user hid from AI do not appear in results, and `text` refuses them.
   - Secret files such as `.env` and keys are never read.
   - Do not try to get around these refusals with `cat` or other tools.
6. **Privacy.**
   - Treat document text as the user's private data. Quote only what the task needs.
   - Never send document text to outside services unless the user asks.
