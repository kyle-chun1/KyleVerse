-- Insert trusted, HTML-escaped API text after the Python pre-render validation.
-- Raw HTML bypasses Pandoc's smart punctuation and Markdown transformations.
function Div(el)
  if el.classes:includes("verse-of-day-slot") then
    local root = os.getenv("QUARTO_PROJECT_DIR") or "."
    local file = assert(io.open(root .. "/_verse/card.html", "r"),
      "Verse card is missing; run the configured Python pre-render script.")
    local html = file:read("*a")
    file:close()
    return pandoc.RawBlock("html", html)
  end
end
