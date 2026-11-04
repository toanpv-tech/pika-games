-- libs/i18n — UI language for Word Maze (vi / en)
-- Resolve: require("libs/i18n")
--
-- Structure follows word_racer/libs/i18n.lua: one TEXT table per language, a
-- set_language() called once from game_start with params.language, and a t()
-- that falls back en -> key so a missing entry shows the key instead of nil.
--
-- SCOPE: chrome only. The curriculum is NEVER translated -- `words`, `pattern`
-- and the sentences built from them are what the child must SAY, and they are
-- the strings handed to Voice.set_keywords. Keyword spotting matches on
-- English, so translating them would make the game unable to hear a correct
-- answer. Same split as word_racer: it shows "VÒNG 3 - THỜI TIẾT" while the
-- lane still reads SUNNY.
--
-- What that means per string kind:
--   translated  — messages, rule names/hints, intro card, the two HUD fields
--                 still spelled as words, the LEAD-IN of a prompt ("MỞ: ")
--   kept        — the vocabulary word on a chip, the sentence after a prompt
--                 lead-in, and the literal keyword FIGHT (CFG.FIGHT_KEYWORD)
--   no string   — lives and the score: both are named by an icon the child
--                 already knows (a heart, and the crumb they pick up to score).
--                 Nothing to translate in either.

local M = {}

local language = "vi"

local TEXT = {
  en = {
    -- HUD field labels. Only the map and clock are worded: lives are hearts and
    -- the score is named by the crumb mark beside it (CFG.SPR_HUD_*), so the
    -- label that cost 55 px the combo needed is gone. gameover_ui.lua keeps its
    -- own "SCORE" for the end screen, where there is room to name things.
    map = "MAP",
    time = "TIME",
    key = "KEY",

    -- Prompt lead-ins. The sentence that follows stays English.
    open_lead = "OPEN: ",
    say_lead = "SAY: ",

    -- Panel hints. FIGHT is the literal keyword, never translated.
    fight_hint = 'SAY "FIGHT" TO BATTLE!',
    voice_dead_gate = "VOICE ERROR - CANNOT OPEN THE CAGE",
    voice_dead = "VOICE ERROR - CHECK THE NETWORK",

    -- Messages raised by libs/rules
    msg_key = "GOT THE KEY!",
    msg_locked = "LOCKED! FIND THE KEY",
    msg_open_door = "OPEN THE DOOR!",
    msg_open_cage = "OPEN THE CHEESE CAGE!",
    msg_hurt = "OUCH! -1 LIFE",
    msg_cheese = "CHEESE! +",
    msg_say_sentence = "SAY THE SENTENCE!",
    msg_say_lead = "SAY: ",

    -- Intro card
    monsters = " MONSTERS",
    no_monsters = "NO MONSTERS",

    -- Rule names (levels.rule_name)
    rule_gauntlet = "GAUNTLET",
    rule_fog = "FOG",
    rule_key_monsters = "KEY + MONSTERS",
    rule_key = "KEY & DOOR",
    rule_monsters = "MONSTERS",
    rule_tutorial = "TUTORIAL",

    -- Rule hints (levels.rule_hint)
    hint_gauntlet = 'RED CHASER! SAY "FIGHT" THEN THE SENTENCE',
    hint_fog = "FOG! ONLY SEE NEAR THE MOUSE",
    hint_monsters = 'MONSTER? SAY "FIGHT", THEN THE SENTENCE',
    hint_key = "GRAB THE KEY, THEN OPEN THE CAGE",
    hint_tutorial = "SAY THE WORD TO MOVE",
  },
  vi = {
    map = "MÀN",
    time = "GIỜ",
    key = "CHÌA",

    open_lead = "MỞ: ",
    say_lead = "NÓI: ",

    fight_hint = 'NÓI "FIGHT" ĐỂ ĐÁNH!',
    voice_dead_gate = "MIC LỖI - KHÔNG MỞ ĐƯỢC LỒNG",
    voice_dead = "MIC LỖI - KIỂM TRA MẠNG",

    msg_key = "ĐƯỢC CHÌA KHOÁ!",
    msg_locked = "BỊ KHOÁ! TÌM CHÌA KHOÁ",
    msg_open_door = "MỞ CỬA ĐI!",
    msg_open_cage = "MỞ LỒNG PHÔ MAI!",
    msg_hurt = "ĐAU QUÁ! -1 MẠNG",
    msg_cheese = "PHÔ MAI! +",
    msg_say_sentence = "HÃY NÓI CẢ CÂU!",
    msg_say_lead = "NÓI: ",

    monsters = " QUÁI VẬT",
    no_monsters = "KHÔNG CÓ QUÁI VẬT",

    rule_gauntlet = "TRUY SÁT",
    rule_fog = "SƯƠNG MÙ",
    rule_key_monsters = "CHÌA + QUÁI VẬT",
    rule_key = "CHÌA & CỬA",
    rule_monsters = "QUÁI VẬT",
    rule_tutorial = "TẬP CHƠI",

    hint_gauntlet = 'KẺ TRUY SÁT ĐỎ! NÓI "FIGHT" RỒI ĐỌC CÂU',
    hint_fog = "SƯƠNG MÙ! CHỈ THẤY QUANH CHUỘT",
    hint_monsters = 'GẶP QUÁI VẬT? NÓI "FIGHT" RỒI ĐỌC CÂU',
    hint_key = "LẤY CHÌA KHOÁ RỒI MỞ LỒNG",
    hint_tutorial = "ĐỌC TỪ ĐỂ DI CHUYỂN",
  },
}

-- Topic display names. Keyed by the English `topic` field of
-- curriculum.TOPICS, which stays English because the vocabulary does.
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
  ["Size & Shape"] = "KÍCH THƯỚC & HÌNH DẠNG",
  ["Games I Like"] = "TRÒ CHƠI",
  ["Sweet Treats"] = "ĐỒ NGỌT",
  ["Sea Animals"] = "ĐỘNG VẬT BIỂN",
  ["Places to Go"] = "ĐỊA ĐIỂM",
}

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
  if language == "vi" then return TOPICS_VI[name] or name:upper() end
  return name:upper()
end

return M
