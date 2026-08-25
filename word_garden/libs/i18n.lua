-- libs/i18n — UI language for Word Garden (vi / en)
-- Resolve: require("libs/i18n")
--
-- Structure follows word_racer/libs/i18n.lua and word_maze/libs/i18n.lua: one
-- TEXT table per language, a set_language() called once from game_start with
-- params.language, and a t() that falls back en -> key so a missing entry shows
-- the key instead of nil.
--
-- SCOPE: chrome only. The curriculum is NEVER translated -- `words` and
-- `pattern` in libs/curriculum, and the phrases built from them, are what the
-- child must SAY and what goes to Voice.set_keywords. Keyword spotting matches
-- on English, so translating them would make the game unable to hear a correct
-- answer. Same split as word_racer and word_maze.
--
-- What that means per string kind:
--   translated  — messages, the HUD field labels, the intro/clear banners, the
--                 LEAD-IN of the spell prompt ("PHÉP: ")
--   kept        — the seed word on a plot label, and the phrase after the spell
--                 lead-in; both are spoken back to the microphone
--   no string   — lives: they have a picture the child already knows
--                 (life.png), so there is nothing to translate.

local M = {}

local language = "vi"

local TEXT = {
  en = {
    -- HUD field labels. All three are worded now: the sun label opens row 1 and
    -- names the bar that follows it, the garden count is centred between bar and
    -- lives, and the score owns row 2. Lives stay iconic (life.png) -- a picture
    -- the child already reads.
    garden = "GARDEN",
    sun = "SUN:",
    score = "SCORE:",

    -- Spell prompt lead-in. The phrase that follows stays English.
    spell_lead = "SPELL: ",

    -- Panel hint shown while no crow is out and no message is up, and the line
    -- that replaces it when the microphone is dead. Since gameplay went
    -- voice-only there is no button fallback, so a dead mic means the round
    -- cannot advance at all -- the red LED alone left the child staring at a
    -- garden that would not respond.
    idle_hint = "SAY A SEED WORD TO BLOOM!",
    voice_dead = "VOICE ERROR - CHECK THE NETWORK",

    -- Banners and messages
    retry = "TRY AGAIN!",
    garden_done = "GARDEN DONE! +",
    crow_ate = "THE CROW ATE ",
    sunset = "SUNSET! -1 LIFE",
  },
  vi = {
    garden = "VƯỜN",
    sun = "NẮNG:",
    score = "ĐIỂM:",

    spell_lead = "PHÉP: ",

    idle_hint = "NÓI MỘT TỪ ĐỂ HOA NỞ!",
    voice_dead = "MIC LỖI - KIỂM TRA MẠNG",

    retry = "THỬ LẠI!",
    garden_done = "XONG VƯỜN! +",
    crow_ate = "QUẠ MỔ MẤT HOA ",
    sunset = "HOÀNG HÔN! -1 MẠNG",
  },
}

-- Topic display names. Keyed by the English `name` field of curriculum.T, which
-- stays English because the vocabulary does. Note "Size Shape" (no ampersand):
-- keyed to what libs/curriculum actually spells, not to word_maze's variant.
local TOPICS_VI = {
  Weather = "THỜI TIẾT",
  ["School Objects"] = "ĐỒ DÙNG HỌC TẬP",
  Clothes = "QUẦN ÁO",
  Fruits = "TRÁI CÂY",
  Home = "NGÔI NHÀ",
  Sports = "THỂ THAO",
  Nature = "THIÊN NHIÊN",
  Technology = "CÔNG NGHỆ",
  Transportation = "GIAO THÔNG",
  Animals = "ĐỘNG VẬT",
  Hobby = "SỞ THÍCH",
  ["How I Feel"] = "CẢM XÚC",
  ["Face Parts"] = "KHUÔN MẶT",
  ["Classroom Colours"] = "MÀU SẮC",
  ["Food I Like"] = "THỨC ĂN",
  ["Toys I Like"] = "ĐỒ CHƠI",
  Rooms = "CÁC PHÒNG",
  ["Drinks I Like"] = "ĐỒ UỐNG",
  Vegetables = "RAU CỦ",
  ["Size Shape"] = "KÍCH THƯỚC & HÌNH DẠNG",
  ["Games I Like"] = "TRÒ CHƠI",
  ["Sweet Treats"] = "ĐỒ NGỌT",
  ["Sea Animals"] = "ĐỘNG VẬT BIỂN",
  ["Places to Go"] = "ĐỊA ĐIỂM",
}

