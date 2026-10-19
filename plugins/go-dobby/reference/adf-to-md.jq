# ADF(Jira 문서 구조 JSON) → 마크다운 비슷한 글. 이슈 설명을 읽기 위한 것이라 모양보다 내용 보존이 목적이다.
def inline: if .type=="text" then
    (.text) as $t | ([.marks[]?.type] ) as $m
    | if ($m|index("code")) then "`\($t)`" elif ($m|index("strong")) then "**\($t)**" else $t end
    + ( [.marks[]? | select(.type=="link") | " (\(.attrs.href))"] | join("") )
  elif .type=="hardBreak" then "\n"
  elif .type=="mention" then "@\(.attrs.text // "")"
  elif .type=="inlineCard" then (.attrs.url // "")
  elif .type=="emoji" then (.attrs.text // "")
  else ([.content[]? | inline] | join("")) end;
def block($ind):
  def item($i; $mark): $i + $mark + ([.content[]? | if (.type=="bulletList" or .type=="orderedList") then "\n" + block($i + "  ") else block("") end] | join(""));
  if .type=="paragraph" then $ind + ([.content[]? | inline] | join(""))
  elif .type=="heading" then ("#" * .attrs.level) + " " + ([.content[]? | inline] | join(""))
  elif .type=="bulletList" then [.content[] | item($ind; "- ")] | join("\n")
  elif .type=="orderedList" then [.content | to_entries[] | (.key as $k | .value | item($ind; "\($k + 1). "))] | join("\n")
  elif .type=="codeBlock" then "```\(.attrs.language // "")\n" + ([.content[]?.text] | join("")) + "\n```"
  elif .type=="blockquote" then [.content[]? | block("> ")] | join("\n")
  elif .type=="rule" then "---"
  elif .type=="mediaSingle" or .type=="mediaGroup" then "[첨부 이미지: " + ([.content[]?.attrs.alt // .content[]?.attrs.id // "이름 없음"] | join(", ")) + "]"
  elif .type=="table" then [.content[] | "| " + ([.content[] | [.content[]? | block("")] | join(" ")] | join(" | ")) + " |"] | join("\n")
  elif .type=="panel" or .type=="expand" or .type=="nestedExpand" then [.content[]? | block($ind)] | join("\n\n")
  else ([.content[]? | inline] | join("")) end;
[.content[]? | block("")] | join("\n\n")
