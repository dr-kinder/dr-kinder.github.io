-- num-si.lua
--
-- Minimal, purpose-built replacement for the slice of siunitx Jesse actually
-- uses: \num, \si, \SI, "." for inter-unit multiplication, \per, \degree,
-- \angstrom, "u" as a micro-prefix, and sans-serif unit font. This is not a
-- port of siunitx's source -- siunitx is a general TeX macro package with its
-- own parser; rewriting it isn't practical outside TeX. Instead this rebuilds
-- just the output behavior he named, as a Pandoc Lua filter that rewrites raw
-- math source BEFORE Quarto hands it to MathJax (HTML) or LaTeX (PDF) -- so
-- both outputs get real \times-10^n scientific notation and real computed
-- uncertainty, which a runtime MathJax macro can't do (no parsing, only
-- fixed-argument substitution).
--
-- Scope: only touches math spans ($...$ / $$...$$). Never touches prose, so
-- normal sentence punctuation is untouched.

-- Uncertainty convention: \num{1.45(7)} -> 1.45 \pm 0.07 (7 aligned to the
-- last shown decimal place of the mantissa -- the standard/siunitx
-- convention). Jesse's own example said 0.007; flagged for confirmation,
-- this implementation uses the standard convention.
local function transform_num(val)
  local mantissa, exp = val:match("^([%d%.%-]+)[eE]([%+%-]?%d+)$")
  if mantissa then
    exp = exp:gsub("^%+", "")
    return mantissa .. " \\times 10^{" .. exp .. "}"
  end

  local main, unc = val:match("^([%d%.%-]+)%((%d+)%)$")
  if main then
    local decimals = main:match("%.(%d+)$")
    local ndec = decimals and #decimals or 0
    local uncval = tonumber(unc) / (10 ^ ndec)
    local uncstr = string.format("%." .. ndec .. "f", uncval)
    return main .. " \\pm " .. uncstr
  end

  return val -- plain number, nothing to do
end

-- Unit-string transforms. Scoped to text captured inside \si{...} /
-- \SI{...}{...}'s second argument only -- "." here always means inter-unit
-- multiplication (siunitx's own convention, and Jesse's kinder-book.tex
-- already sets inter-unit-product = \cdot). Applying this globally across
-- all math would wreck ordinary decimal points elsewhere, so it must not
-- run outside this function.
local function transform_unit(unit)
  unit = unit:gsub("\\per%s*", "/")
  unit = unit:gsub("%.", " \\cdot ")
  -- "u" as a micro-prefix only when followed by more unit letters (um, uF,
  -- uA...); a bare standalone "u" is left alone since it's also the atomic
  -- mass unit symbol -- ambiguous, so the safer default is "don't touch it".
  unit = unit:gsub("(%f[%a])u(%a+)", "\\mu %2")
  return "\\mathsf{" .. unit .. "}"
end

-- \degree and \angstrom work standalone too (e.g. "$45\degree$"), not just
-- inside \si{}, so this runs once over the whole math string first.
local function global_symbols(s)
  s = s:gsub("\\degree", "{}^{\\circ}")
  s = s:gsub("\\angstrom", "\\text{\\AA}")
  return s
end

-- Balanced-brace group reader: s:sub(i,i) must be "{". Returns the group's
-- contents and the index just past the closing brace.
local function read_group(s, i)
  if s:sub(i, i) ~= "{" then return nil, i end
  local depth, j, n = 0, i, #s
  while j <= n do
    local c = s:sub(j, j)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return s:sub(i + 1, j - 1), j + 1 end
    end
    j = j + 1
  end
  return nil, i -- unbalanced; bail out and leave the source untouched
end

-- Full HTML rewrite: rebuilds \num/\si/\SI entirely, since MathJax has none
-- of them. `micro_repl` is the replacement text used for the "u" prefix
-- fix ("\\mu" for HTML -- a plain math symbol MathJax already knows).
local function process(s, unit_fn)
  s = global_symbols(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local matched = false

    if s:sub(i, i + 3) == "\\SI{" then
      local val, j1 = read_group(s, i + 3)
      if val then
        local unit, j2 = read_group(s, j1)
        if unit then
          table.insert(out, transform_num(val) .. "\\," .. unit_fn(unit))
          i = j2
          matched = true
        end
      end
    elseif s:sub(i, i + 3) == "\\num" and s:sub(i + 4, i + 4) == "{" then
      local val, j1 = read_group(s, i + 4)
      if val then
        table.insert(out, transform_num(val))
        i = j1
        matched = true
      end
    elseif s:sub(i, i + 2) == "\\si" and s:sub(i + 3, i + 3) == "{" then
      local unit, j1 = read_group(s, i + 3)
      if unit then
        table.insert(out, unit_fn(unit))
        i = j1
        matched = true
      end
    end

    if not matched then
      table.insert(out, s:sub(i, i))
      i = i + 1
    end
  end
  return table.concat(out)
end

-- PDF/LaTeX: real siunitx handles \num, \si, \SI, ".", \per, \degree,
-- \angstrom natively and correctly -- leave all of that alone. The one gap:
-- siunitx has no ASCII "u" shorthand for the micro prefix, and
-- \DeclareSIPrefix can't add one (verified directly -- it only sets the
-- printed symbol for a prefix's own named command, not a new input token
-- for the compact-letter parser; a fresh \DeclareSIPrefix with micro's own
-- symbol still left "\si{um}" as literal "um"). What does work, verified:
-- mixing the real \micro command with literal letters inside \si{}, e.g.
-- "\si{\micro m}" -- so this only rewrites the "u" prefix inside \si{}/\SI{}
-- unit arguments to "\micro ", and passes everything else through as
-- original source, untouched, for siunitx itself to parse.
local function pdf_fix_unit(unit)
  return unit:gsub("(%f[%a])u(%a+)", "\\micro %2")
end

local function process_pdf_micro(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local matched = false

    if s:sub(i, i + 3) == "\\SI{" then
      local val, j1 = read_group(s, i + 3)
      if val then
        local unit, j2 = read_group(s, j1)
        if unit then
          table.insert(out, "\\SI{" .. val .. "}{" .. pdf_fix_unit(unit) .. "}")
          i = j2
          matched = true
        end
      end
    elseif s:sub(i, i + 2) == "\\si" and s:sub(i + 3, i + 3) == "{" then
      local unit, j1 = read_group(s, i + 3)
      if unit then
        table.insert(out, "\\si{" .. pdf_fix_unit(unit) .. "}")
        i = j1
        matched = true
      end
    end

    if not matched then
      table.insert(out, s:sub(i, i))
      i = i + 1
    end
  end
  return table.concat(out)
end

function Math(el)
  if FORMAT:match("html") then
    el.text = process(el.text, transform_unit)
  else
    el.text = process_pdf_micro(el.text)
  end
  return el
end