-- Rendered widths of the HUD's row-1 pieces, in px at HUD_PX, so main.lua can
-- pad "VƯỜN n" to the screen centre. Tiny TTF gives Lua no width query and each
-- row is a single Text label (the 8-slot pool has none spare, and a Text has one
-- alignment), so the widths have to be derived rather than measured at runtime.
--
-- Every DIGIT in this face shares one advance -- 572 units, 9.152 px at 16 px --
-- so only the digit COUNT varies and each width is an exact linear model: a
-- constant for the worded part plus HUD_DIGIT_W per digit. Checked against the
-- font's hmtx: predicted and real agree to 0.01 px.
--
-- Per-language because the words differ in width (NẮNG:/VƯỜN vs SUN:/GARDEN).
M.HUD_DIGIT_W = 9.152

-- Width of the "NẮNG:" / "SUN:" label that opens row 1.
local HUD_SUN_W = { vi = 50.48, en = 36.93 }
-- Width of "VƯỜN " / "GARDEN " -- the word plus its trailing space, no digits.
local HUD_GARDEN_W = { vi = 50.94, en = 68.72 }

function M.hud_sun_w()
  return HUD_SUN_W[language] or HUD_SUN_W.en
end

function M.hud_garden_w(digits)
  return (HUD_GARDEN_W[language] or HUD_GARDEN_W.en) + digits * M.HUD_DIGIT_W
end

-- Advance of each UPPERCASE letter used by a topic name, in px at HUD_PX.
-- Topic names are the one HUD string that is neither a fixed word nor a number,
-- so their width cannot be a per-language constant -- but a 48-entry table of
-- pre-measured names would rot silently the moment someone edits a name or adds
-- a topic. Measuring per CHARACTER instead keeps it correct by construction.
--
-- The table is small because in this face a DIACRITIC NEVER CHANGES THE
-- ADVANCE: A = Ắ = Ậ = 10.22, E = Ê = Ế = Ệ = 8.90, O = Ô = Ộ = 12.50. So only
-- the base letter matters, and 28 entries cover every topic name in both
-- languages -- including any not written yet.
local GLYPH_W = {
  [" "] = 4.16, ["&"] = 11.71,
  A = 10.22, B = 10.40, C = 10.11, D = 11.68, E = 8.90, F = 8.30,
  G = 11.65, H = 11.86, I = 5.42, J = 4.37, K = 9.90, L = 8.38,
  M = 14.51, N = 12.16, O = 12.50, P = 9.68, Q = 12.50, R = 9.95,
  S = 8.78, T = 8.90, U = 11.70, V = 9.60, W = 14.88, X = 9.38,
  Y = 9.06, Z = 9.15,
}
-- Base letter each Vietnamese vowel decomposes to for WIDTH purposes. Ơ/Ư carry
-- a horn that DOES widen them (12.54 / 12.48 vs O 12.50 / U 11.70), so they get
-- their own entries rather than folding into O/U.
local BASE = {
  ["À"]="A",["Á"]="A",["Â"]="A",["Ă"]="A",["Ạ"]="A",["Ả"]="A",["Ầ"]="A",["Ậ"]="A",["Ắ"]="A",["Ặ"]="A",
  ["Ê"]="E",["Ế"]="E",["Ể"]="E",["Ệ"]="E",
  ["Ì"]="I",["Í"]="I",["Ị"]="I",
  ["Ò"]="O",["Ô"]="O",["Ọ"]="O",["Ố"]="O",["Ồ"]="O",["Ộ"]="O",
  ["Ù"]="U",["Ú"]="U",["Ủ"]="U",
  ["Đ"]="D",
}
local HORN_W = { ["Ơ"]=12.54, ["Ớ"]=12.54, ["Ờ"]=12.54, ["Ở"]=12.54,
                 ["Ư"]=12.48, ["Ứ"]=12.48 }

-- Rendered width of an already-uppercased topic name, in px at HUD_PX.
-- Unknown characters fall back to the average letter rather than zero, so a name
-- using something unforeseen lands slightly off centre instead of far off it.
local FALLBACK_W = 10.0

function M.text_w(s)
  local total = 0
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    total = total + (HORN_W[ch] or GLYPH_W[ch] or GLYPH_W[BASE[ch] or ""] or FALLBACK_W)
  end
  return total
end

function M.set_language(value)
  language = value == "en" and "en" or "vi"
  return language
end

function M.language()
  return language
end

function M.t(key)
  return TEXT[language][key] or TEXT.en[key] or key
end

-- Topic name for display. Falls back to the English name so a curriculum entry
-- added without a translation shows its real topic instead of a key.
function M.topic(name)
  if language == "vi" then return TOPICS_VI[name] or string.upper(name) end
  return string.upper(name)
end

return M
