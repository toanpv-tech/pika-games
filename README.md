# pika-games

Game pack cho **Pika Game Engine** — runtime **Lua 5.5** chạy trên robot PIKA
(ESP32-S3, MCU `head`), game loop **~30 FPS**, màn hình **480×320 RGB565**.

Repo này là **nội dung thẻ SD**, không phải firmware. Mỗi thư mục cấp 1 là một
game pack độc lập; engine nạp pack từ `/sd/games/<game_id>/` lúc runtime. Không
có bước biên dịch — viết Lua rồi copy ra thẻ.

README này là **hướng dẫn làm một game từ đầu đến khi chạy được trên robot**.
Đọc tuần tự Bước 0 → Bước 8. Danh mục pack có sẵn ở §9 — dùng làm bản mẫu để copy.

---

## Bước 0 — Trước khi viết dòng code nào

**Chốt 3 câu hỏi này trước.** Trả lời sai ở đây thì code lại từ đầu, không phải sửa.

**0.1. Game chạy luồng nào?** Quyết định game có dùng `Voice` được hay không:

| | **Offline** (menu) | **A2A / Learn** (server chèn giữa hội thoại) |
|---|---|---|
| Ai mở game | Người dùng chọn từ menu robot | Server gửi `PLAY_GAME{game_id}` |
| Điều khiển | 3 nút ENTER / LEFT / RIGHT | 3 nút **+ `Voice`** (đang online) |
| `Voice` | **Không có** (offline, không mạng) | Dùng được — đây là điểm khác biệt duy nhất |
| Kết thúc | về Menu | robot trả `GAME_RESULT{ended, score}`, hội thoại tiếp tục |
| Thời lượng | tuỳ | **phải hợp lý** — kết nối WS giữ sống suốt lúc chơi |
| Ví dụ | board game, puzzle chơi bằng nút | `word_maze`, `word_racer`, `word_garden` |

Game đọc `params.is_a2a` trong `game_start` để biết mình đang ở luồng nào —
đây là **nguồn duy nhất** (`Voice.mode()` đã bị gỡ). Muốn chạy cả 2 luồng thì
phải có đường điều khiển bằng nút làm fallback.

**0.2. Có ngân sách frame chưa?** 30 FPS = **33 ms/frame**. Trước khi code, đếm
thô mỗi frame vẽ bao nhiêu sprite, đổi bao nhiêu `Text`, có decode ảnh nào
không. Hiệu năng trên robot thật **> độ trung thực hình ảnh** — một game đẹp mà
tụt frame là game chưa xong.

**0.3. Art có vừa panel chưa?** 480×320 là **toàn bộ** không gian. PNG lớn hơn
panel sẽ fail nạp. Layout phải chừa vùng HUD đọc được ở khoảng cách chơi thật.

> Trần cứng phải thiết kế quanh nó, không phải tối ưu sau:
> **1 `Anim` (GIF/MJPEG) cùng lúc** — anim mới **dừng** anim cũ ·
> **≤ 32 sprite** đồng thời · **watchdog 1.5 s mỗi hook** ·
> **Lua heap 512 KB** (PSRAM) · **≤ 64 audio alias** · **≤ 16 input action** ·
> **≤ 8 `Text`** · **≤ 4 cỡ chữ** đồng thời.

Hai trần cuối siết chặt hơn vẻ ngoài của chúng, và cả hai **hỏng âm thầm**:

- **8 `Text`**: slot bị giữ từ lúc tạo tới lúc `destroy()`, **không phải** chỉ
  khi đang hiện. Cả 3 pack đều đã chạm trần → màn kết thúc **mượn lại** label
  của lúc chơi thay vì xin thêm.
- **4 cỡ chữ**: cache key là cặp `(file, px)`, nên mỗi cỡ là một face riêng.
  Xin cỡ thứ 5 thì `font_acquire_slot` chỉ log `font cache full` rồi để label
  giữ **nguyên mặt chữ cũ** — không có lỗi nào ném ra.

---

## Bước 1 — Dựng bộ xương pack

`game_id` = **tên thư mục**, `snake_case`. Đây là id thật: server gửi đúng chuỗi
này trong `PLAY_GAME`, và menu hiển thị tên thư mục nếu manifest thiếu `name`.
Field `name` chỉ là nhãn hiển thị.

Tối thiểu để engine nạp được — đúng 2 file:

