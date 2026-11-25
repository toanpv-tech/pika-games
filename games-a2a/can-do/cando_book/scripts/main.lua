-- Can-do Sticker Book (cando_book): post-lesson card + sticker book, the screens of the
-- "Lesson test" demo (backlog/Lesson Test Demo.html) for one lesson (Câu lạc bộ Sở thích).
--
-- INPUT   Pack.data("game") {mode, words[{id,said}], ms_new, ms_have, placed, date}
--         else start params lv (1 intro, 2 after lesson, 3 collection), i (phrases said 0..3)
--         else (Pika Studio / menu) a tester screen picks mode and phrases said.
-- FLOWS   after_lesson: SUMMARY > CARD > [OPENING > PLACE > STUCK ... | LATER] > FLIP > [MAKEOVER] > DONE
--         intro: INTRO > DONE
--         collection: SHELF > DETAIL > BOOKV > [PLACE ...] (Quay lại / Thoát chips)
-- BUTTONS left / right / middle only: in a talk-flow game HOME ends the game without
--         on_home, so skipping and going back are chips picked with the middle button.
-- ART     every screen is the demo's own pixels: backgrounds (assets/cd/*.rgb565), elements
--         with alpha (assets/el/*.png, positions in libs/art.lua), big effects as GIFs. Motion
--         follows the demo's CSS keyframes. Only the current scene's sprites are alive.
-- RESULT  Engine.report_result (talk flow only), see libs/rules.lua result_json.
--
-- BUDGET  Text 7 of 8 | fonts 4 faces | PSRAM: one scene's sprites (< 1.3 MB) + one big GIF

local Rules = require("libs/rules")
local VOICE = require("libs/voice")
local ART = require("libs/art")

local FONT = "fonts/nunito-700.ttf"     -- Nunito 700, as the demo (OFL, subset Latin + Vietnamese)
local SIZE_TITLE, SIZE_BODY, SIZE_LINE = 22, 16, 15   -- demo subtitle is 15.5 px
local T_WHITE, T_DIM, T_GOLD, T_FOOT = 0xFFFFFF, 0xB0B8D0, 0xFFD700, 0x8A7C68
local C_BG = 0x18E9

local BG = {
  dark = "assets/cd/bg_dark.rgb565", sum = "assets/cd/sum_bg.rgb565", fb = "assets/cd/fb_bg.rgb565",
  page = "assets/cd/page_bg.rgb565", intro = "assets/cd/intro_bg.rgb565",
  coll = "assets/cd/coll_bg.rgb565", det = "assets/cd/det_bg.rgb565",
}
local A_SUB_BAR = "assets/cd/sub_bar.rgb565"
local GIF = {
  flip = "assets/cd/flip.gif", flip_dang = "assets/cd/flip_dang.gif", mk_in = "assets/cd/mk_in.gif",
  mk_loop = "assets/cd/mk_loop.gif", open = "assets/cd/open.gif",
}
local MOODS = { "happy", "celebrate", "proud", "encourage", "curious" }

local DATA_WAIT_MS = 1500      -- GAME_START data may land just after game_start
local OPENING_MS = 1300
local DONE_EXIT_MS = 1800
local LINE_CHARS = 54          -- subtitle wrap matching the demo (390 px at 15.5 px)
local VOICE_GAP_MS = 170       -- Speaker.play refuses a play within 150 ms of the previous one
local VOICE_MAX_MS = 15000     -- longest line is about 9 s
local BURST = { { -46, -30 }, { 44, -34 }, { -40, 30 }, { 46, 26 }, { 0, -52 }, { 0, 46 } }   -- demo burst()

local S = {
  params = {}, st = nil, scene = "LOAD", t0 = 0, started = 0,
  setup_row = 1, setup_mode = 1, setup_n = 3,
  place_q = {}, sel = 1, miss = false, miss_at = 0, stuck_w = 0, back_to = nil,
  opt = 1, flipped = false, unlocked = 0, placed_now = 0,
  reported = false, cur_sound = nil,
}
local tx = {}        -- Text records {t, s, col, vis, size, base}
local SC = {}        -- sprites of the current scene
local FX = {}        -- animated sprites of the current scene
local PL = nil       -- PLACE pools: { slot[k] = {placed, sel, hint, sil}, skip_on, skip_off, ghost[k] }
local P = {}         -- persistent: background solid, subtitle bar, static faces
local AN = {}        -- big GIF anims by name
local FACE = { mood = nil, anim = nil }

-- Helpers ----------------------------------------------------------------------
local function put(spr, x, y)
  if spr then spr:set_pos(x // 1, y // 1); spr:set_visible(true) end
end

local function hide(spr)
  if spr then spr:set_visible(false) end
end

local function sc_clear()
  for i = #SC, 1, -1 do SC[i]:destroy() end
  SC, FX, PL = {}, {}, nil
end

local function bg(key)
  local s, err = Sprite.new(BG[key], 480, 270)
  if not s then print("cando: bg failed " .. key .. " " .. tostring(err)); return nil end
  put(s, 0, 0); SC[#SC + 1] = s
  return s
end

-- An element of the demo at its captured place (+ dx, dy).
local function el(name, dx, dy)
  local a = ART[name]
  if not a then print("cando: no art " .. name); return nil end
  local s, err = Sprite.image("assets/el/" .. name .. ".png")
  if not s then print("cando: el failed " .. name .. " " .. tostring(err)); return nil end
  put(s, a[1] + (dx or 0), a[2] + (dy or 0)); SC[#SC + 1] = s
  return s
end

local function fx(spr, kind, extra)
  if not spr then return nil end
  local r = extra or {}
  r.spr, r.kind = spr, kind
  r.x, r.y = spr:get_pos()
  r.cx, r.cy = r.x, r.y   -- perf: last values sent (fx_tick sends on change only); unmeasured
  FX[#FX + 1] = r
  return r
end

local function set_size(rec, size)
  if rec.size == size then return end
  local ok, ferr = rec.t:set_font(FONT, size)
  if ok == nil and ferr then print("cando: set_font failed: " .. tostring(ferr)) end
  rec.size = size
end

local function label(size)
  local t, err = Text.new("", 0, 0)
  if not t then print("cando: Text.new failed: " .. tostring(err)); return {} end
  local rec = { t = t, vis = false, base = size }
  set_size(rec, size)
  t:show(false)
  return rec
end

-- Text is drawn in creation order and Anim has no set_z: labels are rebuilt after the
-- scene's sprites and after every Anim.new so they stay on top.
local LABELS = { "sub", "r1", "r2", "r3", "line", "hint" }
local function build_labels()
  for _, rec in pairs(tx) do if rec.t then rec.t:destroy() end end
  tx = {}
  tx.title = label(SIZE_TITLE)
  for _, k in ipairs(LABELS) do tx[k] = label(k == "line" and SIZE_LINE or SIZE_BODY) end
end

local function say(rec, str, x, y, col, size)
  if not rec.t then return end
  set_size(rec, size or rec.base)
  if rec.s ~= str then rec.s = str; rec.t:set(str) end
  rec.t:move(x // 1, y // 1)
  local c = col or T_WHITE
  if rec.col ~= c then rec.col = c; rec.t:set_color(c) end
  if not rec.vis then rec.vis = true; rec.t:show(true) end
end

local function say_at(rec, str, where, dx, dy, col, size)
  if not rec.t then return end
  say(rec, str, 0, 0, col, size)
  rec.t:align(where, dx, dy)
end

-- Break at spaces into lines of at most n characters (utf8 aware).
local function wrap(str, n)
  local lines, cur = {}, ""
  for word in str:gmatch("%S+") do
    if cur == "" then cur = word
    elseif utf8.len(cur) + 1 + utf8.len(word) <= n then cur = cur .. " " .. word
    else lines[#lines + 1] = cur; cur = word end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return table.concat(lines, "\n")
end

-- The date line of a Đã đạt card: the demo's line, the date from the server data.
local function card_date(where)
  local d = ART.date[where]
  local str = "Pika xác nhận" .. (S.st.date and (" · " .. S.st.date) or "")
  say_at(tx.r2, str, "top", d[1] - 240, d[2], T_FOOT, d[3])
end

-- Pika's face: the demo's moodOf(), an animated GIF when no big GIF plays, else its first frame.
local function mood_of(t)
  local function has(...) for _, w in ipairs({ ... }) do if t:find(w, 1, true) then return true end end return false end
  if has("Đã đạt", "xác nhận", "giỏi quá", "Tuyệt", "tuyệt quá", "Hoan hô") then return "proud" end
  if has("mở khoá", "lật rồi", "Bí mật", "bí mật", "Sticker mới", "đạt chặng", "mở thêm") then return "celebrate" end
  if has("ở chỗ nào", "Tìm hình", "chỗ khác") or t:find("%?%s*$") then return "curious" end
  if has("Lần sau", "thử lại", "thử xem", "Bỏ qua", "không sao", "Chưa", "chưa") then return "encourage" end
  return "happy"
end

local function big_gif_playing()
  for _, a in pairs(AN) do if a:is_playing() then return true end end
  return false
end

local function face_show(mood)
  for _, m in ipairs(MOODS) do if m ~= mood then hide(P["face_" .. m]) end end
  if FACE.mood ~= mood then
    if FACE.anim then FACE.anim:destroy(); FACE.anim = nil end
    FACE.mood = mood
  end
  if not FACE.anim and not big_gif_playing() then
    local a = Anim.new("assets/face/face_" .. mood .. ".gif")
    if a then a:set_pos(0, 270); a:play(true); FACE.anim = a end
  end
  if FACE.anim and FACE.anim:is_playing() then
    FACE.anim:set_visible(true); hide(P["face_" .. mood])
  else
    put(P["face_" .. mood], 0, 270)
  end
end

local voice_say

-- Demo subtitle: bar 480x50 at y 270, Pika's face box at (0, 270), text at (78, 277).
local function pika(str)
  put(P.sub_bar, 0, 270)
  face_show(mood_of(str))
  local lines = wrap(str, LINE_CHARS)
  say(tx.line, lines, 78, select(2, lines:gsub("\n", "")) >= 2 and 271 or 277, T_WHITE)
  voice_say(str)
end

local function subtitle_off()
  hide(P.sub_bar)
  for _, m in ipairs(MOODS) do hide(P["face_" .. m]) end
  if FACE.anim then FACE.anim:set_visible(false) end
end

local function clear_texts()
  for _, rec in pairs(tx) do
    if rec.t and rec.vis then rec.vis = false; rec.t:show(false) end
  end
end

-- Sounds ---------------------------------------------------------------------------
-- Demo sounds (tone() of the demo, rendered to WAV). One channel: a press plays "click"
-- only when it did not start another sound (two plays within 150 ms are refused).
local function sfx(alias)
  S.sound_this_press = true
  S.vq, S.v_wait, S.v_text = {}, nil, nil
  if S.cur_sound then Speaker.stop(S.cur_sound) end
  if Speaker.play(alias) then S.cur_sound = alias; S.v_ready_at = Timer.millis() + VOICE_GAP_MS end
end

-- Pika's recorded line for a subtitle: one clip, or a milestone line + "Mở khoá N sticker!".
local function voice_clips(str)
  if VOICE[str] then return { VOICE[str] } end
  for i = 1, #Rules.MS_LINES do
    local ms = Rules.MS_LINES[i]
    if str:sub(1, #ms) == ms and VOICE[ms] then
      local tail = str:sub(#ms + 2)
      return VOICE[tail] and { VOICE[ms], VOICE[tail] } or { VOICE[ms] }
    end
  end
  return {}
end

-- Queue the line; on_tick plays it once the sound effect has been handed over (cooldown 150 ms).
voice_say = function(str)
  if S.v_text == str then return end
  S.v_text = str
  if S.v_wait then Speaker.stop(S.v_wait); S.v_wait = nil end
  S.vq = voice_clips(str)
  S.v_ready_at = math.max(S.v_ready_at or 0, Timer.millis() + VOICE_GAP_MS)
  if #S.vq == 0 then print("cando: no recorded line for: " .. str) end
end

local function voice_tick(now)
  if S.v_wait and now - S.v_started > VOICE_MAX_MS then S.v_wait = nil end   -- a cut sound sends no on_sound_end
  if S.v_wait or not S.vq or #S.vq == 0 or now < (S.v_ready_at or 0) then return end
  local a = S.vq[1]
  if Speaker.play(a) then
    table.remove(S.vq, 1)
    S.v_wait, S.cur_sound, S.v_started = a, a, now
  else
    S.v_ready_at = now + VOICE_GAP_MS
  end
end

-- Motion: the demo's CSS keyframes, on sprites of at most 96 px ---------------------------
local function ease_out(t) return 1 - (1 - t) * (1 - t) end
local function ease_io(t) return t < 0.5 and 2 * t * t or 1 - (-2 * t + 2) ^ 2 / 2 end
local function lerp(a, b, t) return a + (b - a) * t end
-- Keyframes {at 0..1, value}: linear between them, each step eased by f.
local function key(frames, t, f)
  for i = 2, #frames do
    local a, b = frames[i - 1], frames[i]
    if t <= b[1] then
      local u = (t - a[1]) / (b[1] - a[1]); if f then u = f(u) end
      return lerp(a[2], b[2], u)
    end
  end
  return frames[#frames][2]
end

-- perf: keyframes hoisted out of fx_tick: the literals built ~10-20 tables per frame
-- (PERF-HEAP, arena churn / GC hitches suspected, unmeasured).
local K_PO_SC = { { 0, 1 }, { 0.3, 1.15 }, { 1, 0.6 } }
local K_PO_ROT = { { 0, 0 }, { 0.3, 0 }, { 1, 250 } }
local K_PO_DY = { { 0, 0 }, { 0.3, 0 }, { 1, -30 } }
local K_PO_OPA = { { 0, 1 }, { 0.3, 1 }, { 1, 0 } }
local K_PULSE = { { 0, 1 }, { 0.5, 1.18 }, { 1, 1 } }
local K_HOVER_DY = { { 0, 0 }, { 0.5, -0.12 }, { 1, 0 } }        -- times the ghost height
local K_HOVER_ROT = { { 0, 0 }, { 0.5, 40 }, { 1, 0 } }
local K_NOPE_DX = { { 0, 0 }, { 0.2, -0.12 }, { 0.4, 0.12 }, { 0.6, -0.08 }, { 0.8, 0.06 }, { 1, 0 } }
local K_NOPE_ROT = { { 0, 0 }, { 0.2, -80 }, { 0.4, 80 }, { 0.6, 0 }, { 1, 0 } }
local K_DROP_DY = { { 0, -120 }, { 0.55, 4 }, { 0.75, -4 }, { 1, 0 } }
local K_DROP_SC = { { 0, 1.7 }, { 0.55, 0.95 }, { 0.75, 1.01 }, { 1, 1 } }
local K_DROP_ROT = { { 0, -200 }, { 0.55, 0 }, { 1, 0 } }
local K_DROP_OPA = { { 0, 0 }, { 0.55, 1 }, { 1, 1 } }
local K_GALLOP_DY = { { 0, 0 }, { 0.5, -8 }, { 1, 0 } }
local K_GALLOP_ROT = { { 0, 0 }, { 0.5, -60 }, { 1, 0 } }
local K_WIG_ROT = { { 0, 0 }, { 0.25, -50 }, { 0.75, 50 }, { 1, 0 } }

-- perf: every mutator is sent only when its value changes; set_opacity repaints even when
-- unchanged, and finished fades/sparks kept sending (PERF-SEND, PERF-PIXELS; unmeasured).
local function fx_pos(r, x, y)
  if x ~= r.cx or y ~= r.cy then r.cx, r.cy = x, y; r.spr:set_pos(x, y) end
end
local function fx_scale(r, v)
  if v ~= r.csc then r.csc = v; r.spr:set_scale(v) end
end
local function fx_rot(r, v)
  if v ~= r.crot then r.crot = v; r.spr:set_rotation(v) end
end
local function fx_opa(r, v)
  if v ~= r.copa then r.copa = v; r.spr:set_opacity(v) end
end

-- Returns true when the record has reached its final state and can leave FX.
local function fx_step(r, now)
  local e = now - (r.t0 or S.t0) - (r.delay or 0)
  if r.kind == "fade" then                         -- pipup (scale 0 -> 1) on parts wider than 96 px
    local t = math.max(0, math.min(1, e / r.dur))
    fx_opa(r, (255 * ease_out(t)) // 1)
    return t >= 1
  elseif r.kind == "pieceoff" then                 -- @keyframes pieceoff 1 s, delay .35 s
    if e >= 0 then
      local t = math.min(1, e / 1000)
      fx_scale(r, (256 * key(K_PO_SC, t)) // 1)
      fx_rot(r, (key(K_PO_ROT, t)) // 1)
      fx_pos(r, r.x, (r.y + key(K_PO_DY, t)) // 1)
      fx_opa(r, (255 * key(K_PO_OPA, t)) // 1)
      return t >= 1
    end
  elseif r.kind == "pulse" then                    -- @keyframes hintp 1 s
    local t = (e % 1000) / 1000
    fx_scale(r, (256 * key(K_PULSE, t, ease_io)) // 1)
  elseif r.kind == "hover" then                    -- ghost: hover .9 s; nope .45 s after a miss
    local t = (e % 900) / 900
    local dy = key(K_HOVER_DY, t, ease_io) * r.h
    local rot = key(K_HOVER_ROT, t, ease_io)
    local dx = 0
    local m = now - (S.miss_at or 0)
    if S.miss and m < 450 then
      local u = m / 450
      dx = key(K_NOPE_DX, u) * r.w
      rot = key(K_NOPE_ROT, u)
    end
    fx_pos(r, (r.x + dx) // 1, (r.y + dy) // 1)
    fx_rot(r, rot // 1)
  elseif r.kind == "stuck" then                    -- @keyframes drop .75 s, with wig 2.2 s / gallop .55 s
    local dy, sc, rot, op = 0, 1, 0, 255
    if e < 750 then
      local t = math.max(0, e) / 750
      dy = key(K_DROP_DY, t, ease_out)
      sc = key(K_DROP_SC, t, ease_out)
      rot = key(K_DROP_ROT, t, ease_out)
      op = (255 * key(K_DROP_OPA, t)) // 1
    end
    if r.motion == "gallop" then
      local t = (e % 550) / 550
      dy = dy + key(K_GALLOP_DY, t, ease_io)
      rot = rot + key(K_GALLOP_ROT, t, ease_io)
    else
      local t = (e % 2200) / 2200
      rot = rot + key(K_WIG_ROT, t, ease_io)
    end
    fx_pos(r, r.x, (r.y + dy) // 1); fx_scale(r, (256 * sc) // 1); fx_rot(r, rot // 1); fx_opa(r, op)
  elseif r.kind == "spark" then                    -- @keyframes fly .8 s ease-out, delay i * 30 ms
    if e < 0 then fx_opa(r, 0)
    elseif e <= 800 then
      local t = ease_out(e / 800)
      fx_pos(r, (r.x + r.dx * t) // 1, (r.y + r.dy * t) // 1)
      fx_scale(r, (256 * lerp(0.3, 1, t)) // 1)
      fx_opa(r, (255 * (1 - t)) // 1)
    else
      fx_opa(r, 0); hide(r.spr)                    -- perf: a finished spark leaves the screen
      return true
    end
  end
  return false
end

-- Records with r.off (a hidden PLACE pool sprite) are kept but not stepped.
local function fx_tick(now)
  local n, cnt = 0, #FX
  for i = 1, cnt do
    local r = FX[i]
    if r.off or not fx_step(r, now) then n = n + 1; FX[n] = r end
  end
  for i = cnt, n + 1, -1 do FX[i] = nil end
end

-- Big animations (GIF) -------------------------------------------------------------------
local function anim_load(name)
  if AN[name] then return AN[name] end
  local a, err = Anim.new(GIF[name])
  if not a then print("cando: Anim.new failed: " .. name .. " " .. tostring(err)); return nil end
  a:set_visible(false)
  AN[name] = a
  build_labels()
  return a
end

local function anim_free(name)
  if AN[name] then AN[name]:destroy(); AN[name] = nil end
end

local function anims_hide()
  for _, a in pairs(AN) do a:stop(); a:set_visible(false) end
end

-- Scenes ------------------------------------------------------------------------
local enter

local function report(quit)
  if S.reported or not S.st then return end
  S.reported = true
  local secs = (Timer.millis() - S.started) // 1000
  local res = Rules.result_json(S.st, S.placed_now, S.unlocked, secs, quit)
  print("cando: result " .. res)
  if S.params.is_a2a and Engine.report_result then
    local ok, err = Engine.report_result({ event = res })
    if not ok then print("cando: report_result failed " .. tostring(err)) end
  end
end

-- A scene drops the previous one's sprites, adds its own, then texts() puts the labels on top.
local function scene_begin()
  sc_clear(); anims_hide(); clear_texts()
end

local function texts()
  build_labels()
end

local function pocket_mask()
  local m = 0
  for k = 1, 3 do if S.st.said[k] and not S.st.placed[k - 1] then m = m + (1 << (k - 1)) end end
  return m
end

-- The sticker page outside placing: placed stickers ("stuck" one animated), "!" on waiting
-- ones, the pocket, the seal of an earned card.
local function draw_page(hint_name)
  local own = Rules.card_done(S.st) and S.st.mode == "collection"
  bg("page")
  el(own and "label_dat" or "label_dang")
  for k = 1, 3 do
    if S.st.placed[k - 1] and S.stuck_w == k then
      fx(el("placed_" .. k), "stuck", { motion = Rules.WORDS[k].motion })
      local c, a = ART.slot[k], ART.spark
      for i, p in ipairs(BURST) do
        local sp = el("spark", c[1] - a[3] // 2 - a[1], c[2] - a[4] // 2 - a[2])
        fx(sp, "spark", { dx = p[1], dy = p[2], delay = (i - 1) * 30 })
      end
    elseif S.st.placed[k - 1] then el("placed_" .. k)
    elseif S.st.said[k] then el("ready_" .. k)
    else el("sil_" .. k) end
  end
  local m = pocket_mask()
  if m > 0 then el("pocket_" .. m) end
  if own then el("seal") end
  if hint_name then el(hint_name) end
end

-- perf: PLACE is built once per entry and a press or a miss only toggles pooled sprites; the
-- old per-press rebuild (bg 259 KB + ~8 PNG decodes + 7 Text) was a load during play
-- (PERF-LOCK, P23: gap_us/overrun on presses suspected, unmeasured).
local function place_build()
  scene_begin()
  bg("page")
  el("label_dang")
  el("hint_place")
  local w = S.place_q[1]
  PL = { slot = {}, ghost = {} }
  for k = 1, 3 do                                  -- one of placed / sel / hint / sil shows per slot
    local p = {}
    if S.st.placed[k - 1] then p.placed = el("placed_" .. k)
    else
      p.sel = el("sel_" .. k); hide(p.sel)
      if k == w and ART["hint_" .. k] then
        local h = el("hint_" .. k); hide(h)
        p.hint = fx(h, "pulse", { off = true })
      end
      p.sil = el("sil_" .. k); hide(p.sil)
    end
    PL.slot[k] = p
  end
  PL.skip_on = el("skip_on_" .. w); hide(PL.skip_on)
  PL.skip_off = el("skip_off"); hide(PL.skip_off)
  for k = 1, 3 do
    local name = "ghost_" .. w .. "_at_" .. k
    local a = ART[name]
    if a and not S.st.placed[k - 1] then
      local g = el(name); hide(g)
      PL.ghost[k] = fx(g, "hover", { w = a[3], h = a[4], off = true })
    end
  end
  texts()
end

local function vis(spr, on)
  if spr then spr:set_visible(on) end
end

local function place_refresh()
  local w = S.place_q[1]
  for k = 1, 3 do
    local p = PL.slot[k]
    if not p.placed then
      local sel = S.sel == k
      local hint = not sel and S.miss and k == w and p.hint ~= nil
      vis(p.sel, sel)
      if p.hint then vis(p.hint.spr, hint); p.hint.off = not hint end
      vis(p.sil, not sel and not hint)
    end
  end
  local skip = S.sel == "skip"
  vis(PL.skip_on, skip); vis(PL.skip_off, not skip)
  local now = Timer.millis()
  for k = 1, 3 do
    local g = PL.ghost[k]
    if g then
      local on = not skip and S.sel == k
      vis(g.spr, on); g.off = not on
      if on then g.t0 = now end                    -- the hover restarts on every press, as before
    end
  end
  fx_tick(now)                                     -- a re-shown pool sprite gets its pose this frame
  pika(skip and Rules.LINE_SKIP or Rules.place_line(w, S.miss))
end

local function draw_setup()
  scene_begin()
  texts()
  subtitle_off()
  local mode = Rules.MODES[S.setup_mode]
  say_at(tx.title, "THỬ SỔ STICKER", "top", 0, 20, T_GOLD)
  say(tx.r1, (S.setup_row == 1 and "> " or "  ") .. "Chế độ: " .. mode, 60, 100, S.setup_row == 1 and T_GOLD or T_WHITE)
  say(tx.r2, (S.setup_row == 2 and "> " or "  ") .. "Trẻ tự nói: " .. S.setup_n .. "/3 cụm", 60, 140,
      S.setup_row == 2 and T_GOLD or T_WHITE)
  say(tx.r3, "Trái/Phải đổi · Giữa tiếp", 60, 200, T_DIM)
end

local function after_place()
  if S.st.mode == "collection" then enter("BOOKV") else enter("FLIP") end
end

local function start_place(back_to)
  S.place_q = Rules.pending(S.st)
  S.back_to = back_to
  if #S.place_q == 0 then after_place(); return end
  enter(back_to and "PLACE" or "OPENING")
end

enter = function(scene, keep_opt)
  S.scene = scene
  S.t0 = Timer.millis()
  if not keep_opt then S.opt = 1 end
  if scene == "SETUP" then draw_setup()

  elseif scene == "SUMMARY" then
    scene_begin()
    bg("sum"); el("hint_next")
    local delays = { 0, 250, 500 }                   -- .srow pipup .45 s, delays 0 / .25 / .5 s
    for k = 1, 3 do
      local s = el((S.st.said[k] and "row_ok_" or "row_pr_") .. k)
      if s then s:set_opacity(0) end
      fx(s, "fade", { delay = delays[k], dur = 450 })
    end
    texts(); pika(Rules.summary_line(S.st))

  elseif scene == "CARD" then
    if S.unlocked > 0 then sfx("unlock") elseif Rules.ms_count(S.st) > 0 then sfx("piece") end
    scene_begin()
    bg("fb"); el(S.unlocked > 0 and "hint_fb_place" or "hint_fb_next")
    el("card_base")
    el(Rules.ms_count(S.st) > 0 and "st_dang" or "st_chua")
    -- As the demo: bar segments and art pieces count milestones from the left (i < got).
    local n, had = Rules.ms_count(S.st), 0
    for i = 0, 3 do if S.st.ms_have[i] then had = had + 1 end end
    for i = 1, 4 do
      el(i <= n and ("bar_on_" .. i) or ("bar_off_" .. i))
      if i > n then el("piece_" .. i)
      elseif i > had then fx(el("piece_" .. i), "pieceoff", { delay = 350 }) end
    end
    for k = 1, 3 do                                  -- .wt.fresh pipup .5 s, delay .5 s
      if S.st.said[k] then
        for _, n in ipairs({ "tile_open_base_" .. k, "tile_icon_" .. k }) do
          local s = el(n)
          if s then s:set_opacity(0) end
          fx(s, "fade", { delay = 500, dur = 500 })
        end
      else el("tile_prac_" .. k) end
    end
    texts(); pika(Rules.feedback_line(S.st))

  elseif scene == "OPENING" then
    scene_begin()
    local a = anim_load("open")
    if a then a:set_pos(0, 0); a:set_visible(true); a:play() else draw_page() end
    texts(); pika(Rules.LINE_OPENING)

  elseif scene == "PLACE" then
    anim_free("open")
    local w = S.place_q[1]
    local fs = {}
    for k = 1, 3 do if not S.st.placed[k - 1] then fs[#fs + 1] = k end end
    table.sort(fs, function(a, b) return Rules.WORDS[a].x < Rules.WORDS[b].x end)
    S.sel = w
    for _, k in ipairs(fs) do if k ~= w then S.sel = k; break end end
    S.miss = false
    place_build(); place_refresh()

  elseif scene == "STUCK" then
    scene_begin(); draw_page("hint_next")
    texts(); pika(Rules.WORDS[S.stuck_w].cue .. (#S.place_q > 0 and " Còn sticker nữa nè." or ""))

  elseif scene == "LATER" then
    scene_begin(); draw_page("hint_next")
    texts(); pika(Rules.LINE_LATER)

  elseif scene == "FLIP" then
    sfx("flip")
    scene_begin(); S.flipped = false; S.preload = nil
    bg("dark")
    local name = Rules.card_done(S.st) and "flip" or "flip_dang"
    S.gif = anim_load(name)
    if S.gif then
      local g = ART.gif[name]
      S.gif:set_pos(g[1], g[2]); S.gif:set_visible(true); S.gif:play()
    end
    texts(); pika(Rules.LINE_FLIP)

  elseif scene == "MAKEOVER" then
    sfx("card")
    scene_begin()
    S.mk_loop = false
    anim_free("flip")
    local a = anim_load("mk_in")
    if a then a:set_pos(0, 0); a:set_visible(true); a:play() end
    texts(); pika(Rules.LINE_MAKEOVER)

  elseif scene == "INTRO" then
    scene_begin(); bg("intro"); el("hint_intro")
    texts(); pika(Rules.LINE_INTRO)

  elseif scene == "SHELF" then
    scene_begin(); bg("coll"); el("hint_coll")
    local dat = Rules.card_done(S.st)
    el(dat and "coll_card_dat" or "coll_card_dang")
    local pend = #Rules.pending(S.st)
    if pend > 0 then el("coll_badge_" .. pend) end
    el(S.opt == 2 and "chip_thoat_on" or "chip_thoat_off")
    texts()
    if dat then card_date("coll") end
    pika(dat and ("Thẻ " .. Rules.TOPIC .. ": " .. Rules.OWN) or ("Thẻ " .. Rules.TOPIC .. " còn một bí mật nữa đó!"))

  elseif scene == "DETAIL" then
    -- Quay lại sits top right (the bottom right holds the Trang sổ button); the hint moves left of it.
    local cb, hd = ART.chip_back_off, ART.hint_det
    local chip_dx, chip_dy = 480 - 6 - cb[3] - cb[1], 6 - cb[2]
    scene_begin(); bg("det"); el("hint_det", (480 - 6 - cb[3] - 6 - hd[3]) - hd[1], 0)
    local dat = Rules.card_done(S.st)
    el(dat and "det_card_dat" or "det_card_dang")
    local sent = S.st.ms_new[3] or S.st.ms_have[3]   -- the card's sentence opens with "Tạo câu"
    el(sent and "sent_open" or "sent_lock")
    for k = 1, 3 do el((S.st.said[k] and "mini_open_" or "mini_lock_") .. k) end
    el("det_btn_" .. #Rules.pending(S.st))
    el(S.opt == 2 and "chip_back_on" or "chip_back_off", chip_dx, chip_dy)
    texts()
    if dat then card_date("det") end
    pika(sent and ("Câu của thẻ " .. Rules.TOPIC .. " nè. Cậu nói lại thử xem!")
         or ("Thẻ " .. Rules.TOPIC .. ": cậu đã mở " .. Rules.said_count(S.st) .. " sticker từ."))

  elseif scene == "BOOKV" then
    local pend = #Rules.pending(S.st)
    scene_begin(); draw_page(pend > 0 and "hint_book" or nil)
    el((S.opt == (pend > 0 and 2 or 1)) and "chip_back_on" or "chip_back_off")
    texts()
    pika(pend > 0 and "Còn sticker chưa dán. Chọn Dán sticker nhé!" or ("Trang " .. Rules.SCENE .. " của cậu"))

  elseif scene == "DONE" then
    report(false)
    scene_begin(); texts(); subtitle_off()
    say_at(tx.title, "Hẹn gặp lại!", "center", 0, 0, T_GOLD)
  end
end

local function begin(st)
  S.st = st
  S.started = Timer.millis()
  S.unlocked = Rules.said_count(st)
  print("cando: start mode=" .. st.mode .. " source=" .. st.source .. " said=" .. S.unlocked)
  if st.mode == "intro" then enter("INTRO")
  elseif st.mode == "collection" then enter("SHELF")
  else enter("SUMMARY") end
end

local function free_slots()
  local out = {}
  for k = 1, #Rules.WORDS do if not S.st.placed[k - 1] then out[#out + 1] = k end end
  table.sort(out, function(a, b) return Rules.WORDS[a].x < Rules.WORDS[b].x end)
  out[#out + 1] = "skip"
  return out
end

local function place_press(action)
  local fs = free_slots()
  if action == "left" or action == "right" then
    local i = 1
    for j, v in ipairs(fs) do if v == S.sel then i = j end end
    i = (i - 1 + (action == "right" and 1 or -1)) % #fs + 1
    S.sel = fs[i]
    S.miss = false
    place_refresh()
    return
  end
  if action ~= "confirm" then return end
  local w = S.place_q[1]
  if S.sel == "skip" then
    if S.back_to == "BOOKV" then enter("BOOKV") else enter("LATER") end
  elseif S.sel == w then
    S.st.placed[w - 1] = true
    S.placed_now = S.placed_now + 1
    table.remove(S.place_q, 1)
    sfx("place")
    S.stuck_w = w
    enter("STUCK")
  else
    S.miss, S.miss_at = true, Timer.millis()
    sfx("miss")
    place_refresh()
  end
end

local function option_press(action, n, pick)
  if action == "left" or action == "right" then
    S.opt = (S.opt - 1 + (action == "right" and 1 or -1)) % n + 1
    enter(S.scene, true)
  elseif action == "confirm" then
    pick(S.opt)
  end
end

-- Hooks ------------------------------------------------------------------------------
function game_start(params)
  S.params = type(params) == "table" and params or {}
  local s = Sprite.solid(480, 320, C_BG)
  if not s then error("cando: background failed") end
  P.bg = s; put(P.bg, 0, 0)
  P.sub_bar = Sprite.new(A_SUB_BAR, 480, 50)
  for _, m in ipairs(MOODS) do P["face_" .. m] = Sprite.new("assets/face/face_" .. m .. ".rgb565", 76, 50) end
  build_labels()

  local p = type(S.params.params) == "table" and S.params.params or S.params
  local st = Rules.from_input(Pack.data("game"), p)
  if st then begin(st)
  elseif S.params.is_a2a then S.scene = "LOAD"; S.t0 = Timer.millis()
  else enter("SETUP") end
end

function on_pack_data(key, version)
  if key ~= "game" or S.scene ~= "LOAD" then return end
  local p = type(S.params.params) == "table" and S.params.params or S.params
  local st = Rules.from_input(Pack.data("game"), p)
  if st then begin(st) end
end

local handle_input

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  S.sound_this_press = false
  handle_input(action)
  if not S.sound_this_press and not S.v_wait and not (S.vq and #S.vq > 0) then
    if S.cur_sound then Speaker.stop(S.cur_sound) end
    if Speaker.play("click") then S.cur_sound = "click" end
  end
end

handle_input = function(action)
  local sc = S.scene
  if sc == "SETUP" then
    if action == "confirm" then
      if S.setup_row == 1 then S.setup_row = 2; draw_setup()
      else begin(Rules.from_count(Rules.MODES[S.setup_mode], S.setup_n)) end
    else
      local d = action == "right" and 1 or -1
      if S.setup_row == 1 then S.setup_mode = (S.setup_mode - 1 + d) % #Rules.MODES + 1
      else S.setup_n = (S.setup_n + d) % 4 end
      draw_setup()
    end
  elseif sc == "PLACE" then place_press(action)
  elseif sc == "SHELF" then
    option_press(action, 2, function(i) if i == 1 then enter("DETAIL") else enter("DONE") end end)
  elseif sc == "DETAIL" then
    option_press(action, 2, function(i) if i == 1 then enter("BOOKV") else enter("SHELF") end end)
  elseif sc == "BOOKV" then
    local pend = #Rules.pending(S.st) > 0
    option_press(action, pend and 2 or 1, function(i)
      if pend and i == 1 then start_place("BOOKV") else enter("DETAIL") end
    end)
  elseif action ~= "confirm" then return
  elseif sc == "SUMMARY" then enter("CARD")
  elseif sc == "CARD" then start_place(nil)
  elseif sc == "STUCK" then
    if #S.place_q > 0 then enter("PLACE") else after_place() end
  elseif sc == "LATER" then after_place()
  elseif sc == "FLIP" then
    if S.flipped then
      if Rules.card_done(S.st) then enter("MAKEOVER") else enter("DONE") end
    end
  elseif sc == "MAKEOVER" or sc == "INTRO" then enter("DONE")
  end
end

function on_tick(dt_ms)
  local now = Timer.millis()
  voice_tick(now)
  fx_tick(now)
  -- The face GIF stops whenever a big GIF plays; restart it once none does.
  if FACE.anim and S.scene ~= "DONE" and S.scene ~= "SETUP" and not FACE.anim:is_playing() and not big_gif_playing() then
    FACE.anim:play(true); FACE.anim:set_visible(true); hide(P["face_" .. FACE.mood])
  elseif not FACE.anim and FACE.mood and S.scene ~= "DONE" and S.scene ~= "SETUP" and not big_gif_playing() then
    face_show(FACE.mood)
  end
  local e = now - S.t0
  local sc = S.scene
  if sc == "LOAD" then
    if e >= DATA_WAIT_MS then
      print("cando: no game data, defaulting to 3 phrases")
      begin(Rules.from_count("after_lesson", 3))
    end
  elseif sc == "OPENING" then
    if e >= OPENING_MS then enter("PLACE") end
  elseif sc == "FLIP" and S.gif then
    if not S.flipped and not S.gif:is_playing() then
      S.flipped = true
      if Rules.card_done(S.st) then card_date("flip"); S.preload = 1 end
    elseif S.flipped and S.preload then
      -- Static screen: load the makeover animations one per tick, then redraw the texts.
      if S.preload == 1 then anim_load("mk_in"); S.preload = 2
      elseif S.preload == 2 then anim_load("mk_loop"); S.preload = nil end
      pika(Rules.LINE_FLIP)
      card_date("flip")
    end
  elseif sc == "MAKEOVER" and AN.mk_in and not S.mk_loop then
    if not AN.mk_in:is_playing() then
      S.mk_loop = true
      local lp = anim_load("mk_loop")
      anim_free("mk_in")
      if lp then lp:set_pos(0, 0); lp:set_visible(true); lp:play(true) end
      pika(Rules.LINE_MAKEOVER)
      card_date("flip")
    end
  elseif sc == "DONE" then
    if e >= DONE_EXIT_MS then
      S.scene = "GONE"
      Engine.exit("done")
      return
    end
  end
end

function on_sound_end(alias, reason)
  if alias == S.cur_sound then S.cur_sound = nil end
  if alias == S.v_wait then
    S.v_wait = nil
    S.v_ready_at = Timer.millis() + VOICE_GAP_MS
  end
end

-- Menu launches only: in the talk flow HOME ends the game without calling this.
function on_home()
  if S.scene ~= "DONE" and S.scene ~= "GONE" then report(true) end
  return false
end

function game_end() end
