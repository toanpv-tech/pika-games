-- Can-do card rules: plain Lua, no engine calls.
-- Input: the "game" pack document (GAME_START data) or the start params
-- (lv = mode 1..3, i = phrases said alone 0..3).

local M = {}

M.MODES = { "after_lesson", "intro", "collection" }

-- Topic t1 of the "Lesson test" demo (strings as in the demo).
M.LESSON = "Câu lạc bộ Sở thích"
M.TOPIC = "Sở thích của bạn"
M.CODE = "Bài thử 1"
M.FRIENDS = "May · An Linh · Kobi"
M.GOAL = "kể sở thích của các bạn"
M.KID = "Tớ kể được sở thích của các bạn."
M.OWN = "Cậu kể được sở thích của các bạn rồi!"
M.SCENE = "Câu lạc bộ"

-- slot: centre (x, y) and side in scene pixels (scene 460 x 200); motion after it is placed.
M.WORDS = {
  { id = 0, en = "collecting cute things", color = 0xFD20, x = 92,  y = 99,  size = 76, motion = "wiggle",
    cue = "Đồ dễ thương xếp đầy kệ của May: collecting cute things!" },
  { id = 1, en = "playing with my pet",    color = 0x07FF, x = 238, y = 150, size = 86, motion = "gallop",
    cue = "Bingo chạy chơi với bóng: playing with my pet!" },
  { id = 2, en = "making slime",           color = 0xF81F, x = 392, y = 106, size = 70, motion = "wiggle",
    cue = "Slime trên bàn của Kobi: making slime!" },
}

M.MILESTONES = { "Hỏi đáp", "Nghe hiểu", "Vốn ngôn ngữ", "Tạo câu" }
M.MS_LINES = {
  "Cậu đã tự chào được các bạn mới!",
  "Cậu đã tự đoán được sở thích của các bạn!",
  "Cậu đã tự nói được cả 3 sở thích!",
  "Cậu đã tự nói được sở thích cậu muốn thử!",
}
local MS_VOCAB = 2   -- reached only when every phrase was said alone

local LV_MODE = { [1] = "intro", [2] = "after_lesson", [3] = "collection" }

local function to_int(v)
  local n = tonumber(v)
  if n == nil then return nil end
  return math.tointeger(n)
end

local function set_of(arr, lo, hi)
  local s = {}
  if type(arr) ~= "table" then return s end
  for _, v in ipairs(arr) do
    local n = to_int(v)
    if n and n >= lo and n <= hi then s[n] = true end
  end
  return s
end

local function valid_mode(m)
  for _, v in ipairs(M.MODES) do if v == m then return true end end
  return false
end

-- State for a tester-chosen run (no server data): first n phrases said.
function M.from_count(mode, n)
  local st = { mode = mode, said = {}, ms_new = {}, ms_have = {}, placed = {}, source = "count" }
  for k = 1, #M.WORDS do st.said[k] = (k <= n) end
  for ms = 0, 3 do
    if ms ~= MS_VOCAB or n == #M.WORDS then st.ms_new[ms] = true end
  end
  return st
end