```
my_game/
├── manifest.json
└── scripts/
    └── main.lua
```

Bố cục đầy đủ nên bám (quy ước của repo, reviewer đọc được ngay):

```
my_game/
├── manifest.json          # bắt buộc — metadata + khai báo ngoại vi + map input/audio
├── icon.png               # icon trên màn hình chọn game
├── scripts/
│   └── main.lua           # entry, trỏ bởi manifest."main" — CHỈ wiring
├── libs/                  # module require được: require("libs/config")
│   ├── config.lua         # hằng số gameplay/layout, tách khỏi logic
│   ├── curriculum.lua     # dữ liệu từ vựng / bài học
│   └── rules.lua          # luật game thuần, không chạm ngoại vi
├── assets/
│   ├── runtime/           # PNG + .rgb565 engine đọc TRỰC TIẾP
│   ├── image/             # PNG nguồn (background, cover, game-over)
│   └── audio/             # WAV đã resample sẵn — cái này engine phát
└── fonts/
    └── vi-regular.ttf     # subset tiếng Việt cho LVGL Tiny TTF
```

**Self-contained:** mọi path resolve dưới `/sd/games/<game_id>/`. Không có SDK
bundle dùng chung → font lặp trong từng pack là **cố ý**, đừng "tối ưu" thành
thư mục chung; mỗi pack còn được chọn face riêng (`word_maze`/`word_racer` dùng
`vi-bold.ttf`, `word_garden` dùng `vi-regular.ttf`). Sandbox chặn path tuyệt
đối, `..`, `\`, `:`.

Cách nhanh nhất: copy `word_maze/` (pack đầy đủ nhất) rồi thay nội dung.

---

## Bước 2 — Viết `manifest.json`

```json
{
  "version": "0.1.0",
  "name":    { "vi": "Tên Tiếng Việt", "en": "English Name" },
  "main":    "scripts/main.lua",
  "peripherals": ["button", "display", "audio", "voice", "led", "servo"],
  "input":  { "actions": { "left":    ["button:left"],
                           "right":   ["button:right"],
                           "confirm": ["button:enter"] } },
  "audio":  { "sounds": { "start": { "path": "assets/audio/start.wav" },
                          "bgm":   { "path": "assets/audio/loop.wav", "loop": true } } },
  "servos": { "neck": "head" },
  "poses":  { "win": "cheer_jump" }
}
```

### Bốn cái bẫy đã làm fail pack thật

**1. `peripherals` — `"voice"` là cam kết, không phải khai báo trang trí.**
Khai `"voice"` thì BACK dựng WS session + mic (lazy-init) **và** coi voice là
bắt buộc: mất transport → **kết thúc game**. Không có mức "voice tuỳ chọn, mất
thì chơi tiếp". Ngược lại, pack gọi `Voice.*` mà **quên** khai `"voice"` thì mọi
lời gọi trả `"busy"` (task/WS chưa dựng). Các giá trị khác
(`servo`/`led`/`audio`/`button`/`display`) hiện **chưa có consumer** nào đọc —
khai cho đủ và cho tương lai, chưa gate gì.

**2. `audio.sounds.*.path` bị `stat()` ngay lúc nạp** → sai **một** đường dẫn là
**reject cả pack**, không phải chỉ mất một tiếng. Kiểm path trước khi flash.

**3. Vượt giới hạn — hành vi KHÔNG đồng nhất, phải nhớ:**

| Vượt | Hậu quả |
|---|---|
| `audio.sounds` > 64 | **âm thầm** bỏ bớt, giữ 64 cái đầu, không log |
| `input.actions` > 16 · `servos` > 8 · `poses` > 16 | **reject cả pack** (`ERR_PACK_MANIFEST`) |
| `name` / `main` > 63 ký tự | **cắt cụt**, không reject |
| sai kiểu bất kỳ bảng con nào | reject cả manifest |

**4. Tên field v1 đã bị gỡ fallback hoàn toàn.** `display_name` / `entry_script`
không còn được đọc dưới bất kỳ hình thức nào → tên rỗng trên menu + fail nạp
Lua. Chỉ dùng `name` / `main`.

`poses` phải khớp danh sách **16 gesture wire-stable**: `default`, `poke`,
`talk_random_v1`, `talk_random_v2`, `say_hi`, `raise_both`, `idle_talk_1`,
`idle_talk_2`, `greeting`, `noaction`, `left_arm_rotate`, `open_menu`,
`admiring`, `cheer_jump`, `left_wave`, `system_error`.
`servos` chỉ 4 target: `head`, `base` (= `body`), `left`, `right`.

Bỏ hẳn block `input` → engine seed default `confirm→enter, left→left, right→right`.

---

## Bước 3 — Viết `main.lua`: hook và thứ tự frame

Mọi hook đều **optional** (thiếu thì engine bỏ qua), chạy dưới `pcall` +
watchdog **1.5 s**. Lỗi hoặc timeout trong `game_start` / `on_tick` /
`on_input` / `on_sound_end` / `on_voice_event` → **kết thúc game** kèm `EVT_ERROR`.

| Hook | Chữ ký | Khi nào | Trả về |
|---|---|---|---|
| `game_start(params)` | `(table)` | 1 lần, sau khi script nạp | bỏ qua |
| `on_input(action, phase, hold_ms)` | `(string, int, int)` | mỗi input event, **trước** `on_tick` cùng frame | bỏ qua |
| `on_tick(dt_ms)` | `(integer)` | mỗi frame (~33 ms) | bỏ qua |
| `on_input_lost(count)` | `(integer)` | input ring (32 slot) tràn | bỏ qua |
| `on_sound_end(alias, reason)` | `(string, int)` | audio kết thúc | bỏ qua |
| `on_sound_lost(count)` | `(integer)` | finish-ring (8 slot) tràn | bỏ qua |
| `on_voice_event(event)` | `(table\|string)` | mỗi frame voice session | bỏ qua |
| `on_home()` | `()` | HOME ngắn khi đang chơi | **bool** — `true` giữ game, `false`/`nil` thoát |
| `game_end()` | `()` | teardown | bỏ qua (lỗi non-fatal) |

Khung tối thiểu chạy được:

```lua
local label   -- Text handle: tạo LAZY, Text.new cần game screen đã có

