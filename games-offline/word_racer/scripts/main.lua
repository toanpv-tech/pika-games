-- Word Racer — Coin Rush v2
-- Voice-first three-lane runner for Pika Game Engine.
-- Art is rasterized directly from word_racer.html's Canvas bitmap/primitives.

local CFG = require("libs/config")
local Curriculum = require("libs/curriculum")
local GameOverUI = require("libs/gameover_ui")
local I18n = require("libs/i18n")

local SCENE_TITLE = "title"
local SCENE_DRIVE = "drive"
local SCENE_CHECKPOINT = "checkpoint"
local SCENE_OVER = "game_over"

local run = {}
local metrics = { voice_hits = 0 }
local render = {
  ready = false, all_sprites = {}, text_cache = {},
  sprite_cache = {}, text_visible = {}, text_color = {},
}
local voice = { started = false }
local persistent = { best_score = 0, best_coins = 0 }
local is_a2a = false
local pending_start = false
local next_sfx_ms = 0
local IMAGE_ASSET = "assets/image/"

-- GAME OVER footer: "<NHẤN> [star] <ĐỂ CHƠI LẠI>". hud-star.png is 18x18; the
-- two text halves anchor to its left and right at OVER_FOOTER_GAP from the rig
-- centre (half the star plus 6 px of air), which keeps the star's spacing fixed
-- no matter how long the strings are. Y is tuned against the 14 px text band
-- that ends 8 px above the bottom (see OVER_STAR_Y).
--
-- The rig centre sits left of the screen centre because the trailing half is
-- far longer than the leading one ("ĐỂ CHƠI LẠI" vs "NHẤN"); centred on 240 the
-- group reads ~30 px right. One constant serves both languages (vi and en land
-- within 2 px of centre), whereas a per-language value would put the star back
-- in the business of knowing text widths -- exactly what this layout avoids.
--
-- lv_obj_align offsets are measured from the anchored EDGE, not the centre:
-- BOTTOM_RIGHT puts label.right at screen.right + dx (so dx is negative), while
-- BOTTOM_LEFT puts label.left at screen.left + dx. Both are derived from the
-- rig centre here so the pair can never drift apart.
local OVER_SCREEN_W = 480
local OVER_FOOTER_CX = 209                 -- rig centre
local OVER_FOOTER_GAP = 15                 -- half the star + 6 px of air
local OVER_FOOTER_DX_PRE = (OVER_FOOTER_CX - OVER_FOOTER_GAP) - OVER_SCREEN_W
local OVER_FOOTER_DX_POST = OVER_FOOTER_CX + OVER_FOOTER_GAP
local OVER_STAR_X = OVER_FOOTER_CX - 9     -- 9 = half the 18 px sprite
-- 291, not the 296 the text band's geometric centre works out to: the glyphs
-- have no descenders here, so their visual mass sits above that midpoint and a
-- centred star read low next to them.
local OVER_STAR_Y = 293

local PLANETS = {
  { first = 1,  last = 3,  name = "MERCURY", bg = "background.png" },
  { first = 4,  last = 6,  name = "VENUS",   bg = "background.png" },
  { first = 7,  last = 9,  name = "EARTH",   bg = "background.png" },
  { first = 10, last = 12, name = "MARS",    bg = "background.png" },
  { first = 13, last = 15, name = "JUPITER", bg = "background.png" },
  { first = 16, last = 18, name = "SATURN",  bg = "background.png" },
  { first = 19, last = 21, name = "URANUS",  bg = "background.png" },
  { first = 22, last = 24, name = "NEPTUNE", bg = "background.png" },
}

