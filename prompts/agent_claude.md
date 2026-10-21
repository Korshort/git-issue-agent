## 리뷰어 띄우기
**Agent 도구**로 띄운다: `subagent_type: "general-purpose"`, `model: "{REVIEW_MODEL}"`,
`prompt` = 「리뷰어 브리프」 전문. fork 하지 않는다(새 컨텍스트). 리뷰어가 끝날 때까지 기다려 판정을 받는다.

## 사용자에게 묻기
**AskUserQuestion** 도구로 묻는다. 선택지에 추천안을 첫 번째로 둔다. 답이 올 때까지 기다린다.