function game_start(params)
  -- params LUÔN là table (mở từ menu → table rỗng), nên `params.x or default` an toàn
  local lang    = params.language or "vi"   -- ISO 639-1, ngoài dải → "vi"
  local is_a2a  = params.is_a2a             -- true khi mở trong luồng A2A
  -- Cả 2 là SNAPSHOT lúc start, không đổi trong ván → đọc 1 lần ở đây là đủ.

  -- Nạp MỌI asset lớn ở đây, không bao giờ trong on_tick.
  label = Text.new("Hello Pika!", 4, 4)
  Speaker.play("start")
end

function on_input(action, phase, hold_ms)
  -- So sánh bằng HẰNG, không dùng số literal
  if action == "confirm" and phase == Input.PRESS then
    if label then label:set("Pressed ENTER") end
  end
end

function on_tick(dt_ms)
  -- Cập nhật state. Phải xong trong ~33 ms.
end

function on_home()
  return false   -- HOME thoát game như mặc định
end

function game_end()
  -- Dọn dẹp. Lỗi ở đây non-fatal.
end
```

**Thứ tự trong 1 frame** — quan trọng khi debug input:

```
sound drain (on_sound_end) → input drain (on_input / on_input_lost)
   → on_tick → reset edge → servo/led/sound-stop drain → anim pump