-- doc: Pack.data("game") or nil; p: start params table or nil.
-- Returns state, or nil when neither carries anything usable.
function M.from_input(doc, p)
  if type(doc) == "table" and type(doc.words) == "table" then
    local mode = valid_mode(doc.mode) and doc.mode or "after_lesson"
    local st = { mode = mode, said = {}, source = "data" }
    for k = 1, #M.WORDS do st.said[k] = false end
    for _, w in ipairs(doc.words) do
      local id = type(w) == "table" and to_int(w.id)
      if id and id >= 0 and id < #M.WORDS then st.said[id + 1] = (w.said == true) end
    end
    st.ms_new = set_of(doc.ms_new, 0, 3)
    st.ms_have = set_of(doc.ms_have, 0, 3)
    st.placed = set_of(doc.placed, 0, #M.WORDS - 1)
    if type(doc.date) == "string" and #doc.date <= 16 then st.date = doc.date end
    return st
  end
  if type(p) == "table" then
    local lv = to_int(p.lv)
    if lv and LV_MODE[lv] then
      local n = to_int(p.i) or #M.WORDS
      if n < 0 then n = 0 elseif n > #M.WORDS then n = #M.WORDS end
      local st = M.from_count(LV_MODE[lv], n)
      st.source = "params"
      return st
    end
  end
  return nil
end

function M.said_count(st)
  local n = 0
  for k = 1, #M.WORDS do if st.said[k] then n = n + 1 end end
  return n
end

function M.ms_count(st)
  local n = 0
  for ms = 0, 3 do if st.ms_new[ms] or st.ms_have[ms] then n = n + 1 end end
  return n
end

function M.card_done(st)
  return M.ms_count(st) == 4
end

-- Unlocked stickers not yet on the page, in word order (1-based word index).
function M.pending(st)
  local out = {}
  for k = 1, #M.WORDS do
    if st.said[k] and not st.placed[k - 1] then out[#out + 1] = k end
  end
  return out
end

-- Card label before the "lessons done" flip, and after it.
function M.state_label(st, flipped)
  if flipped and M.card_done(st) then return "Đã đạt" end
  return M.ms_count(st) > 0 and "Đang phát triển" or "Chưa đạt"
end

local function names(st, said)
  local out = {}
  for k, w in ipairs(M.WORDS) do
    if (st.said[k] == true) == said then out[#out + 1] = w.en end
  end
  return out
end

-- Pika's lines (subtitles until recorded audio exists).
function M.summary_line(st)
  local n = M.said_count(st)
  if n == #M.WORDS then return "Hôm nay cậu học được 3 sở thích ở " .. M.LESSON .. "! Cậu tự nói được hết luôn!" end
  if n > 0 then return "Hôm nay cậu học được 3 sở thích! Cậu tự nói được " .. n .. " cái rồi." end
  return "Hôm nay cậu học được 3 sở thích! Lần sau cậu thử tự nói nhé."
end

function M.feedback_line(st)
  local n = M.said_count(st)
  for ms = 0, 3 do
    if st.ms_new[ms] then
      return M.MS_LINES[ms + 1] .. (n > 0 and (" Mở khoá " .. n .. " sticker!") or "")
    end
  end
  if n > 0 then return "Cậu đã tự nói được " .. table.concat(names(st, true), ", ") .. "! Sticker mở khoá rồi!" end
  local prac = names(st, false)
  if #prac > 0 then return "Hôm nay mình luyện " .. table.concat(prac, ", ") .. ". Lần sau cậu thử tự nói nhé!" end
  return "Mình luyện tiếp nhé!"
end

function M.place_line(k, miss)
  local en = M.WORDS[k].en
  if miss then return "Chỗ này là của sticker khác. Tìm hình giống " .. en .. " nhé!" end
  return en:sub(1, 1):upper() .. en:sub(2) .. " ở chỗ nào nhỉ? Tìm hình giống sticker nhé!"
end

M.LINE_OPENING = "Mở sổ nào!"
M.LINE_LATER = "Sticker chờ ở góc trang. Lúc nào cậu vào Bộ thẻ, mình dán tiếp nhé!"
M.LINE_SKIP = "Bỏ qua thì sticker chờ ở góc trang nhé."
M.LINE_FLIP = "Xong bài " .. M.LESSON .. "! Thẻ " .. M.TOPIC .. " lật lên rồi!"
M.LINE_MAKEOVER = M.OWN .. " Thẻ " .. M.TOPIC .. " là của cậu, Pika xác nhận rồi!"
M.LINE_INTRO = "Chủ đề mới: " .. M.TOPIC .. "! Có một thẻ đang che 4 mảnh và 3 sticker bị khoá."
  .. " Cậu tự nói được từ nào thì sticker từ đó mở khoá nhé!"

-- Result JSON the lesson agent reads: s/n drive the response case, q = quit.
function M.result_json(st, placed_now, unlocked, secs, quit)
  local ids = {}
  for k = 1, #M.WORDS do
    if st.placed[k - 1] then ids[#ids + 1] = tostring(k - 1) end
  end
  return table.concat({
    '{"v":1,"g":"cando_book","mode":"', st.mode, '","s":', tostring(placed_now),
    ',"n":', tostring(unlocked), ',"q":', quit and "1" or "0", ',"t":', tostring(secs),
    ',"pl":[', table.concat(ids, ","), '],"card":"',
    st.mode == "intro" and "none" or (M.card_done(st) and "dat" or "dang"), '"}',
  })
end

return M
