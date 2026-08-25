-- Word Garden — Magic Sunset v2, ported from word_garden.html.
--
-- Input: VOICE ONLY during play. on_input serves TITLE and OVER alone (`confirm`
-- = start / play again), the two beats that are not a language target. The
-- manifest binds no left/right for the same reason.
-- Language: params.language picks vi/en for the CHROME only. The curriculum
-- stays English -- its words and phrases are what the child speaks and what
-- Voice.set_keywords matches on. See libs/i18n.lua.
local CFG=require("libs/config")
local Curriculum=require("libs/curriculum")
local GameOverUI=require("libs/gameover_ui")
local I18n=require("libs/i18n")

local TITLE,GARDEN,CLEAR,OVER="title","garden","clear","over"
local state={scene=TITLE}
local persistent={best=0}
local metrics={}
local voice={started=false,available=true}
local R={ready=false,sprites={},cache={},vis={},px={},py={},opa={},color={}}
local is_a2a=false
local pending_start=false
local next_sfx=0

local function now()
 return Timer and Timer.millis and Timer.millis() or 0
end

-- LED mirrors voice state, following the same design as word_racer_02:
-- solid blue while listening, solid red on error, and two white blinks when a
-- keyword arrives. The flash sequence then restores the current base color.
local LED={BLUE={0,0,255},RED={255,0,0},WHITE={255,255,255},FLASH_ON_MS=120,FLASH_OFF_MS=100,FLASH_BLINKS=2}
local led_base,led_flash,led_flash_i,led_flash_deadline=nil,nil,0,0
local LED_FLASH_SEQ={}
for _=1,LED.FLASH_BLINKS do
 LED_FLASH_SEQ[#LED_FLASH_SEQ+1]={ms=LED.FLASH_ON_MS,rgb=LED.WHITE}
 LED_FLASH_SEQ[#LED_FLASH_SEQ+1]={ms=LED.FLASH_OFF_MS,rgb=nil}
end
local function led_rgb(rgb) if rgb and Led and Led.set then Led.set(rgb[1],rgb[2],rgb[3])end end
local function led_off() if Led and Led.off then Led.off()end end
local function led_apply_base() if led_base then led_rgb(led_base)else led_off()end end
local function led_set_base(rgb) led_base=rgb;if not led_flash then led_apply_base()end end
local function led_start_flash()
 if not(Led and Led.set)then return end
 led_flash=LED_FLASH_SEQ;led_flash_i=0;led_flash_deadline=0
end
local function led_stop()
 led_flash=nil;led_flash_i=0;led_flash_deadline=0;led_base=nil;led_off()
end
local function led_tick(t)
 if not led_flash or t<led_flash_deadline then return end
 led_flash_i=led_flash_i+1;local step=led_flash[led_flash_i]
 if not step then led_flash=nil;led_apply_base();return end
 if step.rgb then led_rgb(step.rgb)else led_off()end
 led_flash_deadline=t+step.ms
end

-- Ranking.get_result() round-trip budget: back does POST /games/result then
-- GET /games/rank server-side before the rank IPC lands (see ranking_bridge.cpp).
-- If it never lands (offline, BE error) stop polling and keep the placeholder
-- rank instead of calling get_result() forever on the OVER screen.
local RANK_POLL_TIMEOUT_MS=6000

-- Speaker.play is MUTATOR-TOLERANT (unknown alias -> false, never raises, see
-- bind_speaker.c), so pcall bought nothing here — same reasoning as led_rgb.
local function sound(alias,force)
 local t=now();if not force and t<next_sfx then return end
 if Speaker and Speaker.play and Speaker.play(alias) then next_sfx=t+90 end
end

local function keep(s) if s then R.sprites[#R.sprites+1]=s end return s end
local function image(path,z)
 if not(Sprite and Sprite.image)then return nil end
 local ok,s,err=pcall(Sprite.image,path)
 if not ok or not s then print("word_garden: image failed "..tostring(path).." "..tostring(err));return nil end
 keep(s);s:set_visible(false);R.vis[s]=false;if z then s:set_z(z)end;return s
end
local function raw(path,w,h,z)
 if not(Sprite and Sprite.new)then return nil end
 local ok,s,err=pcall(Sprite.new,path,w,h)
 if not ok or not s then print("word_garden: raw failed "..tostring(path).." "..tostring(err));return nil end
 keep(s);s:set_visible(false);R.vis[s]=false;if z then s:set_z(z)end;return s
end
local function solid(w,h,c,z)
 if not(Sprite and Sprite.solid)then return nil end
 local ok,s=pcall(Sprite.solid,w,h,c);if not ok or not s then return nil end
 keep(s);s:set_visible(false);R.vis[s]=false;if z then s:set_z(z)end;return s
end
local function text(v,x,y,c)
 if not(Text and Text.new)then return nil end
 local ok,t=pcall(Text.new,v or "",x or 0,y or 0);if not ok or not t then return nil end
 if c then t:set_color(c);R.color[t]=c end;t:show(false);R.vis[t]=false;return t
end
-- Cache guards every write: LVGL calls take a lock shared with the timer task
-- (prio 6 preempts the engine's prio 5), so a redundant set_pos/set_visible/
-- set_color/move call is a real per-frame cost, not a free no-op.
local function txt(t,v,show)
 if not t then return end;v=tostring(v or "")
 if R.cache[t]~=v then t:set(v);R.cache[t]=v end
 show=show~=false;if R.vis[t]~=show then t:show(show);R.vis[t]=show end
end
local function hide(t) if t and R.vis[t]~=false then t:show(false);R.vis[t]=false end end
local function spr(s,show,x,y,opa)
 if not s then return end
 show=show==true
 if x and y then
  x,y=math.floor(x),math.floor(y)
  if R.px[s]~=x or R.py[s]~=y then s:set_pos(x,y);R.px[s],R.py[s]=x,y end
 end
 if opa and R.opa[s]~=opa then s:set_opacity(opa);R.opa[s]=opa end
 if R.vis[s]~=show then s:set_visible(show);R.vis[s]=show end
end
local function color_text(t,c)
 if t and R.color[t]~=c then t:set_color(c);R.color[t]=c end
end

-- Vietnamese-capable face. The engine default (Montserrat) carries no diacritic
-- glyphs, so every label that shows Vietnamese -- or a display_name with dấu
-- from GET /games/rank -- must be moved onto this one or it renders as tofu.
-- That was why the HUD, the plot labels and the messages were all written
-- without dấu: they had no face that could draw them, not because bare ASCII
-- was wanted. This pack's own vi-regular.ttf covers all of them (486 glyphs;
-- every string in libs/i18n was checked against its cmap).
--
-- Four sizes = four (path,size) faces, which is exactly GAME_FONT_SLOTS. The
-- cache keys on the PAIR, so every extra size is another face, another ~36 KB
-- resident buffer and another slot. A fifth would make font_acquire_slot log
-- "font cache full: all 4 faces in use" and return -1 -- it only evicts faces
-- with refs==0, so a live label would silently keep whatever face it had rather
-- than switching. Same ceiling word_maze and word_racer sit on.
local FONT_VI="fonts/vi-regular.ttf"
local HUD_PX=16       -- HUD row
local LABEL_PX=14     -- plot labels; also OVER rank/board/footer
local STATUS_PX=18    -- messages + spell prompt: read under time pressure
local OVER_SCORE_PX=26 -- the one number the child remembers

local function set_font(t,size)
 if not t then return end
 local ok,err=t:set_font(FONT_VI,size)
 if ok==nil and err then print("word_garden: set_font failed "..tostring(err))end
end

-- Centre a seed word under its pot. Text has no width-query API, so the label
-- cannot be positioned by computing its left edge; instead it is aligned "top",
-- which anchors on the SCREEN centre, and offset by the distance from there to
-- the pot centre. LVGL does the width maths, so SNOWY and CLOUDY both land
-- centred instead of both starting at the same x and running right by different
-- amounts (the old PLOT_X[i]+4 left anchor).
--
-- R.px/R.py are cleared because they cache absolute set_pos() coordinates, which
-- an align() invalidates -- a later spr()/move() must not think it already knows
-- where this label sits.
local function place_plot_label(t,i)
 if not t then return end
 t:align("top",CFG.PLOT_X[i]+CFG.PLOT_W//2-CFG.W//2,CFG.PLOT_Y[i]+CFG.LABEL_DY)
 R.px[t],R.py[t]=nil,nil
end

local function build_render()
 if R.ready then return true end
 -- Title is a STILL now, not a 2-frame atlas. The old title-cycle.rgb565 blinked
 -- the prompt by swapping the whole 480x320 frame every 500 ms -- a 300 KB
 -- open+fseek+fread off the SD card twice a second, holding the LVGL lock, which
 -- is the same mechanism that blew the Lua watchdog on the garden background.
 -- Only 1.09% of those 300 KB actually differed between the two frames.
 --
 -- title-still is old frame 1 (prompt already blank) and title-prompt is just
 -- the 209x29 band that differed, blinked by set_opacity -- no file I/O at all.
 -- Composited they are pixel-identical to the old frame 0 (verified).
 R.title=raw(CFG.ASSET.."title-still.rgb565",480,320,20)
 R.prompt=raw(CFG.ASSET.."title-prompt.rgb565",CFG.PROMPT_W,CFG.PROMPT_H,21)
 R.bg=raw(CFG.ASSET.."garden-cycle.rgb565",480,320,0)
 R.timebar=raw(CFG.ASSET.."time-bar.rgb565",CFG.HUD_BAR_W,8,15)
 R.life={image(CFG.ASSET.."life.png",15),image(CFG.ASSET.."life.png",15),image(CFG.ASSET.."life.png",15)}
 R.plot={}
 for i=1,6 do R.plot[i]={seed=image(CFG.ASSET.."plot-"..i.."-seed.png",5),bloom=image(CFG.ASSET.."plot-"..i.."-bloom.png",5)}end
 R.gold={seed=image(CFG.ASSET.."plot-gold-seed.png",6),bloom=image(CFG.ASSET.."plot-gold-bloom.png",6)}
 R.crow=image(CFG.ASSET.."crow.png",10)
 R.spell=image(CFG.ASSET.."spell-bg.png",12)
 R.flash=solid(480,320,CFG.FLASH_RGB565,30);if R.flash then R.flash:set_opacity(0);R.opa[R.flash]=0 end
 -- Blank backdrop for the OVER screen, the same one word_maze puts behind its
 -- INTRO/OVER scenes. Created HERE -- after the garden art, before the Text
 -- pool -- because LVGL draws in creation order on a shared parent: the five
 -- OVER labels are made below and so land in front of it. Resident and merely
 -- toggled, never rebuilt: a 480x320 Sprite.solid is a ~300 KB PSRAM
 -- allocation, and destroying/recreating it per round would both spike the
 -- frame and churn the arena's largest free block.
 R.blank=solid(480,320,CFG.BLANK_RGB565,25)
 if not R.blank then print("word_garden: blank backdrop alloc failed")end
 -- OVER footer only: the ENTER button drawn between the two halves of
 -- "NHẤN [*] ĐỂ CHƠI LẠI". z above the backdrop, hidden everywhere else.
 R.star=image(CFG.ASSET.."hud-star.png",26)
 -- ONE label for BOTH HUD rows, joined with "\n". The Text pool is 8 and this
 -- pack already spends all of it (hud + status + 6 plot labels), so a second
 -- HUD label does not exist to be had: a slot is held from allocation to
 -- destroy, not just while visible. See hud_rows().
 R.hud=text("",CFG.HUD_PAD_X,CFG.HUD_Y,CFG.COL_HUD)
 R.status=text("",0,0,0xFFFFFF)
 set_font(R.hud,HUD_PX);set_font(R.status,STATUS_PX)
 R.label={}
 -- Plot label positions are static (CFG.PLOT_X/Y) — place once here instead of
 -- move()-ing every frame in render_plot.
 for i=1,6 do
  R.label[i]=text("",CFG.PLOT_X[i],CFG.PLOT_Y[i]+CFG.LABEL_DY,0xFFFFFF)
  set_font(R.label[i],LABEL_PX)
  place_plot_label(R.label[i],i)
 end
 if R.status then R.status:align("bottom",0,-5)end
 R.ready=true;return true
end

local function hide_garden()
 spr(R.bg,false);spr(R.timebar,false);for _,s in ipairs(R.life or{})do spr(s,false)end
 for _,p in ipairs(R.plot or{})do spr(p.seed,false);spr(p.bloom,false)end
 if R.gold then spr(R.gold.seed,false);spr(R.gold.bloom,false)end
 spr(R.crow,false);spr(R.spell,false);for _,t in ipairs(R.label or{})do hide(t)end
 -- The OVER footer star. Hidden here so every scene that clears the garden
 -- clears it too; render_over() runs AFTER this on the OVER path and puts it
 -- back, and setup_garden() reaches this via the same call.
 spr(R.star,false)
end

local function show_title()
 state.scene=TITLE;hide_garden();spr(R.blank,false);hide(R.hud);hide(R.status);spr(R.title,true,0,0,255)
end

local function stop_voice()
 if voice.started and Voice and Voice.stop then pcall(Voice.stop)end;voice.started=false;led_stop()
end
local function configure_voice()
 stop_voice();voice.available=(not Voice or not Voice.is_available)or Voice.is_available()
 if not(Voice and Voice.set_keywords and Voice.start)then voice.available=false;led_set_base(LED.RED);return end
 local words=Curriculum.keywords(state.plots,state.level)
 local ok,why=Voice.set_keywords(words,CFG.VOICE_SENSITIVITY)
 if not ok then print("word_garden: keywords "..tostring(why));voice.available=false;led_set_base(LED.RED);return end
 ok,why=Voice.start();if not ok then print("word_garden: voice start "..tostring(why));voice.available=false;led_set_base(LED.RED);return end
 voice.started=true;led_set_base(LED.BLUE)
end

local function shuffle(a)
 local b={};for i=1,#a do b[i]=a[i]end
 for i=#b,2,-1 do local j=math.random(i);b[i],b[j]=b[j],b[i]end;return b
end
local function make_plot(word,topic,index,golden)
 return{word=word,word_upper=string.upper(word),core=Curriculum.core(word),pattern=topic.pattern,bloom=false,golden=golden==true,color=index,shown=now()}
end
local function message(v,ms)
 state.message=v or"";state.message_until=ms and now()+ms or 0
end
local function setup_garden(fresh)
 local topic,ti=Curriculum.topic(state.level);local words=shuffle(topic.words);state.plots={}
 -- Display name for the HUD's second row. Resolved once per level here rather
 -- than per frame in render_garden: it is chrome, so it is translated, and
 -- I18n.topic() does a table lookup plus an upper() that has no business
 -- running 30 times a second.
 state.topic_name=I18n.topic(topic.name)
 for i=1,6 do state.plots[i]=make_plot(words[i],topic,i,false)end
 state.golden_slot=nil
 if state.level>1 and math.random()<0.6 then
  local max_old=math.min(state.level-1,Curriculum.count());local gi=math.random(max_old)
  if gi~=ti then local gt=Curriculum.topic_at(gi);local gw=shuffle(gt.words)[1];local slot=math.random(6);state.plots[slot]=make_plot(gw,gt,slot,true);state.golden_slot=slot end
 end
 state.crow=nil;state.crow_next=now()+CFG.FIRST_CROW_MS
 state.time_max=math.max(30,58-(state.level-1)*4);state.time_left=state.time_max
 state.scene=GARDEN
 -- No banner on a fresh level. It used to flash "VƯỜN 3: THỜI TIẾT" in white
 -- over the garden for 1.5 s, which was the only place the topic was named --
 -- but the topic now sits permanently in HUD row 2, so the banner repeated
 -- something already on screen while covering the plots the child was reading.
 --
 -- message("") rather than no call at all: entering a level from CLEAR leaves
 -- the "XONG VƯỜN! +n" text in state.message, and the banner used to overwrite
 -- it. Its deadline happens to equal CLEAR_HOLD_MS so it expires on the very
 -- tick that advances the level -- but that is two constants agreeing by
 -- accident, not a guarantee, so the message is cleared outright here.
 --
 -- The retry message stays: it marks a life lost, which nothing else shows.
 message(fresh and "" or I18n.t("retry"),fresh and 0 or 1100)
 -- R.hud keeps its gameplay anchor and face all the way through OVER now (the
 -- title line that used to borrow it is gone), so only the row cache is dropped
 -- here -- game_over() hides the label without clearing it, and hud_rows() skips
 -- the redraw when the cached values still match.
 if fresh and R.hud then
  R.hud_score,R.hud_level,R.hud_topic=nil,nil,nil
  -- The OVER screen borrowed R.status and plot labels 1-4 for its four lines
  -- plus the split footer, leaving them at OVER sizes and centred/bottom
  -- alignment. Play Again has to put all five back or the next round shows a
  -- 26 px score where the spell prompt belongs and four seed words stacked down
  -- the middle of the garden.
  if R.over_y then
   set_font(R.status,STATUS_PX);R.status_anchor=nil
   for i=1,4 do
    local t=R.label[i]
    if t then
     set_font(t,LABEL_PX)
     place_plot_label(t,i)
     R.cache[t]=nil
    end
   end
   R.over_y=nil
  end
 end
 configure_voice()
end

local function reset_metrics()
 metrics={blooms=0,spells=0,eaten=0,sunsets=0,goldens=0}
end
local function start_game()
 if not R.ready then pending_start=true;return end
 -- The star goes with the backdrop: setup_garden() does not call hide_garden(),
 -- so this is the only point on the OVER -> play-again path that clears them.
 pending_start=false;spr(R.title,false);spr(R.prompt,false);spr(R.blank,false);spr(R.star,false);reset_metrics()
 -- Drain any rank result still latched from the previous round: back's
 -- FetchGameRank runs on its own fire-and-forget task per Ranking.report()
 -- call and does not cancel an earlier in-flight fetch, so a reply slower
 -- than RANK_POLL_TIMEOUT_MS can land after this round already gave up
 -- polling. Left unconsumed, this round's first get_result() would read
 -- it and show the previous round's rank under this round's score (see
 -- word_racer_02's start_run() for the same fix).
 if Ranking and Ranking.get_result then Ranking.get_result() end
 state={scene=GARDEN,score=0,lives=CFG.MAX_LIVES,level=1,gardens=0,clear_until=0,flash_until=0,exit_at=0}
 setup_garden(true);sound("start",true)
end

local function all_bloomed()
 for _,p in ipairs(state.plots)do if not p.bloom then return false end end;return true
end
-- No `from_voice` flag any more: voice is the only way a plot blooms, so every
-- call comes from on_voice_event. It was declared to tell the two input paths
-- apart and never actually read by either.
local function bloom(i)
 local p=state.plots[i];if not p or p.bloom then return end
 p.bloom=true;metrics.blooms=metrics.blooms+1;local pts=(p.golden and 20 or 10)*state.level;state.score=state.score+pts
 if p.golden then metrics.goldens=metrics.goldens+1;sound("gold",true)else sound("bloom",true)end
 message("+"..pts,650)
 if all_bloomed()then
  local bonus=50*state.level+math.ceil(state.time_left)*2;state.score=state.score+bonus;state.gardens=state.gardens+1
  state.crow=nil;state.scene=CLEAR;state.clear_until=now()+CFG.CLEAR_HOLD_MS;message(I18n.t("garden_done")..bonus,CFG.CLEAR_HOLD_MS);sound("done",true)
 end
end

local function spawn_crow()
 local choices={};for i,p in ipairs(state.plots)do if p.bloom then choices[#choices+1]=i end end
 if #choices==0 then state.crow_next=now()+1000;return end
 local i=choices[math.random(#choices)];local p=state.plots[i]
 local phrase=Curriculum.phrase(p,state.level)
 local phrase_upper=string.upper(phrase)
 -- Lead-in is chrome and translated; the phrase after it is what the child says.
 state.crow={plot=i,deadline=now()+math.max(4500,8000-(state.level-1)*600),phrase=phrase,phrase_upper=phrase_upper,spell_prefix=I18n.t("spell_lead")..phrase_upper.."  ",shown=now()}
 sound("caw",true)
end
local function next_crow_time()
 return now()+math.max(1800,6000+math.random(0,4000)-(state.level-1)*400)
end
local function shoo_crow()
 if not state.crow then return end;metrics.spells=metrics.spells+1;local pts=20*state.level;state.score=state.score+pts
 state.crow=nil;state.crow_next=next_crow_time();message("+"..pts,700);sound("spell",true)
end
local function crow_eats()
 local p=state.plots[state.crow.plot];p.bloom=false;p.shown=now();metrics.eaten=metrics.eaten+1
 -- The flower NAME stays English: it is the word the child just spoke.
 message(I18n.t("crow_ate")..string.upper(p.word).."!",1300);state.crow=nil;state.crow_next=next_crow_time();sound("peck",true)
end

----------------------------------------------------------------------
-- GAME OVER screen. Five stacked lines, each on its own label so each can take
-- its own size, colour and centre -- the layout word_racer and word_maze use for
-- the same screen. Reading order is the order of importance: what happened, what
-- you scored, where that put you, who else is on the board, how to play again.
--
-- Labels: the six plot labels are idle here (hide_garden() has just hidden the
-- garden, so there are no seed words to show), which is what pays for the extra
-- lines. No new Text slot is taken -- the pool stays at 8 of 8.
--
-- Y values are word_maze's, matched line for line so the two OVER screens are
-- the same screen -- the sizes already agreed (26 / 14 / 14 / 14).
--
-- The "KẾT THÚC" title line is gone from both games. The screen itself already
-- says the run ended -- the garden is off, the score is huge and the footer
-- offers a replay -- so a heading only pushed the number the child actually came
-- for further down. The Y values are unchanged, so the score keeps the position
-- it has always had rather than sliding up into the title's slot.
--
--   y=72   ĐIỂM  1250          OVER_SCORE_PX  0xFFE600        the number they remember
--   y=116  HẠNG  #7            LABEL_PX       0x65F4FF        where it placed them
--   y=150  TOP 5 + rows        LABEL_PX       0xF4F7FF        the board
--   y=-8   NHẤN NÚT...         LABEL_PX       0xFFE600        the way out (bottom)
--
-- The old screen packed title + gardens + best into one label and score into
-- another. That forced a single size on unrelated fields and left the score --
-- the only number the child remembers -- the same weight as a tally of zero.
-- The gardens and best lines went with it: to a fresh player they read "0 and
-- 0", which teaches nothing, and the garden count is in the HUD all run.
local OVER_HERO_Y=72
local OVER_RANK_Y=116
local OVER_BOARD_Y=150

-- OVER footer: "<NHẤN> [star] <ĐỂ CHƠI LẠI>", the rig word_racer uses and
-- word_maze now shares. The star is 18x18; the two halves anchor to its left and
-- right at OVER_FOOTER_GAP from the rig centre (half the star plus 6 px of air),
-- so its spacing is fixed no matter how long the strings are.
--
-- The rig centre sits LEFT of the screen centre because the trailing half is far
-- longer than the leading one, so the group would read right-heavy if the star
-- itself were centred. How far left depends on that length difference, which
-- differs per language -- a single constant cannot centre both:
--
--   vi  "NHẤN" 40.6 px / "ĐỂ CHƠI LẠI" 81.3 px  ->  cx 220
--   en  "PRESS" 40.3 px / "TO PLAY AGAIN" 102.1 px  ->  cx 209
--
-- so it is derived rather than tuned. The old fixed 209 was right for en and put
-- vi 10.7 px left of centre. Centring the group means
--   cx + (post_w - pre_w)/2 = W/2
-- because the group spans [cx-GAP-pre_w, cx+GAP+post_w]. Widths are measured
-- from the shipped fonts/vi-regular.ttf at LABEL_PX with the same advance sum
-- Tiny TTF renders (sum of hmtx advances * px / unitsPerEm) -- this pack's face
-- is REGULAR, so word_maze's bold numbers do not carry over.
--
-- Text still cannot report a width at runtime, which is the whole reason the
-- halves are edge-anchored; this only moves the measuring to author time, where
-- the strings are known. Re-measure if the strings, LABEL_PX or the face change.
local OVER_FOOTER_W={vi={pre=40.6,post=81.3},en={pre=40.3,post=102.1}}
local OVER_FOOTER_GAP=15
-- align() offsets are measured from the anchored EDGE, not the centre:
-- bottom_right puts label.right at screen.right + dx (so dx is negative),
-- bottom_left puts label.left at screen.left + dx. Both derive from the same rig
-- centre so the pair can never drift apart.
local function footer_rig()
 local w=OVER_FOOTER_W[I18n.language()] or OVER_FOOTER_W.vi
 local cx=math.floor(CFG.W/2-(w.post-w.pre)/2+0.5)
 return (cx-OVER_FOOTER_GAP)-CFG.W,cx+OVER_FOOTER_GAP,cx-9  -- dx_pre, dx_post, star x (9 = half the 18 px sprite)
end
-- 293, not the 296 the text band's geometric centre works out to: the glyphs
-- have no descenders here, so their visual mass sits above that midpoint and a
-- centred star read low next to them.
local OVER_STAR_Y=293

-- Centre one borrowed label on its own line. Returns nothing; the caller owns
-- which label carries which line.
--
-- "top", not "top_mid": t:align() accepts only
-- center/top/bottom/left/right/top_{left,right}/bottom_{left,right}
-- (docs/pika-engine/api.md) and returns (nil,msg) on anything else -- a return
-- nobody here reads, so "top_mid" silently left every OVER line wherever it
-- last sat instead of on its y. "top" IS the horizontally-centred top anchor,
-- and is what word_maze's scene_text() passes for these same five lines.
local function over_line(t,value,y,color)
 if not t then return end
 txt(t,value,true);color_text(t,color)
 if R.over_y[t]~=y then t:align("top",0,y);R.over_y[t]=y;R.px[t],R.py[t]=nil,nil end
end

-- Paint every OVER line. Split out of game_over() because the rank and board
-- arrive later, on a Ranking.get_result() that lands some frames after the
-- screen is already up -- both paths render the same five lines.
local function render_over()
 -- The title line is gone: the score is the top line now, and R.hud stays a
 -- gameplay-only label -- no longer borrowed, so no re-anchor or font swap.
 hide(R.hud)
 over_line(R.status,GameOverUI.score_card(math.floor(state.score)),OVER_HERO_Y,0xFFE600)
 over_line(R.label[1],GameOverUI.rank_line(state.over_rank),OVER_RANK_Y,0x65F4FF)
 over_line(R.label[2],state.over_board or GameOverUI.pending_board(),OVER_BOARD_Y,0xF4F7FF)
 -- Footer anchored to the BOTTOM, not offset from the board: the board is 1 to
 -- 6 lines tall depending on what the backend returned, so anything measured
 -- from its top would drift with it.
 --
 -- Two halves with the star sprite between them. label[4] is idle on this screen
 -- (hide_garden() hid the plots), so the second half costs no extra Text slot.
 local dx_pre,dx_post,star_x=footer_rig()
 if R.label[3] then
  txt(R.label[3],GameOverUI.footer_pre(),true);color_text(R.label[3],0xFFE600)
  if R.over_y[R.label[3]]~="foot_pre" then R.label[3]:align("bottom_right",dx_pre,-8);R.over_y[R.label[3]]="foot_pre";R.px[R.label[3]],R.py[R.label[3]]=nil,nil end
 end
 if R.label[4] then
  txt(R.label[4],GameOverUI.footer_post(),true);color_text(R.label[4],0xFFE600)
  if R.over_y[R.label[4]]~="foot_post" then R.label[4]:align("bottom_left",dx_post,-8);R.over_y[R.label[4]]="foot_post";R.px[R.label[4]],R.py[R.label[4]]=nil,nil end
 end
 spr(R.star,true,star_x,OVER_STAR_Y,255)
end

local function game_over()
 if state.scene==OVER then return end;state.scene=OVER;stop_voice();persistent.best=math.max(persistent.best,state.score);sound("over",true)
 hide_garden();spr(R.title,false);spr(R.prompt,false)
 -- Raise the backdrop AFTER hide_garden(): the five lines below are contrast-
 -- checked against black, and without it they land on whatever the panel last
 -- held. state.flash_until is cleared too -- the sunset flash that took the
 -- final life is a full-screen white solid at z=30, above the backdrop, and
 -- render() would keep it up for the rest of its fade over the OVER text.
 state.flash_until=0;spr(R.flash,false)
 spr(R.blank,true,0,0,255)
 -- set_font takes the LVGL lock and re-renders the face, so it runs on scene
 -- ENTRY only, never from render_over(). Only R.status changes size here, and
 -- setup_garden(fresh) puts it back to STATUS_PX on the way into the next round.
 R.over_y={}
 set_font(R.status,OVER_SCORE_PX)
 for i=1,4 do set_font(R.label[i],LABEL_PX)end
 render_over();R.status_anchor="over"
 -- Reported on every round end regardless of A2A, independent of
 -- Engine.report_result below (same split as word_racer_02). Only start
 -- polling get_result() once the report actually went out (send_failed /
 -- bad_score / payload_too_big all return false, see bind_ranking.c) - back
 -- never kicks off FetchGameRank without a report landing first.
 local reported=false
 if Ranking and Ranking.report then local ok,sent=pcall(Ranking.report,{score=state.score});reported=ok and sent==true end
 state.rank_shown=not reported
 state.rank_poll_deadline=reported and (now()+RANK_POLL_TIMEOUT_MS) or nil
 if is_a2a and Engine and Engine.report_result then pcall(Engine.report_result,{event=string.format("over:s%d:g%d:l%d",state.score,state.gardens,state.level)});state.exit_at=now()+CFG.A2A_EXIT_HOLD_MS end
end
local function sunset()
 metrics.sunsets=metrics.sunsets+1;state.lives=state.lives-1;sound("sunset",true);message(I18n.t("sunset"),900)
 if state.lives<=0 then game_over()else setup_garden(false)end
end

-- Build the two-line HUD block.
--
--   NẮNG: ▓▓▓▓▓▓▓░░░      VƯỜN 3        ♥ ♥ ♡     <- row 1
--   ĐIỂM: 1250          THỜI TIẾT                 <- row 2
--
-- ONE Text carries both rows, joined with "\n". The pool is 8 and this pack
-- spends all of it (hud + status + 6 plot labels), so a second HUD label does
-- not exist to be had -- and a slot is held from allocation to destroy, not
-- just while visible, so the plot labels being hidden on other scenes does not
-- free one for gameplay. A multi-line label works here only because both rows
-- share the same left edge: LVGL left-aligns every line of a label, so two rows
-- that wanted different alignments could not share one.
--
-- Both rows carry a LEFT item and a CENTRED one, and the centring is done with
-- padding spaces measured from the left item's width:
--
--   row 1  NẮNG: + [bar sprite gap] ..... VƯỜN n    centred on HUD_MID_X
--   row 2  ĐIỂM: n ..................... topic      centred on HUD_MID_X
--
-- The pads are computed, never fixed. On row 1 the level goes from 1 to 2
-- digits; on row 2 the score swings 45 px between 0 and 99999 and the topic
-- changes every level. A fixed pad would let both centred items drift. The
-- widths come from libs/i18n: exact for the worded parts and the digits (every
-- digit in this face shares one advance), and within 0.03 px for a topic name
-- (I18n.text_w, checked against all 48 names in both languages).
--
-- No `sun` parameter: the seconds are shown by the BAR now, not by a number.
local function hud_rows(level,score,topic)
 -- Gap that puts `centred` (width w) on HUD_MID_X when the row's left item ends
 -- at `left_end`, quantised to whole spaces.
 local function pad_to_centre(left_end,w)
  return math.max(1,math.floor((CFG.HUD_MID_X-w/2-left_end)/CFG.HUD_SPACE_ADV+0.5))
 end

 -- Measured from the LABEL's end, not the bar's: the padding is TEXT, so it
 -- counts from where the text left off. The bar sprite is drawn on top of that
 -- gap, not appended after it -- measuring from the bar's right edge would
 -- double-count its 100 px and throw the cluster ~105 px off centre.
 local garden=I18n.t("garden").." "..level
 local row1=I18n.t("sun")
 ..string.rep(" ",pad_to_centre(CFG.HUD_PAD_X+I18n.hud_sun_w(),I18n.hud_garden_w(#tostring(level))))
 ..garden

 local score_s=I18n.t("score").." "..score
 local row2=score_s
 if topic and topic~="" then
  local score_end=CFG.HUD_PAD_X+I18n.text_w(I18n.t("score"))
                  +CFG.HUD_SPACE_ADV+#tostring(score)*I18n.HUD_DIGIT_W
  row2=score_s..string.rep(" ",pad_to_centre(score_end,I18n.text_w(topic)))..topic
 end
 return row1.."\n"..row2
end

local function time_frac()return state.time_max>0 and math.max(0,state.time_left/state.time_max)or 0 end
-- Only normal.{seed,bloom} live here — at most one plot is golden per round
-- (see setup_garden), so gold.{seed,bloom} is a single shared sprite pair
-- rendered once below for that slot, not per-plot here. Rendering it inside
-- this per-plot loop used to re-hide it on every non-golden slot visited
-- after the golden one in the same frame.
local function render_plot(i,p)
 local x,y=CFG.PLOT_X[i],CFG.PLOT_Y[i];local normal=R.plot[i];local sway=p.bloom and(math.floor(now()/450)%2)or 0
 spr(normal.seed,(not p.golden)and not p.bloom,x,y)
 spr(normal.bloom,(not p.golden)and p.bloom,x+sway,y)
 -- Three states, no cursor: bloomed (dim green, done), golden (pale gold, worth
 -- double) and waiting (white). The yellow "selected" colour went with the
 -- button cursor -- with voice-only input there is no selection to show, and a
 -- highlight stuck on plot 1 would have implied one.
 local label=R.label[i]
 color_text(label,p.bloom and 0x5F7A68 or(p.golden and 0xFFE08A or 0xFFFFFF))
 txt(label,p.word_upper,true)
end
local function render_garden()
 spr(R.title,false);spr(R.prompt,false);local pc=time_frac();local bg_last=CFG.BG_FRAMES-1;local bg_frame=math.max(0,math.min(bg_last,math.floor((1-pc)*bg_last+0.5)))
 if R.bg and R.bg_frame~=bg_frame then R.bg:set_frame(CFG.ASSET.."garden-cycle.rgb565",bg_frame);R.bg_frame=bg_frame end
 spr(R.bg,true,0,0)
 local bar_frame=math.max(0,math.min(32,math.floor(pc*32+0.5)))
 if R.timebar and R.bar_frame~=bar_frame then R.timebar:set_frame(CFG.ASSET.."time-bar.rgb565",bar_frame);R.bar_frame=bar_frame end
 -- Inline with row 1, right after the NẮNG:/SUN: label it belongs to.
 spr(R.timebar,true,CFG.HUD_BAR_X,CFG.HUD_BAR_Y)
 -- Lives stay VISIBLE and dim when spent instead of disappearing (word_racer's
 -- trick): the row never reflows, and the child reads "2 of 3" rather than
 -- just "2". Laid out from the right bezel so the count grows inward.
 for i,s in ipairs(R.life or{})do
  spr(s,true,480-CFG.HUD_PAD_X-CFG.HUD_LIFE_STEP*i,CFG.HUD_LIFE_Y,i<=state.lives and 255 or CFG.HUD_SPENT_OPA)
 end
 for i,p in ipairs(state.plots)do render_plot(i,p)end
 if R.gold then
  local gi=state.golden_slot
  if gi then
   local gbloom=state.plots[gi].bloom
   local gx,gy=CFG.PLOT_X[gi],CFG.PLOT_Y[gi];local sway=gbloom and(math.floor(now()/450)%2)or 0
   spr(R.gold.seed,not gbloom,gx,gy);spr(R.gold.bloom,gbloom,gx+sway,gy)
  else
   spr(R.gold.seed,false);spr(R.gold.bloom,false)
  end
 end
 if state.crow then local i=state.crow.plot;local bob=math.floor(now()/200)%2==1 and 2 or 0;spr(R.crow,true,CFG.PLOT_X[i]+24,CFG.PLOT_Y[i]-8+bob)else spr(R.crow,false)end
 -- Score/garden change on events, sun ticks ~1/s: rebuilding+re-setting this
 -- string unconditionally every frame at 30 FPS allocated garbage and
 -- re-locked LVGL for values that were almost always unchanged.
 -- The clock no longer appears as a NUMBER (the bar carries it), so the text is
 -- rebuilt only when the score or the level changes -- not once a second.
 if R.hud_score~=state.score or R.hud_level~=state.level or R.hud_topic~=state.topic_name then
  R.hud_score,R.hud_level,R.hud_topic=state.score,state.level,state.topic_name
  color_text(R.hud,CFG.COL_HUD)
  txt(R.hud,hud_rows(state.level,state.score,state.topic_name),true)
 end
 -- Messages share the idle hint's slot at the bottom of the screen rather than
 -- taking their own centred position over the garden. One place for everything
 -- the game says to the child, so there is a single line to watch instead of
 -- text appearing in two unrelated spots -- and the plots stay unobscured while
 -- a message is up, which the old centred anchor covered.
 --
 -- The CROW outranks a message now (it did not before). All three share one
 -- line, and the crow prompt is the only one that is time-critical: it is the
 -- spell the child must read before the countdown expires. Letting a 650 ms
 -- "+50" from blooming another plot blank it -- which is what the old order did
 -- -- cost the child the phrase and, two px apart from the countdown, read as a
 -- flicker rather than as a new message. Scoring feedback still lands: the HUD
 -- score updates on the same frame.
 --
 -- The message branch uses the idle anchor, deliberately: they are alternatives
 -- for the same line, so status_anchor is "idle" in both and no re-align runs
 -- when a message replaces the hint or expires back into it.
 if state.crow then
  if R.status_anchor~="crow" then R.status:align("bottom",0,-7);R.status_anchor="crow" end
  local sec=math.max(0,math.ceil((state.crow.deadline-now())/1000))
  if R.spell_sec~=sec or R.spell_crow~=state.crow then
   R.spell_sec,R.spell_crow=sec,state.crow
   txt(R.status,state.crow.spell_prefix..sec,true)
  end
  spr(R.spell,true,0,286)
 else
  if R.status_anchor~="idle" then R.status:align("bottom",0,-5);R.status_anchor="idle" end
  spr(R.spell,false)
  -- Message if one is live, otherwise the standing hint. Both on this line, so
  -- a message reads as the line briefly changing what it says.
  --
  -- A dead microphone replaces the hint: gameplay is voice-only now, so there is
  -- no button left to fall back on and the round simply cannot advance. Telling
  -- the child to say a word would be a lie. Messages still win over it -- they
  -- are brief, and the error returns when they expire.
  if state.message~="" and(now()<state.message_until or state.message_until==0)then
   txt(R.status,state.message,true)
  elseif not voice.available then
   txt(R.status,I18n.t("voice_dead"),true)
  else
   txt(R.status,I18n.t("idle_hint"),true)
  end
 end
 if state.flash_until and now()<state.flash_until then spr(R.flash,true,0,0,80)else spr(R.flash,false)end
end

local function tick_garden(dt)
 state.time_left=state.time_left-dt/1000
 if state.time_left<=0 then sunset();return end
 if not state.crow and now()>=state.crow_next then spawn_crow()end
 if state.crow and now()>=state.crow.deadline then crow_eats()end
end

-- Renders the GET /games/rank payload (top[] + my_rank) once it arrives.
-- Leaves the "updating..." placeholder from game_over() up if the result
-- never lands (offline, BE error) or decodes to nil, or takes longer than
-- RANK_POLL_TIMEOUT_MS - stops polling get_result() every frame once the
-- round trip is clearly not coming back.
local function update_over_rank()
 if state.rank_shown then return end
 if state.rank_poll_deadline and now()>=state.rank_poll_deadline then state.rank_shown=true;return end
 local result=Ranking and Ranking.get_result and Ranking.get_result()
 if not result then return end
 state.over_board=GameOverUI.top5_board(result)
 state.over_rank=GameOverUI.rank_of(result)
 render_over();R.status_anchor="over"
 state.rank_shown=true
end

function game_start(params)
 print("word_garden: game_start");is_a2a=params and params.is_a2a or false
 -- Chrome language only; the curriculum stays English (see libs/i18n.lua).
 -- Both modules keep their own table, so both get told.
 local lang=I18n.set_language(params and params.language)
 GameOverUI.set_language(lang)
 math.randomseed(now()+113);state={scene=TITLE};R.ready=false
end
function on_tick(dt_ms)
 local t=now()
 led_tick(t)
 if not R.ready then build_render();show_title();if pending_start then start_game()end;return end
 -- The engine supplies its configured period (normally 33 ms), not elapsed
 -- wall time. Trusting that value under render overrun makes the sunset
 -- timer run in slow motion vs real time (see word_racer_02 for the same fix).
 -- A single overrun can exceed the 100ms anti-tunnel clamp; the remainder is
 -- kept in state.time_debt and paid back over the following ticks instead of
 -- being discarded, so total elapsed game time still tracks wall time.
 local engine_dt=math.max(0,math.min(100,tonumber(dt_ms)or 0))
 local real_dt=t-(state.last_tick_ms or t)
 state.last_tick_ms=t
 local raw_dt=real_dt>0 and real_dt or engine_dt
 local debt=(state.time_debt or 0)+math.max(0,raw_dt-100)
 dt_ms=math.max(0,math.min(100,raw_dt))
 local payback=math.min(debt,100-dt_ms)
 dt_ms=dt_ms+payback;state.time_debt=debt-payback
 -- Blink by toggling the prompt sprite's VISIBILITY, not by swapping a 300 KB
 -- title frame off the SD card. spr() already caches vis, so the frames where
 -- nothing changed cost nothing.
 if state.scene==TITLE then spr(R.prompt,math.floor(now()/CFG.PROMPT_BLINK_MS)%2==0,CFG.PROMPT_X,CFG.PROMPT_Y,255)
 elseif state.scene==GARDEN then tick_garden(dt_ms);if state.scene==GARDEN then render_garden()end
 elseif state.scene==CLEAR then if now()>=state.clear_until then state.level=state.level+1;setup_garden(true)end;if state.scene~=OVER then render_garden()end
 elseif state.scene==OVER then
  update_over_rank()
  if is_a2a and state.exit_at>0 and now()>=state.exit_at then Engine.exit("word_garden_over");state.exit_at=0 end
 end
end
-- TITLE and OVER only. Gameplay is VOICE ONLY: a plot blooms when the child
-- says its seed word and a crow leaves when they read the spell, both through
-- on_voice_event. `confirm` survives here because start / play-again are the
-- only two beats that are not a language target -- the same split word_maze
-- uses.
--
-- The cursor went with the buttons. left/right moved a selection between the
-- six plots and confirm acted on it, which let a child clear a garden without
-- speaking; with nothing to move it, the highlight would have pinned plot 1
-- yellow for the whole round and named a choice that no longer exists.
function on_input(action,phase,_hold)
 if phase~=Input.PRESS then return end
 if state.scene==TITLE then if action=="confirm"then start_game()end
 elseif state.scene==OVER then if action=="confirm"and not is_a2a then start_game()end end
end
function on_voice_event(e)
 if type(e)~="table"then return end
 if e.type=="error"then voice.available=false;led_set_base(LED.RED);return end
 if e.type~="VOICE_COMMAND"or type(e.data)~="table"then return end
 if e.data.status=="unavailable"then voice.available=false;led_set_base(LED.RED);return end
 if not e.data.keyword or state.scene~=GARDEN then return end
 local key=Curriculum.clean(e.data.keyword);led_start_flash()
 if state.crow and key==state.crow.phrase then shoo_crow();return end
 for i,p in ipairs(state.plots)do if not p.bloom and key==p.core then bloom(i);return end end
end
function on_home()return false end
function game_end()
 stop_voice();if Speaker and Speaker.stop_all then pcall(Speaker.stop_all)end
 for _,s in ipairs(R.sprites or{})do if s and s.destroy then pcall(function()s:destroy()end)end end;R.sprites={};R.ready=false;print("word_garden: game_end")
end
