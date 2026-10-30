# 제3자 고지

Allspot은 MIT 라이선스로 배포한다(`LICENSE`). 다만 아래 출처의 코드나 자료를 옮겨 쓴 부분은 그 출처의 조건을 따른다.

## LibreOffice hwpfilter (MPL-2.0)

- 쓴 곳: `Sources/AllspotCore/Hwp3Text.swift`
- 원본: LibreOffice `hwpfilter/source/hcode.cxx` (https://git.libreoffice.org/core/+/refs/heads/master/hwpfilter/source/hcode.cxx)
- 옮긴 것: 한글 3.x 내부 코드를 KS X 1001로 바꾸는 규칙(`s_hh2ks`, `hcharconv`)과 기호 표(`tgSymbols`, 64개)
- 라이선스: Mozilla Public License 2.0 — https://mozilla.org/MPL/2.0/

MPL-2.0은 파일 단위 라이선스다. 그래서 `Hwp3Text.swift` 한 파일은 MPL-2.0으로 배포하고, 이 파일을 고쳐 배포하면 고친 소스도 MPL-2.0으로 공개해야 한다. 나머지 파일에는 이 조건이 걸리지 않는다.

## 한글과컴퓨터 문서 형식 공개 자료

- 「한글 문서 파일 구조 3.0」, 「한글 문서 파일 형식 5.0」, HWPX(OWPML, KS X 6101)
- 한글과컴퓨터가 공개한 형식 설명서를 보고 독자적으로 구현했다. 설명서의 코드는 옮기지 않았다.
- 한글과컴퓨터의 공개 문서에 따라, 이 설명서를 참고해 만든 결과물에는 다음 문구를 넣는다: "본 제품은 한글과컴퓨터의 한글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다."

## Apple 시스템 프레임워크

PDFKit, Vision, CoreServices(Spotlight), CoreText, Compression은 macOS에 들어 있는 것을 링크해서 쓴다. 함께 배포하지 않는다.
