-- libs/gameover_ui — shared GAME OVER / leaderboard text layout
-- Resolve: require("libs/gameover_ui")
--
-- Pure string formatting only: takes plain numbers/tables in, returns plain
-- strings out. No engine calls, no Text/Sprite handles, so it stays testable
-- with libs/testkit and reusable across games that each own their own Text
-- pool (the 8-label cap means each caller decides which of its own labels
-- gets which line).
--
-- Was "shared verbatim" across word_racer_02 / word_maze_01 / word_garden_03,
-- but the three copies have diverged: word_racer added the language table and
-- the split footer first, and this file follows it for word_maze. Any fix here
-- is worth checking against word_racer/libs/gameover_ui.lua, which is now the
-- more complete of the two -- word_garden still carries the original constants.
--
-- The former M.TITLE / M.FOOTER / M.PENDING_BOARD constants are functions now:
-- a constant is fixed at load, before game_start knows the language.

local M = {}

local language = "vi"
local TEXT = {
  en = {
    title = "GAME OVER", pending = "UPDATING LEADERBOARD...",
    pending_rank = "CALCULATING RANK...",
    footer = "PRESS ENTER TO PLAY AGAIN", top = "TOP 5 EXPLORERS",
    footer_pre = "PRESS", footer_post = "TO PLAY AGAIN",
    score = "SCORE", rank = "RANK",
  },
  vi = {
    title = "KẾT THÚC", pending = "ĐANG CẬP NHẬT BẢNG XẾP HẠNG...",
    pending_rank = "ĐANG TÍNH HẠNG...",
    footer = "NHẤN NÚT ĐỂ CHƠI LẠI", top = "TOP 5 NHÀ THÁM HIỂM",
    footer_pre = "NHẤN", footer_post = "ĐỂ CHƠI LẠI",
    score = "ĐIỂM", rank = "HẠNG",
  },
}

local function tr(key)
  return TEXT[language][key] or TEXT.en[key] or key
end

function M.set_language(value)
  language = value == "en" and "en" or "vi"
end

function M.title() return tr("title") end
function M.pending_board() return tr("pending") end
function M.footer() return tr("footer") end

-- Split footer for callers that render the ENTER button as a SPRITE between the
-- two halves instead of spelling it out ("NHẤN NÚT ĐỂ CHƠI LẠI"). Copied from
-- word_racer, which introduced it.
--
-- Text has no width-query API, so a sprite can only be placed beside a label
-- whose relevant EDGE is pinned. Anchoring the halves bottom_right/bottom_left
-- does exactly that -- the inner edges stay put while the outer ends grow with
-- the string, which is why this survives the vi/en length difference that a
-- centred single label could not. M.footer() stays for text-only callers.
function M.footer_pre() return tr("footer_pre") end
function M.footer_post() return tr("footer_post") end

-- Hero score line: the star sprite beside it names the value, so this carries
-- the number and only enough of a word to anchor it. `score` is an
-- already-rounded integer -- callers floor their own float, which keeps this a
-- pure formatter with no opinion about any one game's scoring unit.
--
-- M.stat_line() lived here and rendered "CRUMBS n  BEST n". It went with the
-- crumb and best-score lines: on the OVER screen a fresh player reads them as
-- "0 and 0", which teaches nothing, and the crumb tally is already visible in
-- the HUD throughout the run. word_racer's OVER screen shows score and rank
-- only, for the same reason.
function M.score_card(score)
  return tr("score") .. "  " .. score
end

-- Rank on its own line so it can take its own accent colour, and so the score
-- above it stays the largest thing on the screen.
function M.rank_line(rank)
  if rank then return tr("rank") .. "  #" .. rank end
  return tr("pending_rank")
end

-- display_name comes straight from the backend and is neither glyph-checked
-- nor width-checked anywhere between GET /games/rank and the LVGL label, so it
-- gets both treatments here.
--
-- 1. The pack ships one Vietnamese face: Latin plus Vietnamese, no emoji and
--    no symbol block. A name carrying one renders as tofu, so anything at or
--    above U+2000 is dropped rather than shown as a broken box. Combining
--    marks (U+0300..U+036F) are kept -- they are how decomposed Vietnamese
--    spells its diacritics.
-- 2. string.format's "%-10s" pads by BYTES. One emoji is 4 bytes and one
--    Vietnamese letter is 2-3, so byte padding misaligned the score column for
--    every non-ASCII name. Padding is counted in codepoints here instead, and
--    truncation lands on a codepoint boundary so a cut name can never emit a
--    partial sequence into the label.
local NAME_COLS = 10

local function keep_cp(cp)
  if cp < 0x0300 then return true end            -- ASCII + Latin-1
  if cp <= 0x036F then return true end           -- combining diacritics
  return cp < 0x2000                             -- Latin Extended; drop symbols/emoji
end

-- utf8.codes RAISES on malformed input, and a backend string is untrusted, so
-- the walk is wrapped: a name that fails to decode degrades to "?" instead of
-- taking the OVER screen down with it.
local function sanitize(s)
  local out, n = {}, 0
  for _, cp in utf8.codes(s) do
    if n >= NAME_COLS then break end
    if keep_cp(cp) then
      n = n + 1
      out[n] = utf8.char(cp)
    end
  end
  return table.concat(out), n
end

function M.safe_name(value)
  local s = tostring(value or "")
  local ok, text, cols = pcall(sanitize, s)
  if ok then
    -- Dropping a trailing emoji ("An 😀") leaves the separator space dangling
    -- before the pad; trim so the name ends on a real glyph. Only trailing
    -- blanks go -- interior spaces are part of the name.
    local trimmed = string.gsub(text, "%s+$", "")
    if trimmed ~= text then
      cols = cols - (utf8.len(text) - utf8.len(trimmed))
      text = trimmed
    end
  end
  if not ok or text == "" then return "?" .. string.rep(" ", NAME_COLS - 1) end
  return text .. string.rep(" ", NAME_COLS - cols)
end

-- result is the Ranking.get_result() payload: { top = {{rank,display_name,score}, ...}, my_rank }.
-- Returns the TOP-5 board text, or nil if result has no usable top[] (caller
-- keeps its pending_board() placeholder up in that case).
--
-- The player's own row is marked with ">" (word_racer does the same): five names
-- with no marker leaves the child hunting for themselves, and a name can repeat
-- across a family sharing one robot.
function M.top5_board(result)
  if not result or not result.top then return nil end
  local lines = { tr("top") }
  local my_rank = M.rank_of(result)
  for i, row in ipairs(result.top) do
    if i > 5 then break end
    local rank = row.rank or i
    local marker = rank == my_rank and ">" or " "
    -- "%s" not "%-10s": safe_name already padded to NAME_COLS in codepoints.
    lines[#lines + 1] = string.format("%s %d. %s %d",
      marker, rank, M.safe_name(row.display_name), math.floor(row.score or 0))
  end
  return table.concat(lines, "\n")
end

function M.rank_of(result)
  local my_rank = result and result.my_rank
  return my_rank and my_rank.rank or nil
end

return M
