-- metal-boites.lua — Filtre Quarto : encadrés MetalEmacs selon le format
-- À placer dans le dossier du document (le tableau de bord s'en charge).
--
-- Usage dans un .qmd :
--   filters:
--     - metal-boites.lua
--
-- Syntaxe dans le document :
--   :::{.infobox title="Mon titre"}
--   Contenu **Markdown** normal ici.
--   :::
--
-- Rendu :
--   PDF / Beamer (LaTeX) → environnements tcolorbox (metal-tcolorbox.sty)
--   HTML, Word, etc.      → callouts Quarto natifs, avec leur titre
--
-- En sortie non LaTeX, \textcolor{couleur}{texte} devient un <span> coloré
-- (HTML) ou du texte simple (autres formats) : le texte n'est jamais perdu.

local box_classes = {
  infobox      = "note",
  exercicebox  = "note",
  warningbox   = "important",
  attentionbox = "warning",
}

-- Le titre précise parfois mieux le type de callout que la classe :
-- l'infobox sert à la fois aux remarques et aux astuces.
local titre_vers_callout = {
  ["astuce"]    = "tip",
  ["conseil"]   = "tip",
  ["remarque"]  = "note",
  ["note"]      = "note",
  ["attention"] = "warning",
  ["important"] = "important",
  ["exercice"]  = "note",
}

local function sortie_latex()
  if quarto and quarto.doc and quarto.doc.is_format then
    return quarto.doc.is_format("latex") or quarto.doc.is_format("beamer")
  end
  return FORMAT:match("latex") ~= nil or FORMAT:match("beamer") ~= nil
end

local function sortie_html()
  if quarto and quarto.doc and quarto.doc.is_format then
    return quarto.doc.is_format("html")
  end
  return FORMAT:match("html") ~= nil
end

-- ── Encadrés ────────────────────────────────────────────────────────────

function Div(el)
  for _, class in ipairs(el.classes) do
    local defaut = box_classes[class]
    if defaut then
      local title = el.attributes["title"] or ""

      if sortie_latex() then
        local blocks = { pandoc.RawBlock("latex",
          "\\begin{" .. class .. "}[" .. title .. "]") }
        for _, b in ipairs(el.content) do
          blocks[#blocks + 1] = b
        end
        blocks[#blocks + 1] = pandoc.RawBlock("latex", "\\end{" .. class .. "}")
        return blocks
      end

      local type_callout = titre_vers_callout[pandoc.text.lower(title)] or defaut
      -- Quarto ≥ 1.3 reconnaît les callouts AVANT les filtres utilisateur :
      -- un Div « callout-* » créé ici ne serait plus converti.  On construit
      -- donc directement le nœud Callout de Quarto.
      if quarto and quarto.Callout then
        return quarto.Callout({
          type    = type_callout,
          title   = (title ~= "" and title) or nil,
          content = el.content,
        })
      end
      -- Hors Quarto (pandoc seul) : Div de callout, stylable en CSS.
      local attrs = {}
      if title ~= "" then attrs["title"] = title end
      return pandoc.Div(el.content,
        pandoc.Attr(el.identifier, { "callout-" .. type_callout }, attrs))
    end
  end
end

-- ── \textcolor hors LaTeX ───────────────────────────────────────────────

-- Couleurs xcolor sans équivalent CSS direct.
local couleurs_css = {
  ["green!50!black"] = "#3f7f3f",
  ["violet"]         = "#8e44ad",
  ["gray"]           = "#7f8c8d",
}

local function couleur_css(c)
  if couleurs_css[c] then return couleurs_css[c] end
  -- Mélange xcolor (« red!60 », « blue!50!black ») : garder la teinte.
  return (c:match("^([^!]+)")) or c
end

-- Extraire les deux arguments de \textcolor{c}{t}, accolades imbriquées
-- comprises dans t.
local function analyser_textcolor(texte)
  local couleur, reste = texte:match("^\\textcolor%s*{([^}]*)}%s*(.*)$")
  if not couleur or reste:sub(1, 1) ~= "{" then return nil end
  local profondeur = 0
  for i = 1, #reste do
    local ch = reste:sub(i, i)
    if ch == "{" then
      profondeur = profondeur + 1
    elseif ch == "}" then
      profondeur = profondeur - 1
      if profondeur == 0 then
        if reste:sub(i + 1):match("^%s*$") then
          return couleur, reste:sub(2, i - 1)
        end
        return nil
      end
    end
  end
  return nil
end

function RawInline(el)
  if sortie_latex() or not (el.format == "tex" or el.format == "latex") then
    return nil
  end
  local couleur, contenu = analyser_textcolor(el.text)
  if not couleur then return nil end
  local doc = pandoc.read(contenu, "markdown")
  local inlines = (doc.blocks[1] and doc.blocks[1].content) or {}
  if sortie_html() then
    return pandoc.Span(inlines,
      pandoc.Attr("", {}, { style = "color: " .. couleur_css(couleur) .. ";" }))
  end
  return inlines
end

-- ── header-includes LaTeX hors LaTeX ────────────────────────────────────
-- En HTML, un `header-includes: |' rempli de \usepackage… serait recopié
-- tel quel en tête de page, donc visible.  On retire les entrées qui
-- contiennent du LaTeX brut ; une entrée HTML légitime est conservée.
-- La liste doit rester une liste (éventuellement vide) : Quarto la relit.

local function contient_latex(valeur)
  local trouve = false
  local function voir(r)
    if r.format == "tex" or r.format == "latex" then
      trouve = true
    -- Quarto a déjà converti l'entrée en bloc brut HTML : on reconnaît
    -- le LaTeX à son contenu (une commande \nom en tête de texte).
    elseif r.text:match("^%s*\\%a") then
      trouve = true
    end
  end
  local t = pandoc.utils.type(valeur)
  if t == "Inlines" then
    pandoc.Inlines(valeur):walk({ RawInline = voir })
  elseif t == "Blocks" then
    pandoc.Blocks(valeur):walk({ RawInline = voir, RawBlock = voir })
  elseif t == "string" then
    trouve = valeur:match("\\%a+") ~= nil
  end
  return trouve
end

function Meta(meta)
  if sortie_latex() then return nil end
  local hi = meta["header-includes"]
  if hi == nil then return nil end
  local items = (pandoc.utils.type(hi) == "List") and hi or pandoc.List({ hi })
  local gardes = pandoc.List()
  for _, item in ipairs(items) do
    if not contient_latex(item) then gardes:insert(item) end
  end
  meta["header-includes"] = gardes
  return meta
end