```

Vì vậy `Input.just_pressed()` đúng trong **cả** `on_input` lẫn `on_tick` của
cùng frame.

`phase`: `Input.PRESS` (0) / `Input.RELEASE` (1) / `Input.REPEAT` (2).
`hold_ms` = 0 khi PRESS.

### Kiến trúc file: `main.lua` chỉ là wiring layer

Bám cách `word_maze` chia (1800 dòng `main.lua` + 7 module):

- `scripts/main.lua` — **chỉ** sở hữu sprite, `Text`, audio, hook. Không chứa luật.
- `libs/rules.lua`, `libs/maze.lua`, `libs/levels.lua` — luật game **thuần**,
  không chạm ngoại vi → đọc và review được độc lập.
- `libs/config.lua` — hằng số layout/gameplay, tách khỏi logic. Đây là **nguồn
  duy nhất** của layout: đổi `HUD_H` thì mê cung và đường kẻ tự dịch theo.
- `libs/curriculum.lua` — dữ liệu bài học.
- `libs/i18n.lua` — chrome vi/en. **Không dịch từ vựng**: đó là chuỗi trẻ phải
  nói và là thứ đưa cho `Voice.set_keywords`, dịch đi thì game hết nghe được.
- `libs/gameover_ui.lua` — format text màn kết thúc, thuần chuỗi, không chạm engine.

`require` chỉ một dạng được phép: `require("libs/config")`. Dạng khác
(`require("config")` không prefix, có `..`) bị **từ chối**. Module cache 1 phiên.

### Sandbox

Mở: `base`, `table`, `string`, `math`, `utf8`. **Không có** `io`, `os`,
`package`, `debug`, `coroutine`; `load` / `loadfile` / `dofile` bị gán `nil`.
Không tự mở kết nối mạng. Toàn bộ alloc Lua nằm trong budget **512 KB** PSRAM;
chạm 90% → engine phát `EVT_MEM_FALLBACK`, vượt → lỗi memory.

---

## Bước 4 — Vẽ và phát tiếng đúng cách

Bốn nguyên tắc này sinh ra gần hết bug hiệu năng của pack:

**4.1. Nạp asset ở `game_start`, không bao giờ trong `on_tick`.** Decode PNG
giữa frame là nguyên nhân tụt frame phổ biến nhất.

**4.2. Tái dùng sprite, đừng tạo/hủy mỗi frame.** Trần **32 sprite**. Tạo quá
trần → factory trả `nil`, **Lua phải tự kiểm**:

```lua
local s = Sprite.image("assets/runtime/hero.png")
if not s then print("load fail") ; return end   -- factory trả (nil, msg)
```

Xong việc thì `:destroy()`.

**4.3. Servo / LED / Anim là async — "đặt lệnh rồi quên".** Chỉ `Speaker` có
completion (`on_sound_end`). Đừng thiết kế gameplay giả định servo đã tới đích
khi hàm return. `Servo.is_busy` / `Speaker.is_playing` là **ước lượng**, không
phải trạng thái phần cứng thật — đừng xây logic phụ thuộc tuyệt đối vào chúng.

**4.4. Kiểm return của mọi lời gọi có thể bị từ chối.** Ví dụ hay sai:
`Led.blink` period phải ∈ [333, 5000] ms — ngoài range bị **từ chối**, engine
**không tự clamp** → `if not Led.blink(...) then ... end`. `Speaker.play` có
cooldown giữa 2 lần phát, bị bỏ thì trả `false`.

Chi tiết chữ ký từng hàm: xem tài liệu API của engine.

---

## Bước 5 — Chuẩn bị asset

| Đuôi | Dùng cho | Bắt buộc phải làm |
|---|---|---|
| `.png` | Sprite, icon, background | ≤ panel 480×320, nền trong suốt, chừa 1–2 px quanh silhouette |
| `.rgb565` | Frame buffer thô dựng sẵn | Bỏ hẳn decode PNG runtime — **đổi dung lượng thẻ SD lấy frame time** |
| `.wav` | Hiệu ứng qua `Speaker` | **Resample sẵn** về sample rate loa. Pack chỉ ship bản đã resample — **không giữ master 44.1 kHz trong pack** (thẻ SD là thứ ship ra máy, không phải kho asset); master để ở kho asset ngoài repo |
| `.ttf` | Text tiếng Việt (LVGL Tiny TTF) | Subset theo ngôn ngữ; có trần dung lượng + số face đồng thời |

`.rgb565` là con dao hai lưỡi: `word_garden` nặng **3.0 MB** — gấp 3 lần
`word_racer` (1014 KB) vốn không dùng `.rgb565` file nào — chính vì cycle
`.rgb565`. Chấp nhận được khi đổi lấy frame time, nhưng phải là quyết định có ý
thức, không phải mặc định.

Chữ có dấu tiếng Việt cần font phủ bộ chữ tương ứng, nếu không ra **tofu**. Game
đa ngôn ngữ phải fallback khi gặp `params.language` chưa dịch.

---

## Bước 6 — Đo, đừng đoán

Đọc `game.stat` / `game.warn` trên UART để thấy frame drop **thật**. Đừng tối ưu
theo cảm giác, và đừng tối ưu trước khi có số.

Khi cần đo giới hạn engine chứ không phải game của mình, dùng
`Engine.stack_hwm()` — trả về bytes stack **còn trống**, và FreeRTOS giữ mức
thấp nhất trong đời task nên giá trị chỉ giảm: theo dõi số **nhỏ nhất**, không
cần lấy mẫu giữa lời gọi. Đường tốn C stack thật là Lua→C→Lua lồng nhau
(`pcall`, binding, traceback), không phải Lua gọi Lua thuần.

Nếu `on_tick` treo > 5 s (ví dụ deadlock binding), stall detector kết thúc game.

---

## Bước 7 — Copy ra thẻ SD và chạy

1. Copy `my_game/` vào `/sd/games/my_game/` trên thẻ.
2. Offline: chọn game từ menu robot. A2A: server gửi `PLAY_GAME{game_id}` với
   `game_id` = `my_game`.
3. Bám UART lúc nạp — pack fail nạp thì log nói lý do (`ERR_PACK_MANIFEST`, sai
   path audio).

Fail nạp thường gặp, theo thứ tự tần suất: **sai path trong `audio.sounds`** →
vượt trần `input.actions`/`poses` → còn dùng `display_name`/`entry_script`.

---

## Bước 8 — Chấm Definition of Done

Trước khi coi là xong, chấm theo tài liệu Definition of Done của engine.
Tự kiểm nhanh:

- [ ] `manifest.json` schema v2 (`name` / `main` / `peripherals`), `peripherals`
      khai đúng theo API Lua **thật sự** gọi — rà lại script, nhất là `voice`
- [ ] Mọi `audio.sounds.*.path` tồn tại thật
- [ ] Không vượt trần: 32 sprite · 1 anim · 16 action · 64 sound · 8 servo ·
      16 pose · **8 `Text`** · **4 cỡ chữ**
- [ ] Không nạp asset trong `on_tick`; không tạo sprite mỗi frame
- [ ] Kiểm `nil` sau mọi factory; kiểm return của `Led.blink` / `Speaker.play`
- [ ] Luật game ở `libs/`, `main.lua` chỉ wiring
- [ ] Giữ được ~30 FPS trên **robot thật**, có số từ `game.stat`
- [ ] Có đường điều khiển bằng nút làm fallback nếu game voice-first

---

## 9. Các pack trong repo này

Dùng làm bản mẫu — cột cuối nói nên copy pack nào cho việc gì.

| Pack (`game_id`) | Tên | Ver | Ngoại vi | Size | Học được gì từ nó |
| --- | --- | --- | --- | ---: | --- |
| `word_maze` | Mê Cung | 1.1.1 | led, audio, display, voice, button, servo | 1.3 MB | **Bản mẫu tốt nhất.** Pack đầy đủ nhất, `libs/` tách `maze`/`rules`/`levels`/`curriculum` sạch. Nói từ trên biển chỉ đường để di chuyển chuột, đánh quái vật, mở lồng phô mai. Xem thêm: camera trượt 5×4 cho map lớn hơn màn hình. |
| `word_racer` | Trường Đua | 1.1.1 | led, audio, display, voice, button | 1014 KB | Voice-first 3 quỹ đạo, 24 chủ đề từ vựng, 8 hành tinh. Pack duy nhất dùng đủ 3 nút (`left`/`right`/`confirm`). Xem cách rasterize art từ Canvas HTML. |
| `word_garden` | Vườn Hoa | 1.1.1 | audio, display, voice, led, button | 3.0 MB | Đánh đổi `.rgb565` ↔ dung lượng thẻ. `main.lua` gọn nhất (756 dòng) nhờ đẩy hết layout sang `libs/config.lua`. Đọc đúng từ để hoa nở, giữ vườn trước lũ quạ. |

Cả 3 pack đều dùng chung 4 module `libs/`: `config` · `curriculum` · `i18n` ·
`gameover_ui`. Riêng `word_maze` có thêm `maze` / `rules` / `levels`. Ba bản
`gameover_ui.lua` **đã hội tụ** về cùng một layout màn kết thúc (điểm → hạng →
TOP 5 → footer `NHẤN [★] ĐỂ CHƠI LẠI`); sửa một bản thì đối chiếu 2 bản kia.

Font: `word_maze` và `word_racer` ship `vi-bold.ttf`, `word_garden` ship
`vi-regular.ttf` — **không dùng chung số đo bề rộng chữ giữa các pack**.

---

## 10. License

MIT.

Asset bên thứ ba giữ license riêng của chúng — kiểm license gốc trước khi tái
sử dụng asset từ pack khác.