-- LED mirrors voice state, following the proven design used by game 1234:
-- solid blue while listening, solid red on error, and two white blinks when a
-- keyword arrives. The flash sequence then restores the current base color.
local LED = {
  BLUE = { 0, 0, 255 },
  RED = { 255, 0, 0 },
  WHITE = { 255, 255, 255 },
  FLASH_ON_MS = 120,
  FLASH_OFF_MS = 100,
  FLASH_BLINKS = 2,
}
local led_base = nil
local led_flash = nil
local led_flash_i = 0
local led_flash_deadline = 0
local LED_FLASH_SEQ = {}
for _ = 1, LED.FLASH_BLINKS do
  LED_FLASH_SEQ[#LED_FLASH_SEQ + 1] = { ms = LED.FLASH_ON_MS, rgb = LED.WHITE }
  LED_FLASH_SEQ[#LED_FLASH_SEQ + 1] = { ms = LED.FLASH_OFF_MS, rgb = nil }
end

local function now_ms()
  if Timer and Timer.millis then return Timer.millis() end
  return 0
end

-- Ranking.get_result() round-trip budget: back does POST /games/result then
-- GET /games/rank server-side before the rank IPC lands (see ranking_bridge.cpp).
-- If it never lands (offline, BE error) stop polling and keep the placeholder
-- rank instead of calling get_result() forever on the OVER screen.
--
-- KNOWN LIMITATION (needs a back fix, not reachable from Lua): back does not
-- chain those two requests. Application's IPC_CMD_GAME_RESULT handler calls
-- PostGameResult() then FetchGameRank(), and each spawns its OWN task, so the
-- POST and the GET race. The GET usually wins, and the board that comes back
-- is then one round stale -- it does not yet contain the score just reported.
-- Ranking.report() returning true only means the IPC frame went out, so there
-- is nothing here to await. The budget is widened rather than tightened: it
-- costs nothing when the rank lands early, and on a slow link it is the
-- difference between showing a board and showing "loading" forever.
local RANK_POLL_TIMEOUT_MS = 9000

-- Led.* is a MUTATOR-TOLERANT binding: bad args return false, it never raises.
-- So pcall bought nothing here and cost a protected-call frame on the 120 ms
-- flash path.
local function led_rgb(rgb)
  if rgb and Led and Led.set then Led.set(rgb[1], rgb[2], rgb[3]) end
end

local function led_off()
  if Led and Led.off then Led.off() end
end

local function led_apply_base()
  if led_base then led_rgb(led_base) else led_off() end
end

local function led_set_base(rgb)
  led_base = rgb
  if not led_flash then led_apply_base() end
end

local function led_start_flash()
  if not (Led and Led.set) then return end
  led_flash = LED_FLASH_SEQ
  led_flash_i = 0
  led_flash_deadline = 0
end

local function led_stop()
  led_flash = nil
  led_flash_i = 0
  led_flash_deadline = 0
  led_base = nil
  led_off()
end

local function led_tick(t)
  if not led_flash or t < led_flash_deadline then return end
  led_flash_i = led_flash_i + 1
  local step = led_flash[led_flash_i]
  if not step then
    led_flash = nil
    led_apply_base()
    return
  end
  if step.rgb then led_rgb(step.rgb) else led_off() end
  led_flash_deadline = t + step.ms
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Speaker.play returns the neutral value (false) for an unknown alias or a
-- cooldown reject and never raises, so the old pcall wrapper only added a
-- protected-call frame per SFX.
--
-- The engine serves a single channel and rejects any play within 80 ms of the
-- previous one, and that rejection ignored the old `force` flag entirely: a
-- crash landing right after a coin was dropped on the floor. Arbitration is
-- therefore by rank, mirroring the engine's own window. A sound may cut the
-- previous one only if it ranks at least as high; anything the cooldown blocks
-- is either re-armed (see pump_sfx) or discarded by rank.
local sfx_pending_alias, sfx_pending_prio, sfx_pending_until = nil, 0, 0

local function sfx_prio(alias)
  return CFG.SFX_PRIO[alias] or CFG.SFX_PRIO_DEFAULT
end

local function play_sfx(alias)
  if not CFG.SFX_ENABLED then return false end
  local now = now_ms()
  local prio = sfx_prio(alias)

  if now < next_sfx_ms then
    -- Cooldown still closed. Queue it only if it outranks whatever is already
    -- waiting; a stale low-rank entry must never displace a fresh crash.
    if prio >= CFG.SFX_RETRY_MIN_PRIO and prio >= sfx_pending_prio then
      sfx_pending_alias = alias
      sfx_pending_prio  = prio
      sfx_pending_until = now + CFG.SFX_RETRY_MS
    end
    return false
  end

  -- Channel is free. A queued higher-rank sound gets it first, otherwise this
  -- call would preempt the very sound it was told to wait for.
  if sfx_pending_alias and sfx_pending_prio > prio and now < sfx_pending_until then
    local queued = sfx_pending_alias
    sfx_pending_alias, sfx_pending_prio = nil, 0
    if Speaker and Speaker.play and Speaker.play(queued) then
      next_sfx_ms = now + CFG.SFX_COOLDOWN_MS
    end
    return false
  end

  sfx_pending_alias, sfx_pending_prio = nil, 0
  if Speaker and Speaker.play and Speaker.play(alias) then
    next_sfx_ms = now + CFG.SFX_COOLDOWN_MS
    return true
  end
  return false
end

-- Drains a sound the cooldown pushed back. Called once per tick so a blocked
-- crash lands a frame late instead of being lost.
local function pump_sfx(now)
  if not sfx_pending_alias then return end
  if now >= sfx_pending_until then
    sfx_pending_alias, sfx_pending_prio = nil, 0
    return
  end
  if now < next_sfx_ms then return end
  local queued = sfx_pending_alias
  sfx_pending_alias, sfx_pending_prio = nil, 0
  if Speaker and Speaker.play and Speaker.play(queued) then
    next_sfx_ms = now + CFG.SFX_COOLDOWN_MS
  end
end

local function remember_sprite(s)
  if s then
    render.all_sprites[#render.all_sprites + 1] = s
    render.sprite_cache[s] = { visible = false }
  end
  return s
end

local function make_image(path, z)
  if not (Sprite and Sprite.image) then return nil end
  local ok, s, reason = pcall(Sprite.image, path)
  if not ok or not s then
    print("word_racer: Sprite.image failed " .. tostring(path) .. " " .. tostring(reason))
    return nil
  end
  remember_sprite(s)
  s:set_visible(false)
  if z then s:set_z(z) end
  return s
end

local function make_raw(path, w, h, z)
  if not (Sprite and Sprite.new) then return nil end
  local ok, s, reason = pcall(Sprite.new, path, w, h)
  if not ok or not s then
    print("word_racer: Sprite.new failed " .. tostring(path) .. " " .. tostring(reason))
    return nil
  end
  remember_sprite(s)
  s:set_visible(false)
  if z then s:set_z(z) end
  return s
end

local function make_text(value, x, y, color)
  if not (Text and Text.new) then return nil end
  local ok, t = pcall(Text.new, value or "", x or 0, y or 0)
  if not ok or not t then return nil end
  if color then t:set_color(color) end
  t:show(false)
  render.text_visible[t] = false
  render.text_color[t] = color
  return t
end

local function set_text(t, value, visible)
  if not t then return end
  value = tostring(value or "")
  if render.text_cache[t] ~= value then
    t:set(value)
    render.text_cache[t] = value
  end
  local show = visible ~= false
  if render.text_visible[t] ~= show then
    t:show(show)
    render.text_visible[t] = show
  end
end

local function hide_text(t)
  if t and render.text_visible[t] ~= false then
    t:show(false)
    render.text_visible[t] = false
  end
end

local function hide_lane_labels()
  for _, t in ipairs(render.lane_text or {}) do hide_text(t) end
end

-- Text.new returns nil when the 8-slot pool is exhausted, so every handle here
-- may legitimately be absent. Align through this helper rather than calling the
-- method directly: a bare t:align() on a nil handle raises inside on_tick, and
-- the engine treats that as fatal -- it tears the session down mid-play.
local function align_text(t, where, dx, dy)
  if t then t:align(where, dx, dy) end
end

-- The face cache holds 4 entries keyed on the (path, size) PAIR and only evicts
-- faces no live label still references -- and hiding a label does NOT drop its
-- reference. Stay within FONT_PX_* or a set_font silently keeps the old face.
--
-- set_font is a mutator: it returns NOTHING on success and (nil, msg) on
-- failure, so `local ok = t:set_font(...)` reads nil either way. The second
-- return is what distinguishes them. Wrapping it in pcall catches nothing --
-- it does not raise -- which is exactly how the cache overflow stayed silent.
local FONT_VI = "fonts/vi-bold.ttf"
local FONT_PX_SMALL, FONT_PX_UI, FONT_PX_WORD, FONT_PX_HERO = 14, 16, 18, 20

local function set_font(t, size)
  if not t then return end
  local ok, err = t:set_font(FONT_VI, size)
  if ok == nil and err then
    print("word_racer: set_font " .. size .. " failed " .. tostring(err))
  end
end

local function color_text(t, color)
  if t and render.text_color[t] ~= color then
    t:set_color(color)
    render.text_color[t] = color
  end
end

local function set_sprite(s, visible, x, y, opacity)
  if not s then return end
  local c = render.sprite_cache[s]
  if not c then c = {}; render.sprite_cache[s] = c end
  visible = visible == true
  if x and y then
    x, y = math.floor(x), math.floor(y)
    if c.x ~= x or c.y ~= y then
      s:set_pos(x, y)
      c.x, c.y = x, y
    end
  end
  if opacity and c.opacity ~= opacity then s:set_opacity(opacity); c.opacity = opacity end
  if c.visible ~= visible then s:set_visible(visible); c.visible = visible end
end

-- Size comes from the sprite itself (spr:get_size()) rather than a constant, so
-- cropping an asset can never silently desync the hitbox from the artwork. xoff
-- centres the blob on the lane; obstacles differ in height (24 vs 28) after crop.
local function new_slot(kind, sprite)
  local w, h = 0, 0
  if sprite then w, h = sprite:get_size() end
  local size = CFG.ITEM_SIZE[kind]
  if w == 0 and size then w, h = size.w, size.h end
  return {
    kind = kind,
    spr = sprite,
    w = w,
    h = h,
    xoff = math.floor(w / 2),
    yoff = size and size.yoff or 0,
    active = false,
    lane = 1,
    y = -40,
    passed = false,
  }
end

local function build_render_objects()
  if render.ready then return true end
  render.road_bg = make_image(IMAGE_ASSET .. PLANETS[1].bg, 0)
  render.bg_name = PLANETS[1].bg
  render.over_bg = make_image(IMAGE_ASSET .. "game-over.png", 1)
  render.cover = make_image(IMAGE_ASSET .. "cover.png", 1)
  render.start_star = make_image(CFG.ASSET .. "start-star.png", 24)
  render.player = make_image(CFG.ASSET .. "pika-player.png", 20)
  render.player_shield = make_image(CFG.ASSET .. "pika-player-shield.png", 20)
  render.hud_planet = make_image(CFG.ASSET .. "hud-planet.png", 24)
  render.hud_star = make_image(CFG.ASSET .. "hud-star.png", 24)
  render.hud_hearts = {}
  for i = 1, CFG.MAX_LIVES do
    render.hud_hearts[i] = make_image(CFG.ASSET .. "hud-heart.png", 24)
  end
  render.obstacles = {}
  local obs_art = {
    "3_1_patrol_disc.png", "3_2_heavy_cargo_disc.png",
    "3_3_mini_scout_disc.png", "3_4_double_ring_disc.png",
    "3_5_segmented_disc.png", "3_6_gyroscope_disc.png",
    "3_7_green_dome_disc.png", "3_8_purple_dome_disc.png",
  }
  for i = 1, CFG.OBS_POOL do
    local art = obs_art[((i - 1) % #obs_art) + 1]
    render.obstacles[i] = new_slot("obstacle", make_image(CFG.ASSET .. art, 12))
  end

  render.coins = {}
  for i = 1, CFG.COIN_POOL do
    render.coins[i] = new_slot("coin", make_image(CFG.ASSET .. "4_1_small_star.png", 10))
  end
  render.crystal = new_slot("crystal", make_image(CFG.ASSET .. "4_2_energy_crystal.png", 11))
  render.magnet = new_slot("magnet", make_image(CFG.ASSET .. "4_3_asteroid_magnet.png", 11))
  render.shooting_star = new_slot("shooting_star", make_image(CFG.ASSET .. "4_4_shooting_star.png", 11))
  render.armor = new_slot("armor", make_image(CFG.ASSET .. "4_5_armor_shield.png", 11))
  render.heart = new_slot("heart", make_image(CFG.ASSET .. "4_6_heart.png", 11))
  render.hud = make_text("", 6, 8, 0xFFD24A)
  render.lane_text = {
    make_text("", 102, 38, 0xFFFFFF),
    make_text("", 198, 38, 0xFFFFFF),
    make_text("", 294, 38, 0xFFFFFF),
  }
  render.message = make_text("", 0, 0, 0xFFFFFF)
  render.voice = make_text("", 4, 301, 0x7FD0FF)
  render.boss = make_text("", 0, 258, 0xFFE600)
  render.footer = make_text("", 0, 286, 0xFFFFFF)

  -- Firmware-tested Vietnamese Bold keeps base glyph metrics identical between
  -- e/ê and o/ô in LVGL Tiny TTF. Compact UI at 16 px, vocabulary and feedback
  -- at 18 px.
  local compact_labels = { render.hud, render.voice, render.boss, render.footer }
  for _, label in ipairs(compact_labels) do
    set_font(label, FONT_PX_UI)
  end
  set_font(render.message, FONT_PX_WORD)
  for _, label in ipairs(render.lane_text) do
    set_font(label, FONT_PX_WORD)
  end

  if render.message then render.message:align("center", 0, -28) end
  if render.boss then render.boss:align("center", 0, 90) end
  if render.footer then render.footer:align("bottom", 0, -5) end

  render.ready = true
  return true
end

local function hide_slot(slot)
  slot.active = false
  slot.passed = false
  set_sprite(slot.spr, false)
end

local function clear_items()
  for _, slot in ipairs(render.obstacles or {}) do hide_slot(slot) end
  for _, slot in ipairs(render.coins or {}) do hide_slot(slot) end
  if render.crystal then hide_slot(render.crystal) end
  if render.magnet then hide_slot(render.magnet) end
  if render.shooting_star then hide_slot(render.shooting_star) end
  if render.armor then hide_slot(render.armor) end
  if render.heart then hide_slot(render.heart) end
end

local function hide_gameplay_text()
  hide_text(render.boss)
  hide_text(render.footer)
end

local function current_speed()
  local base = CFG.BASE_SPEED + CFG.SPEED_PER_ROUND * (run.round - 1)
  local ramp = math.min(CFG.SPEED_RAMP_MAX,
    (run.play_ms / 1000) / CFG.SPEED_RAMP_SEC * CFG.SPEED_RAMP_MAX)
  return base * (1 + ramp)
end

local function combo_multiplier()
  return math.min(3, 1 + math.floor(run.streak / 4))
end

local function set_message(value, duration_ms, color)
  run.message = value or ""
  run.message_until = duration_ms and (now_ms() + duration_ms) or 0
  color_text(render.message, color or 0xFFFFFF)
end

local function voice_stop()
  if voice.started and Voice and Voice.stop then pcall(Voice.stop) end
  voice.started = false
  led_stop()
end

local function voice_start()
  voice_stop()
  if not (Voice and Voice.set_keywords and Voice.start) then
    led_set_base(LED.RED)
    return false
  end

  local keywords = Curriculum.build_keywords(run.topic)
  local ok, reason = Voice.set_keywords(keywords, CFG.VOICE_SENSITIVITY)
  if not ok then
    print("word_racer: set_keywords failed " .. tostring(reason))
    led_set_base(LED.RED)
    return false
  end
  ok, reason = Voice.start()
  if not ok then
    print("word_racer: Voice.start failed " .. tostring(reason))
    led_set_base(LED.RED)
    return false
  end
  voice.started = true
  led_set_base(LED.BLUE)
  return true
end

local function shuffled_three(words)
  local a = { words[1], words[2], words[3] }
  for i = #a, 2, -1 do
    local j = math.random(i)
    a[i], a[j] = a[j], a[i]
  end
  return a
end

local function planet_for_round(round)
  for i, planet in ipairs(PLANETS) do
    if round >= planet.first and round <= planet.last then return planet, i end
  end
  return PLANETS[#PLANETS], #PLANETS
end

local function set_planet_background(planet, planet_idx)
  if render.planet_idx == planet_idx then return end
  if render.bg_name == planet.bg then
    render.planet_idx = planet_idx
    return
  end
  if render.road_bg and render.road_bg.destroy then pcall(function() render.road_bg:destroy() end) end
  render.road_bg = make_image(IMAGE_ASSET .. planet.bg, 0)
  render.bg_name = planet.bg
  render.planet_idx = planet_idx
end

local function setup_round()
  if render.message then render.message:align("center", 0, -40) end
  run.lane = 2
  run.car_x = CFG.LANE_X[2]
  run.player_y = CFG.CAR_Y
  run.player_opacity = 255
  run.flight_bank_dir = 0
  run.flight_bank_until = 0
  local topic, topic_idx = Curriculum.topic(run.round, 1)
  run.topic = topic
  run.topic_idx = topic_idx
  run.lane_words = shuffled_three(topic.words)
  local sentence_word = topic.words[math.random(4, 6)]
  run.checkpoint_phrase = Curriculum.boss_phrase(topic, sentence_word)
  run.checkpoint_display = string.upper(topic.pattern .. " " .. sentence_word)
  run.wave_count = 0
  run.round_wave_target = CFG.ROUND_WAVES_MIN + math.random(0, CFG.ROUND_WAVES_RAND - 1)
  run.next_spawn_ms = now_ms() + 800
  run.scene = SCENE_DRIVE
  run.play_layout_dirty = true
  hide_gameplay_text()
  clear_items()
  local planet, planet_idx = planet_for_round(run.round)
  local changed_planet = run.planet_idx ~= planet_idx
  run.planet_idx = planet_idx
  set_planet_background(planet, planet_idx)
  if changed_planet then
    set_message(I18n.t("flying_to") .. I18n.planet(planet.name) .. "...", 1600)
  else
    set_message(I18n.t("round") .. run.round .. " - " .. string.upper(I18n.topic(topic.name)), 1400)
  end
  run.hud_dirty = true
  run.lanes_dirty = true
  -- The web demo rotates all 24 topics. Keep the active KWS vocabulary at six
  -- entries by closing and reopening voice on each round boundary.
  run.voice_available = voice_start()
end

local function build_checkpoint_loot()
  local candidates = {
    { kind = "star", slot = render.coins[1] },
    { kind = "crystal", slot = render.crystal },
    { kind = "heart", slot = render.heart },
    { kind = "armor", slot = render.armor },
  }
  for i = #candidates, 2, -1 do
    local j = math.random(i)
    candidates[i], candidates[j] = candidates[j], candidates[i]
  end
  run.checkpoint_loot = candidates
  run.checkpoint_loot_n = math.random(3, 4)
  local formation_lanes = { 1, 2, 3, 2 }
  local drop_span = CFG.CAR_Y - CFG.PORTAL_Y
  for i = 1, #candidates do
    local loot = candidates[i]
    loot.active = i <= run.checkpoint_loot_n
    loot.lane = formation_lanes[i]
    -- Stagger the convoy by more than the tallest reward (31 px). This keeps
    -- sprites separate even while all three trajectories converge at the portal.
    loot.trail_y = 66 + (i - 1) * 36
    loot.drop_y = CFG.PORTAL_Y + drop_span * i / (run.checkpoint_loot_n + 1)
    if loot.slot and loot.slot.spr then set_sprite(loot.slot.spr, false) end
  end
end

local function enter_checkpoint()
  run.scene = SCENE_CHECKPOINT
  run.round_waiting = false
  run.checkpoint_solved = false
  run.checkpoint_y = CFG.PORTAL_Y
  build_checkpoint_loot()
  hide_lane_labels()
  if not run.voice_available then
    set_message(I18n.t("voice_unavailable"), 0, 0xFFB347)
  end
  play_sfx("boss")
end

local function collect_checkpoint_loot()
  for i = 1, run.checkpoint_loot_n do
    local loot = run.checkpoint_loot[i]
    if loot.active then
      loot.active = false
      if loot.slot and loot.slot.spr then set_sprite(loot.slot.spr, false) end
      if loot.kind == "star" then
        run.coins = run.coins + 1
        run.score = run.score + combo_multiplier()
      elseif loot.kind == "crystal" then
        run.coins = run.coins + 3
        run.score = run.score + 15 * combo_multiplier()
      elseif loot.kind == "heart" then
        if run.lives < CFG.MAX_LIVES then
          run.lives = run.lives + 1
        else
          run.score = run.score + 15 * combo_multiplier()
        end
      elseif loot.kind == "armor" then
        if run.shield then
          run.score = run.score + 15 * combo_multiplier()
        else
          run.shield = true
        end
      end
    end
  end
end

local function complete_checkpoint()
  if run.checkpoint_solved then return end
  run.checkpoint_solved = true
  metrics.voice_hits = metrics.voice_hits + 1
  run.streak = run.streak + 1
  collect_checkpoint_loot()
  run.score = run.score + 50 * run.round * combo_multiplier()
  run.hud_dirty = true
  play_sfx("smash")
  set_message(I18n.t("sentence_correct"), 900, 0x7CFFCB)
  run.departure_from_x = run.car_x
  run.departure_started_at = now_ms()
  run.pending_round_at = run.departure_started_at + CFG.DEPARTURE_MS
end

local function resume_round_after_checkpoint()
  for i = 1, run.checkpoint_loot_n do
    local loot = run.checkpoint_loot[i]
    if loot.slot and loot.slot.spr then set_sprite(loot.slot.spr, false) end
  end
  run.scene = SCENE_DRIVE
  run.round_waiting = false
  run.wave_count = 0
  run.round_wave_target = CFG.CHECKPOINT_RETRY_WAVES_MIN
    + math.random(0, CFG.CHECKPOINT_RETRY_WAVES_RAND - 1)
  run.next_spawn_ms = now_ms() + 800
  run.play_layout_dirty = true
  run.hud_dirty = true
  run.lanes_dirty = true
  run.checkpoint_loot = nil
  run.checkpoint_loot_n = 0
  hide_gameplay_text()
  if render.message then render.message:align("center", 0, -40) end
end

local function show_title()
  run.scene = SCENE_TITLE
  clear_items()
  hide_gameplay_text()
  -- Release the GAME OVER footer's borrowed half (hide_lane_labels below
  -- clears the label itself); the title screen owns these labels next.
  render.footer_post = nil
  set_sprite(render.road_bg, false)
  set_sprite(render.over_bg, false)
  set_sprite(render.cover, true, 0, 0)
  set_sprite(render.start_star, true, 208, 128, 255)
  set_sprite(render.player, false)
  set_sprite(render.player_shield, false)
  set_sprite(render.hud_planet, false)
  set_sprite(render.hud_star, false)
  for _, heart in ipairs(render.hud_hearts or {}) do set_sprite(heart, false) end
  hide_text(render.hud)
  hide_lane_labels()
  hide_text(render.voice)
  hide_text(render.message)
  hide_text(render.boss)
  set_font(render.footer, FONT_PX_HERO)
  set_font(render.boss, FONT_PX_HERO)
  set_font(render.voice, FONT_PX_HERO)
  set_font(render.message, FONT_PX_HERO)
  set_text(render.footer, I18n.t("start_left"), true)
  set_text(render.boss, I18n.t("start_right"), true)
  set_text(render.voice, I18n.t("start_left"), true)
  set_text(render.message, I18n.t("start_right"), true)
  color_text(render.footer, 0xFFE66D)
  color_text(render.boss, 0xFFE66D)
  color_text(render.voice, 0xFFE66D)
  color_text(render.message, 0xFFE66D)
  if render.footer then render.footer:align("center", -100, 0) end
  if render.boss then render.boss:align("center", 95, 0) end
  if render.voice then render.voice:align("center", -99, 0) end
  if render.message then render.message:align("center", 96, 0) end
  run.title_blink = true
  run.title_started_at = now_ms()
end

local function start_run()
  if not render.ready then pending_start = true; return end
  pending_start = false
  set_sprite(render.over_bg, false)
  set_font(render.footer, FONT_PX_UI)
  set_font(render.boss, FONT_PX_UI)
  set_font(render.voice, FONT_PX_SMALL)
  set_font(render.hud, FONT_PX_SMALL)
  set_font(render.message, FONT_PX_WORD)
  -- lane_text[1] doubled as the GAME OVER footer's second half at 14 px; the
  -- gameplay redraw restores its text and anchor via lanes_dirty but not its
  -- font, so hand the lane vocabulary back its 18 px face here.
  if render.footer_post then
    set_font(render.footer_post, FONT_PX_WORD)
    hide_text(render.footer_post)
    render.footer_post = nil
  end
  hide_text(render.voice)
  hide_text(render.message)
  -- Drain any rank result still latched from the previous round: back's
  -- FetchGameRank runs on its own fire-and-forget task per Ranking.report()
  -- call and does not cancel an earlier in-flight fetch, so a reply slower
  -- than RANK_POLL_TIMEOUT_MS can land after this round already gave up
  -- polling. Left unconsumed, the next round's first get_result() would read
  -- it and show the previous round's rank under this round's score.
  if Ranking and Ranking.get_result then Ranking.get_result() end
  if render.cover then
    pcall(function() render.cover:destroy() end)
    render.sprite_cache[render.cover] = nil
    render.cover = nil
  end
  set_sprite(render.start_star, false)
  set_sprite(render.hud_star, false)
  clear_items()
  hide_gameplay_text()
  metrics.voice_hits = 0
  run = {
    scene = SCENE_DRIVE,
    score = 0,
    coins = 0,
    round = 1,
    lives = CFG.MAX_LIVES,
    streak = 0,
    lane = 2,
    car_x = CFG.LANE_X[2],
    play_ms = 0,
    invincible_until = 0,
    magnet_until = 0,
    shield = false,
    message = "",
    message_until = 0,
    hud_dirty = true,
    play_layout_dirty = true,
    hud_next_ms = 0,
    last_tick_ms = now_ms(),
    exit_at = 0,
  }
  if render.message then render.message:align("center", 0, -40) end
  if render.footer then render.footer:align("bottom", 0, -5) end
  setup_round()
  play_sfx("start")
end

local function first_free(pool)
  for _, slot in ipairs(pool) do
    if not slot.active then return slot end
  end
  return nil
end

local function random_free(pool)
  local free = {}
  for _, slot in ipairs(pool) do
    if not slot.active then free[#free + 1] = slot end
  end
  if #free == 0 then return nil end
  return free[math.random(#free)]
end

-- Return a spawn position above every active item in the same lane. Consecutive
-- web-demo waves can otherwise overlap: at 58 px/s a trailing coin may still
-- be near y=-46 when the next item is inserted at y=-30 (sprites are 30 px
-- high). A 40 px pitch preserves the demo's coin-trail spacing plus 10 px air.
local function safe_spawn_y(lane, desired_y)
  local top_y = nil
  for i = 1, #render.obstacles do
    local slot = render.obstacles[i]
    if slot.active and slot.lane == lane and (not top_y or slot.y < top_y) then
      top_y = slot.y
    end
  end
  for i = 1, #render.coins do
    local slot = render.coins[i]
    if slot.active and slot.lane == lane and (not top_y or slot.y < top_y) then
      top_y = slot.y
    end
  end
  local slot = render.crystal
  if slot.active and slot.lane == lane and (not top_y or slot.y < top_y) then top_y = slot.y end
  slot = render.magnet
  if slot.active and slot.lane == lane and (not top_y or slot.y < top_y) then top_y = slot.y end
  slot = render.shooting_star
  if slot.active and slot.lane == lane and (not top_y or slot.y < top_y) then top_y = slot.y end
  slot = render.armor
  if slot.active and slot.lane == lane and (not top_y or slot.y < top_y) then top_y = slot.y end
  slot = render.heart
  if slot.active and slot.lane == lane and (not top_y or slot.y < top_y) then top_y = slot.y end
  if top_y then return math.min(desired_y, top_y - (CFG.ITEM_SPAWN_H + 10)) end
  return desired_y
end

local function lane_x_at(lane, y)
  -- Geometry sampled from the four cyan boundaries in background.png. Their
  -- lane midlines converge around (239,106) and spread by ~0.82 px per y pixel.
  -- Using the measured midlines keeps outer-lane sprites clear of both borders.
  local depth = math.max(0, y - CFG.LANE_FOCUS_Y)
  return CFG.LANE_FOCUS_X + (lane - 2) * depth * CFG.LANE_SPREAD_PER_Y
end

local function portal_opacity(y)
  local progress = clamp((y - CFG.PORTAL_Y) / 45, 0, 1)
  return math.floor(255 * progress)
end

local function activate(slot, lane, y)
  if not slot then return false end
  y = safe_spawn_y(lane, y)
  slot.active = true
  slot.lane = lane
  slot.y = y
  slot.passed = false
  if slot.spr then
    local x = lane_x_at(lane, y + slot.h * 0.5) - slot.xoff
    local opacity = portal_opacity(y + slot.h * 0.5)
    set_sprite(slot.spr, opacity > 0, x, y + slot.yoff, opacity)
  end
  return true
end

local function spawn_wave()
  if run.wave_count >= run.round_wave_target then
    run.round_waiting = true
    set_message(I18n.t("round_complete"), 1000)
    return
  end
  run.wave_count = run.wave_count + 1

  local lanes = { 1, 2, 3 }
  -- Robot profile: one obstacle per wave. Difficulty still rises through
  -- speed/round, without increasing simultaneous LVGL movers over time.
  local pick = math.random(#lanes)
  local obstacle_lane = table.remove(lanes, pick)
  activate(random_free(render.obstacles), obstacle_lane, CFG.PORTAL_Y)

  local candidates = {}
  for _, lane in ipairs(lanes) do
    if lane ~= run.lane then candidates[#candidates + 1] = lane end
  end
  if #candidates == 0 then candidates = lanes end
  if #candidates == 0 then return end
  local coin_lane = candidates[math.random(#candidates)]

  local reward_roll = math.random()
  local bonus = nil
  if reward_roll < 0.05 then bonus = render.crystal
  elseif reward_roll < 0.09 then bonus = render.magnet
  elseif reward_roll < 0.12 then bonus = render.shooting_star
  elseif reward_roll < 0.16 then bonus = render.armor
  elseif reward_roll < 0.19 then bonus = render.heart end

  -- Normal waves contain one star 65% of the time and a two-star trail 35% of
  -- the time. A special pickup always leads one star, preserving a clear
  -- reward path without making every normal wave look duplicated.
  if bonus and not bonus.active then
    activate(bonus, coin_lane, CFG.PORTAL_Y)
    local coin = first_free(render.coins)
    if coin then activate(coin, coin_lane, CFG.PORTAL_Y - 40) end
  else
    local star_count = math.random() < 0.65 and 1 or 2
    for i = 0, star_count - 1 do
      local coin = first_free(render.coins)
      if coin then activate(coin, coin_lane, CFG.PORTAL_Y - i * 40) end
    end
  end
end

local function collect_coin(slot)
  hide_slot(slot)
  run.coins = run.coins + 1
  run.score = run.score + 1
  run.hud_dirty = true
  play_sfx("coin")
end

local function lose_life(trigger)
  local now = now_ms()
  if now < run.invincible_until then return end
  run.invincible_until = now + CFG.INVINCIBLE_MS
  run.streak = 0
  run.lives = run.lives - 1
  run.hud_dirty = true
  set_message(I18n.t("life_lost"), 900, 0xE53935)
  play_sfx("crash")
end

local function finish_game(won)
  if run.scene == SCENE_OVER then return end
  run.scene = SCENE_OVER
  voice_stop()
  clear_items()
  hide_gameplay_text()
  local is_coin_record = run.coins >= persistent.best_coins
  persistent.best_score = math.max(persistent.best_score, math.floor(run.score))
  persistent.best_coins = math.max(persistent.best_coins, run.coins)
  play_sfx(is_coin_record and "record" or "over")
  set_sprite(render.road_bg, false)
  set_sprite(render.over_bg, true, 0, 0, 255)
  set_sprite(render.player, false)
  set_sprite(render.player_shield, false)
  set_sprite(render.hud_planet, false)
  set_sprite(render.hud_star, false)
  for _, heart in ipairs(render.hud_hearts or {}) do set_sprite(heart, false) end

  run.won = won == true
  -- Hero score was 22 px and the board line 15 px, but by this scene all four
  -- cache slots are pinned by live labels, so both requests failed and rendered
  -- at whatever face the label already held. Reusing the sizes already resident
  -- keeps the whole pack inside 4 distinct faces and makes them render at all.
  set_font(render.message, FONT_PX_HERO)
  set_font(render.hud, FONT_PX_HERO)
  set_font(render.voice, FONT_PX_SMALL)
  set_font(render.boss, FONT_PX_UI)
  set_font(render.footer, FONT_PX_SMALL)

  set_text(render.message, run.won and I18n.t("journey_complete") or GameOverUI.title(), true)
  color_text(render.message, run.won and CFG.COL_WIN_TITLE or CFG.COL_OVER_TITLE)
  if render.message then render.message:align("top", 0, 8) end
  set_text(render.hud, GameOverUI.score_card(math.floor(run.score)), true)
  color_text(render.hud, 0xFFD85A)
  if render.hud then render.hud:align("top", 0, 78) end
  set_text(render.voice, GameOverUI.rank_line(nil), true)
  color_text(render.voice, 0x65F4FF)
  if render.voice then render.voice:align("top", 0, 106) end
  set_text(render.boss, GameOverUI.pending_board(), true)
  color_text(render.boss, 0xF4F7FF)
  if render.boss then render.boss:align("top", 0, 140) end
  -- Footer reads "<pre> [star] <post>" with the real star sprite standing in
  -- for the button name. The two halves anchor to OPPOSITE edges so the gap
  -- they leave is fixed: bottom_right pins the left half's right edge, and
  -- bottom_left pins the right half's left edge, both measured from the screen
  -- centre. Only their outer ends move when vi/en text lengths differ, so the
  -- sprite between them never needs a width the engine cannot report.
  -- lane_text[1] is idle on this screen, so borrowing it for the second half
  -- costs no extra Text slot. Its two siblings are hidden here rather than via
  -- hide_lane_labels(), which would also blank the half just assigned.
  for i = 2, #(render.lane_text or {}) do hide_text(render.lane_text[i]) end
  render.footer_post = render.lane_text and render.lane_text[1]
  set_font(render.footer_post, FONT_PX_SMALL)
  set_text(render.footer, GameOverUI.footer_pre(), true)
  color_text(render.footer, 0xFFD85A)
  if render.footer then
    render.footer:align("bottom_right", OVER_FOOTER_DX_PRE, -8)
  end
  set_text(render.footer_post, GameOverUI.footer_post(), true)
  color_text(render.footer_post, 0xFFD85A)
  if render.footer_post then
    render.footer_post:align("bottom_left", OVER_FOOTER_DX_POST, -8)
  end
  set_sprite(render.hud_star, true, OVER_STAR_X, OVER_STAR_Y, 255)

  -- Ranking.report is called on every round end regardless of launch mode
  -- (A2A or menu) - it is the only path that reaches the Robot Game
  -- leaderboard, independent of Engine.report_result below. Only start
  -- polling get_result() if the report actually went out (send_failed /
  -- bad_score / payload_too_big all return false, see bind_ranking.c) - back
  -- never kicks off FetchGameRank without a report landing first, so polling
  -- on a failed report would just burn the full timeout waiting on a rank
  -- refresh that was never triggered.
  local reported = false
  if Ranking and Ranking.report then
    local ok, sent = pcall(Ranking.report, { score = run.score })
    reported = ok and sent == true
  end
  run.rank_shown = not reported
  run.rank_poll_deadline = reported and (now_ms() + RANK_POLL_TIMEOUT_MS) or 0

  if is_a2a and Engine and Engine.report_result then
    local event = string.format("over:s%d:c%d:r%d:v%d",
      math.floor(run.score), run.coins, run.round, metrics.voice_hits)
    pcall(Engine.report_result, { event = event })
    run.exit_at = now_ms() + CFG.A2A_EXIT_HOLD_MS
  end
end

local function move_to_lane(lane, from_voice)
  lane = clamp(lane, 1, 3)
  if from_voice then
    metrics.voice_hits = metrics.voice_hits + 1
  end
  if lane == run.lane then return end
  run.flight_bank_dir = lane > run.lane and 1 or -1
  run.flight_bank_until = now_ms() + CFG.FLIGHT_BANK_MS
  run.lane = lane
  run.streak = run.streak + 1
  run.hud_dirty = true
  run.lanes_dirty = true
  play_sfx("lane")
end

local function hit_obstacle(slot)
  hide_slot(slot)
  if run.shield then
    run.shield = false
    run.invincible_until = now_ms() + CFG.INVINCIBLE_MS
    set_message(I18n.t("shield_used"), 700)
    play_sfx("shield")
  else
    lose_life("obstacle")
  end
end

local function update_slot(slot, dt_sec, speed, now)
  if not slot.active then return end
  -- Perspective pacing: distant objects linger near the portal, then
  -- accelerate smoothly as they approach PIKA. This makes the road read much
  -- longer without changing round difficulty or the collision window.
  local travel = CFG.CAR_Y + CFG.CAR_H * 0.5 - CFG.PORTAL_Y
  local depth = clamp((slot.y + slot.h * 0.5 - CFG.PORTAL_Y) / travel, 0, 1)
  local eased_depth = depth * depth * (3 - 2 * depth)
  local perspective_k = CFG.FAR_SPEED_K + (1 - CFG.FAR_SPEED_K) * eased_depth
  slot.y = slot.y + speed * perspective_k * dt_sec
  local slot_x = lane_x_at(slot.lane, slot.y + slot.h * 0.5) - slot.xoff
  local opacity = portal_opacity(slot.y + slot.h * 0.5)
  set_sprite(slot.spr, opacity > 0, slot_x, slot.y + slot.yoff, opacity)

  if slot.kind == "coin" and now < run.magnet_until and
      slot.y >= CFG.CAR_Y - 30 and slot.y <= CFG.CAR_Y + 60 then
    collect_coin(slot)
    return
  end

  -- Use the actual interpolated ship position rather than its selected lane.
  -- This keeps collision aligned with PIKA while it is visibly changing lanes.
  local art_top = slot.y + slot.yoff
  local scale = CFG.COLLISION_SCALE[slot.kind] or 1
  local grace = slot.kind == "obstacle" and CFG.OBSTACLE_GRACE or CFG.PICKUP_GRACE
  local object_w = math.max(1, slot.w * scale + grace * 2)
  local object_h = math.max(1, slot.h * scale + grace * 2)
  local object_cx = slot_x + slot.xoff
  local object_cy = art_top + slot.h * 0.5
  local object_left = object_cx - object_w * 0.5
  local object_right = object_cx + object_w * 0.5
  local object_top = object_cy - object_h * 0.5
  local object_bottom = object_cy + object_h * 0.5

  local shield_expand = slot.kind == "obstacle" and run.shield
    and CFG.SHIELD_HITBOX_EXPAND or 0
  local pika_left = run.car_x - CFG.PIKA_HITBOX_W * 0.5 - shield_expand
  local pika_right = run.car_x + CFG.PIKA_HITBOX_W * 0.5 + shield_expand
  local pika_top = CFG.CAR_Y + CFG.PIKA_HITBOX_YOFF - shield_expand
  local pika_bottom = pika_top + CFG.PIKA_HITBOX_H + shield_expand * 2
  local touching = object_right > pika_left and object_left < pika_right
    and object_bottom > pika_top and object_top < pika_bottom

  if touching then
    if slot.kind == "obstacle" then
      if now >= run.invincible_until then hit_obstacle(slot) end
    elseif slot.kind == "coin" then
      collect_coin(slot)
    elseif slot.kind == "crystal" then
      hide_slot(slot)
      run.coins = run.coins + 3
      run.score = run.score + 15 * combo_multiplier()
      run.hud_dirty = true
      set_message(I18n.t("crystal"), 800)
      play_sfx("powerup")
    elseif slot.kind == "magnet" then
      hide_slot(slot)
      run.magnet_until = now + CFG.MAGNET_MS
      set_message(I18n.t("magnet"), 800)
      play_sfx("powerup")
    elseif slot.kind == "shooting_star" then
      hide_slot(slot)
      run.coins = run.coins + 5
      run.score = run.score + 25 * combo_multiplier()
      run.hud_dirty = true
      set_message(I18n.t("shooting_star"), 800)
      play_sfx("powerup")
    elseif slot.kind == "armor" then
      hide_slot(slot)
      run.shield = true
      run.hud_dirty = true
      set_message(I18n.t("shield_ready"), 800)
      play_sfx("powerup")
    elseif slot.kind == "heart" then
      hide_slot(slot)
      if run.lives < CFG.MAX_LIVES then
        run.lives = run.lives + 1
        set_message(I18n.t("heart"), 800)
      else
        run.score = run.score + 15 * combo_multiplier()
        set_message(I18n.t("heart_full"), 800)
      end
      run.hud_dirty = true
      play_sfx("powerup")
    end
    return
  end

  if slot.kind == "obstacle" and not slot.passed and slot.y > CFG.CAR_Y + CFG.CAR_H then
    slot.passed = true
    run.score = run.score + 6 * run.round * combo_multiplier()
    run.streak = run.streak + 1
    run.hud_dirty = true
  end
  if slot.y > CFG.SCREEN_H + 40 then hide_slot(slot) end
end

local function update_items(dt_sec, speed, now)
  for i = 1, #render.obstacles do update_slot(render.obstacles[i], dt_sec, speed, now) end
  for i = 1, #render.coins do update_slot(render.coins[i], dt_sec, speed, now) end
  update_slot(render.crystal, dt_sec, speed, now)
  update_slot(render.magnet, dt_sec, speed, now)
  update_slot(render.shooting_star, dt_sec, speed, now)
  update_slot(render.armor, dt_sec, speed, now)
  update_slot(render.heart, dt_sec, speed, now)
end

local function update_drive(dt_ms, now)
  local dt_sec = dt_ms * 0.001
  run.play_ms = run.play_ms + dt_ms
  local speed = current_speed()
  run.score = run.score + speed * dt_sec * 0.02
  local target_x = CFG.LANE_X[run.lane]
  run.car_x = run.car_x + (target_x - run.car_x) * math.min(1, dt_ms / 80)
  if not run.pending_round_at and not run.round_waiting and now >= run.next_spawn_ms then
    spawn_wave()
    local dynamic_max = math.max(CFG.WAVE_MIN_MS,
      CFG.WAVE_MAX_MS - (run.play_ms / 1000) * 4)
    run.next_spawn_ms = now + math.random(CFG.WAVE_MIN_MS, math.floor(dynamic_max))
  end
  update_items(dt_sec, speed, now)
  if run.round_waiting then
    clear_items()
    enter_checkpoint()
  end
end

local function update_checkpoint(dt_ms, now)
  if run.checkpoint_solved then
    local elapsed = now - run.departure_started_at
    local progress = clamp(elapsed / CFG.DEPARTURE_MS, 0, 1)
    local eased = progress * progress * (3 - 2 * progress)
    run.car_x = run.departure_from_x
      + (CFG.LANE_FOCUS_X - run.departure_from_x) * eased
    run.player_y = CFG.CAR_Y + (CFG.PORTAL_Y - CFG.CAR_Y) * eased
    run.player_opacity = math.floor(255
      * (1 - clamp((progress - 0.65) / 0.35, 0, 1)))
    if not run.pending_round_at or now < run.pending_round_at then return end
    run.pending_round_at = nil
    if run.round >= Curriculum.count() then
      finish_game(true)
      return
    end
    run.round = run.round + 1
    setup_round()
    return
  end

  run.checkpoint_y = run.checkpoint_y + current_speed() * dt_ms * 0.001
  for i = 1, run.checkpoint_loot_n do
    local loot = run.checkpoint_loot[i]
    if loot.active and run.checkpoint_y >= loot.drop_y then
      loot.active = false
      if loot.slot and loot.slot.spr then set_sprite(loot.slot.spr, false) end
    end
  end
  if run.checkpoint_y > CFG.SCREEN_H + 24 then
    resume_round_after_checkpoint()
  end
end

local function render_gameplay(now)
  set_sprite(render.road_bg, true, 0, 0)
  local hud_visible = run.scene == SCENE_DRIVE or run.scene == SCENE_CHECKPOINT
  set_sprite(render.hud_planet, hud_visible, 24, 12, 255)
  set_sprite(render.hud_star, hud_visible, 330, 13, 255)
  for i, heart in ipairs(render.hud_hearts) do
    set_sprite(heart, hud_visible, 382 + (i - 1) * 25, 13,
      i <= run.lives and 255 or 45)
  end
  local blink = now < run.invincible_until and math.floor(now / 120) % 2 == 0
  local player_y = run.player_y or CFG.CAR_Y
  local player_opacity = run.player_opacity or 255
  local player_x = run.car_x
  local hovering = run.scene == SCENE_DRIVE
    or (run.scene == SCENE_CHECKPOINT and not run.checkpoint_solved)
  if hovering then
    local phase = (now % CFG.FLIGHT_BOB_PERIOD_MS) / CFG.FLIGHT_BOB_PERIOD_MS
    local wave = math.sin(phase * math.pi * 2)
    player_y = player_y + wave * CFG.FLIGHT_BOB_PX
    player_opacity = math.min(player_opacity,
      255 - math.floor((wave + 1) * 0.5 * CFG.FLIGHT_PULSE_OPACITY))
    if run.flight_bank_until and now < run.flight_bank_until then
      local bank_k = (run.flight_bank_until - now) / CFG.FLIGHT_BANK_MS
      player_x = player_x + (run.flight_bank_dir or 0) * CFG.FLIGHT_BANK_PX * bank_k
    end
  end
  set_sprite(render.player, not blink and not run.shield,
    player_x - CFG.CAR_W / 2, player_y + 2, player_opacity)
  set_sprite(render.player_shield, not blink and run.shield,
    player_x - 30, player_y - 1, player_opacity)

  if run.play_layout_dirty then
    -- The journey reads as planet + name + stage, followed by the star score;
    -- defensive states remain grouped on the right.
    align_text(render.voice, "top_left", 50, 13)
    align_text(render.hud, "top_left", 353, 13)
    color_text(render.hud, 0xFFE66D)
    color_text(render.voice, 0x7CFFCB)
    hide_text(render.footer)
    hide_text(render.boss)
    run.play_layout_dirty = false
  end
  if run.hud_dirty or now >= run.hud_next_ms then
    set_text(render.hud, tostring(run.coins), true)
    local planet = planet_for_round(run.round)
    set_text(render.voice,
      I18n.planet(planet.name) .. " | " .. string.format("%02d", run.round), true)
    run.hud_dirty = false
    run.hud_next_ms = now + 150
  end

  if run.scene == SCENE_DRIVE then
    if run.lanes_dirty then
      for i = 1, 3 do
        local word = string.upper(run.lane_words[i])
        local lane_dx = (i - 2) * 160
        -- LVGL's bottom anchor uses the rendered glyph width, so long and short
        -- words remain truly centred without a rough character-count estimate.
        align_text(render.lane_text[i], "bottom", lane_dx, -5)
        color_text(render.lane_text[i], i == run.lane and 0xFFD85A or 0xF4F7FF)
        set_text(render.lane_text[i], word, true)
      end
      run.lanes_dirty = false
    end
  end

  if run.message ~= "" and (run.message_until == 0 or now < run.message_until) then
    set_text(render.message, run.message, true)
  else
    run.message = ""
    hide_text(render.message)
  end

  if run.scene == SCENE_CHECKPOINT then
    hide_lane_labels()
    hide_text(render.footer)
    local checkpoint_dy = math.floor(run.checkpoint_y) - CFG.SCREEN_H / 2
    for i = 1, run.checkpoint_loot_n do
      local loot = run.checkpoint_loot[i]
      local slot = loot.slot
      if slot and slot.spr then
        local loot_y = math.floor(run.checkpoint_y) - loot.trail_y
        local loot_x = lane_x_at(loot.lane, loot_y + slot.h * 0.5) - slot.xoff
        set_sprite(slot.spr, loot.active,
          loot_x, loot_y + slot.yoff, portal_opacity(loot_y + slot.h * 0.5))
      end
    end
    if run.checkpoint_solved then
      hide_text(render.boss)
      hide_text(render.message)
    else
      align_text(render.boss, "center", 0, checkpoint_dy - 24)
      color_text(render.boss, 0x7CFFCB)
      set_text(render.boss, run.voice_available and I18n.t("say_sentence")
        or I18n.t("voice_unavailable"), true)
      align_text(render.message, "center", 0, checkpoint_dy)
      color_text(render.message, 0xFFE66D)
      set_text(render.message, run.checkpoint_display, true)
    end
  end
end

-- Renders the GET /games/rank payload (top[] + my_rank) once it arrives.
-- Falls back to leaving the "updating..." placeholder from finish_game() up
-- if the result never lands (offline, BE error) or decodes to nil.
local function show_rank_result(result)
  local board = GameOverUI.top5_board(result)
  if board then set_text(render.boss, board, true) end
  local rank = GameOverUI.rank_of(result)
  set_text(render.voice, GameOverUI.rank_line(rank), true)
end

local function update_over(now)
  if not run.rank_shown then
    if run.rank_poll_deadline and now >= run.rank_poll_deadline then
      run.rank_shown = true
    else
      local result = Ranking and Ranking.get_result and Ranking.get_result()
      if result then
        show_rank_result(result)
        run.rank_shown = true
      end
    end
  end
  if is_a2a and run.exit_at > 0 and now >= run.exit_at then
    if Engine and Engine.exit then Engine.exit("word_racer_over") end
    run.exit_at = 0
  end
end

function game_start(params)
  print("word_racer: game_start")
  is_a2a = params and params.is_a2a or false
  local language = I18n.set_language(params and params.language or "vi")
  GameOverUI.set_language(language)
  math.randomseed(now_ms() + 73)
  run = { scene = SCENE_TITLE, last_tick_ms = now_ms() }
  render.ready = false
  pending_start = false
end

function on_tick(dt_ms)
  local now = now_ms()
  led_tick(now)
  pump_sfx(now)
  if not render.ready then
    if not build_render_objects() then return end
    show_title()
    if pending_start then start_run() end
    return
  end

  -- The engine supplies its configured period (normally 33 ms), not the
  -- elapsed wall time. When rendering overruns on hardware, trusting that
  -- value makes the whole game run in slow motion. Prefer the monotonic timer
  -- and keep the engine value as a simulator/fallback path.
  local engine_dt = clamp(tonumber(dt_ms) or 0, 0, 100)
  local real_dt = now - (run.last_tick_ms or now)
  run.last_tick_ms = now
  dt_ms = clamp(real_dt > 0 and real_dt or engine_dt, 0, 100)
  if run.scene == SCENE_TITLE then
    -- Two-second blink cycle: visible for 1 s, hidden for 1 s.
    local elapsed = now - (run.title_started_at or now)
    local visible = math.floor(elapsed / 1000) % 2 == 0
    if run.title_blink ~= visible then
      set_sprite(render.start_star, visible, 208, 128, 255)
      if visible then
        set_text(render.footer, I18n.t("start_left"), true)
        set_text(render.boss, I18n.t("start_right"), true)
        set_text(render.voice, I18n.t("start_left"), true)
        set_text(render.message, I18n.t("start_right"), true)
      else
        hide_text(render.footer)
        hide_text(render.boss)
        hide_text(render.voice)
        hide_text(render.message)
      end
      run.title_blink = visible
    end
  elseif run.scene == SCENE_DRIVE then
    update_drive(dt_ms, now)
    if run.scene == SCENE_OVER then
      update_over(now)
    elseif run.lives <= 0 then
      finish_game()
    else
      render_gameplay(now)
    end
  elseif run.scene == SCENE_CHECKPOINT then
    update_checkpoint(dt_ms, now)
    if run.scene == SCENE_OVER then
      update_over(now)
    else
      render_gameplay(now)
    end
  elseif run.scene == SCENE_OVER then
    update_over(now)
  end
end

function on_input(action, phase, _hold_ms)
  if phase ~= Input.PRESS then return end
  if run.scene == SCENE_TITLE then
    if action == "confirm" then start_run() end
  elseif run.scene == SCENE_OVER then
    if action == "confirm" and not is_a2a then start_run() end
  elseif run.scene == SCENE_DRIVE then
    if action == "left" then move_to_lane(run.lane - 1, false) end
    if action == "right" then move_to_lane(run.lane + 1, false) end
  elseif run.scene == SCENE_CHECKPOINT then
    -- Voice is the normal completion path. The star button is exposed only
    -- after KWS fails, so a hardware/service error cannot trap the player in
    -- an endless checkpoint loop.
    if action == "confirm" and not run.voice_available then complete_checkpoint() end
  end
end

function on_voice_event(e)
  if type(e) ~= "table" then
    print("word_racer: raw voice event " .. tostring(e))
    return
  end
  if e.type == "error" then
    run.voice_available = false
    led_set_base(LED.RED)
    if run.scene == SCENE_CHECKPOINT then
      set_message(I18n.t("voice_unavailable"), 0, 0xFFB347)
    end
    return
  end
  if e.type ~= "VOICE_COMMAND" then return end
  local data = e.data
  if type(data) ~= "table" then return end
  if data.status == "unavailable" then
    run.voice_available = false
    led_set_base(LED.RED)
    if run.scene == SCENE_CHECKPOINT then
      set_message(I18n.t("voice_unavailable"), 0, 0xFFB347)
    end
    return
  end
  if not data.keyword then return end

  local keyword = Curriculum.clean(data.keyword)
  led_start_flash()
  if run.scene == SCENE_CHECKPOINT then
    if keyword == run.checkpoint_phrase then complete_checkpoint() end
  elseif run.scene == SCENE_DRIVE then
    for lane, word in ipairs(run.lane_words) do
      if lane ~= run.lane and keyword == Curriculum.core(word) then
        move_to_lane(lane, true)
        return
      end
    end
  end
end

function on_home()
  return false
end

function game_end()
  voice_stop()
  if Speaker and Speaker.stop_all then pcall(Speaker.stop_all) end
  for _, s in ipairs(render.all_sprites or {}) do
    if s and s.destroy then pcall(function() s:destroy() end) end
  end
  render.all_sprites = {}
  render.sprite_cache = {}
  render.text_cache = {}
  render.text_visible = {}
  render.text_color = {}
  render.ready = false
  print("word_racer: game_end")
end
