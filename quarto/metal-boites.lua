-- metal-boites.lua — Filtre Quarto : divs Markdown → environnements tcolorbox
-- À placer dans ~/.emacs.d/ (ou le répertoire du projet)
--
-- Usage dans un .qmd :
--   filters:
--     - metal-boites.lua
--
-- Syntaxe dans le document :
--   :::{.infobox title="Mon titre"}
--   Contenu **Markdown** normal ici.
--   :::

local box_classes = {
  "infobox", "exercicebox", "warningbox", "attentionbox"
}

local function is_box(class)
  for _, c in ipairs(box_classes) do
    if c == class then return true end
  end
  return false
end

function Div(el)
  for _, class in ipairs(el.classes) do
    if is_box(class) then
      local title = el.attributes["title"] or ""
      local open  = pandoc.RawBlock("latex",
        "\\begin{" .. class .. "}[" .. title .. "]")
      local close = pandoc.RawBlock("latex",
        "\\end{" .. class .. "}")
      local blocks = { open }
      for _, b in ipairs(el.content) do
        blocks[#blocks + 1] = b
      end
      blocks[#blocks + 1] = close
      return blocks
    end
  end
end
