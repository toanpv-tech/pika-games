"""Build the two A1 learn bots (v2, graph with one LEARN node) for the 30-min trial.

Chunk bot: converted from workflow 950 (robot lesson 1209, "The Camping Trip part 1"), parts P1 (car scene only)
to P12 (without "Let's move to the next mission!"). Lines, audio and pictures are the workflow's own; the agent
payload (prompt, tools, generation params) comes from agent 2897, which is the same A1 lesson family.
Sentence bot: cut from agent 2897 (robot lesson 3162), positions 4-18 and 23; position 18 gets a second turn.
Usage: python3 build_learn_a1.py <source dir> <out dir>
"""
import copy
import json
import re
import sys

SD, OUT = sys.argv[1], sys.argv[2]

PASS = 0.85         # same threshold as the Pre-A1 lesson bots
ANSWER_PASS = 0.6   # "look and answer": the workflow accepted the phrase "clearly or not"
NOT_TRYING = ("Trẻ CÓ nói tiếng Anh và đang cố đọc theo từ mẫu (kể cả phát âm chưa chuẩn, thiếu hoặc thừa từ) thì KHÔNG chọn "
              "nhánh này — CHỈ dùng nhánh này khi trẻ im lặng, nói tiếng Việt, nói \"tớ không biết\", hoặc nói chuyện khác "
              "không liên quan tới từ mẫu: ")


def load(name):
    with open(f"{SD}/{name}", encoding="utf-8") as f:
        d = json.load(f)
    return d.get("result", d)


WF = load("activity950.json")
SRC = load("bot2897_prod.json")


def part(p):
    return WF["parts"][p - 1]["checkpoints"]


def q_resps(p, c):
    """Pika responses of workflow part p, checkpoint c (1-based), with the on-screen description."""
    ck = part(p)[c - 1]
    return ck["question"].get("pika_responses") or [], (ck["question"].get("show_on_screen") or {}).get("describe", "")


def intent_resps(p, name):
    """All responses of one intent of the speaking checkpoint of part p, flattened."""
    ck = next(c for c in part(p) if c["type"] == "cta-voice")
    it = next(i for i in ck["intents"] if i["name"] == name)
    out = []
    for lp in it["loops"]:
        rs = lp["response"] if isinstance(lp["response"], list) else [lp["response"]]
        for r in rs:
            out += r.get("pika_responses") or []
    return out


class Media:
    """Collects media of one checkpoint; tag() returns the [MEDIA:id] token for a sound and/or picture."""

    def __init__(self):
        self.items = []

    def tag(self, mid, image=None, audio=None, desc="", kind="for_question"):
        if not any(m["id"] == mid for m in self.items):
            self.items.append({"id": mid, "type": kind, "score": None, "audio_url": audio or "",
                               "image_url": image or "", "media_description": desc})
        return f"[MEDIA:{mid}]"


def speak(resps, media, prefix, desc="", kind="for_question"):
    """Turn workflow responses into text: spoken text stays, each sound or picture becomes one media tag."""
    out = []
    for i, r in enumerate(resps, 1):
        # [[name]] comes from the device account profile, which on a shared demo robot is not the child.
        text = (r.get("text") or "").replace("[[name]]", "").replace("~", "!").replace("!!", "!").strip()
        if r.get("sound"):
            out.append(media.tag(f"{prefix}_{i}", r.get("media"), r["sound"], desc, kind))
            if text:
                out.append(text)
        else:
            if r.get("media"):
                out.append(media.tag(f"{prefix}_{i}", r["media"], None, desc, kind))
            if text:
                out.append(text)
    return " ".join(out)


def base_ck(name, ctype):
    ck = copy.deepcopy(SRC["task_chain"][0]["checkpoints"][9])  # a cta_simplify of 2897: carries every runtime field
    for k in ("question", "question_guide", "response_guide", "image_listening", "media_list"):
        ck[k] = None
    ck.update({"name": name, "type": ctype, "cache_hash_question": None, "cache_hash_guide": None,
               "type_cta_simplify": "pronun", "pronun_version": 2})
    return ck


def narrative(name, segments):
    """segments: list of (part, ckp, extra_text_or_None)."""
    m = Media()
    words = []
    for p, c, extra in segments:
        resps, desc = q_resps(p, c)
        words.append(speak(resps, m, f"p{p}c{c}", desc))
        if extra:
            words.append(extra)
    ck = base_ck(name, "narrative")
    ck["question"] = " ".join(w for w in words if w) + " <next_ckp/>"
    ck["media_list"] = m.items
    return ck


def say_phrase(name, p, ref, reward_intent="intent_true", answer=False, with_intro=True):
    """'Look and say' / 'look and answer' / 'say the hard word' of part p as one cta_simplify.

    Look and say: two turns (turn 1 below PASS gets the workflow's model line and one more try).
    Look and answer and the hard word: one turn, as in the workflow (model line, then move on).
    """
    ck_src = next(c for c in part(p) if c["type"] == "cta-voice")
    m = Media()
    pre = [c for c in part(p) if c["type"] == "narrative"] if with_intro else []
    words = []
    for c in pre:
        words.append(speak(c["question"]["pika_responses"], m, f"p{p}n", c["question"]["show_on_screen"].get("describe", "")))
    q = ck_src["question"]
    desc = (q.get("show_on_screen") or {}).get("describe", "")
    words.append(speak(q["pika_responses"], m, f"p{p}q", desc))
    listen = next((r.get("image_listening") for r in q["pika_responses"] if r.get("image_listening")), None)
    reward = speak(intent_resps(p, reward_intent), m, f"p{p}ok", "Popa crystals reward", "for_response")
    hard_word = not any(i["name"] == "intent_false" for i in ck_src["intents"])
    model = speak(intent_resps(p, "intent_false" if not hard_word else "fallback"), m, f"p{p}fix", desc, "for_response")
    ck = base_ck(name, "cta_simplify")
    ck["question"] = " ".join(w for w in words if w)
    ck["image_listening"] = listen
    ck["media_list"] = m.items
    if hard_word:
        # The workflow models the word on every branch and moves on.
        turns = [{"turn": 1, "cases": [
            {"lower_bound": PASS, "response_guide": f"<emotion type=\"proud\"/> [Khen ngắn, cụ thể] {model} <next_ckp/>"},
            {"lower_bound": 0, "response_guide": f"<emotion type=\"encouraging\"/> {model} <next_ckp/>"}],
            "turn_guide": NOT_TRYING + f"<emotion type=\"encouraging\"/> {model} <next_ckp/>"}]
    elif answer:
        turns = [{"turn": 1, "cases": [
            {"lower_bound": ANSWER_PASS, "response_guide": f"<emotion type=\"proud\"/> [Khen ngắn, cụ thể] {reward} <next_ckp/>"},
            {"lower_bound": 0, "response_guide": f"<emotion type=\"encouraging\"/> {model} <next_ckp/>"}],
            "turn_guide": NOT_TRYING + f"<emotion type=\"encouraging\"/> {model} <next_ckp/>"}]
    else:
        # The workflow's "Not quite right!" openers are dropped: the trial never tells the child they got it wrong.
        last = model.replace("Not quite right! ", "").replace("Hehe, something’s not quite right! ", "").replace(
            "Oopsie, that sounded a little different! ", "")
        retry = re.sub(r"\s*\[MEDIA:[^\]]*_3\]$", "", last)  # the funny "tèn ten" closes the last try only
        turns = [
            {"turn": 1, "cases": [
                {"lower_bound": PASS, "response_guide": f"<emotion type=\"proud\"/> [Khen ngắn, cụ thể] {reward} <next_ckp/>"},
                {"lower_bound": 0, "response_guide": f"<emotion type=\"encouraging\"/> [Gần được rồi] {retry} Now, say it again!"}],
             "turn_guide": NOT_TRYING + f"<emotion type=\"calm\"/> [Mời trẻ nói cùng] {retry} Now, say it again!"},
            {"turn": 2, "cases": [
                {"lower_bound": PASS, "response_guide": f"<emotion type=\"proud\"/> [Khen ngắn, cụ thể] {reward} <next_ckp/>"},
                {"lower_bound": 0, "response_guide": f"<emotion type=\"encouraging\"/> {last} [Bảo chúng mình sẽ luyện thêm sau] <next_ckp/>"}],
             "turn_guide": NOT_TRYING + f"<emotion type=\"encouraging\"/> {last} [Bảo chúng mình sẽ luyện thêm sau] <next_ckp/>"}]
    ck["response_guide"] = {"tool": "pronun_check_v2_simplify", "turns": turns, "ref_text": ref, "global_guide": ""}
    return ck


def ending():
    m = Media()
    words = []
    for c in range(1, 8):
        resps, desc = q_resps(12, c)
        resps = [r for r in resps if (r.get("text") or "").strip() != "Let's move to the next mission!"]
        words.append(speak(resps, m, f"p12c{c}", desc))
    words.append("Cậu dạy tớ đủ 3 kiểu trời rồi, vào album hết! Bạn Jenny đang du lịch Tây Bắc cũng thấy y như vậy. "
                 "Mình qua hỏi Jenny xem trời thế nào nha!")
    ck = base_ck("P12 - Ôn 3 kiểu trời, nối sang Jenny", "narrative")
    ck["question"] = " ".join(w for w in words if w) + " <next_ckp/>"
    ck["media_list"] = m.items
    return ck


def wrap(checkpoints, node_id, name, desc):
    r = copy.deepcopy(SRC)
    task = r["task_chain"][0]
    task["checkpoints"] = checkpoints
    r["graph"] = {
        "nodes": [{
            "node_id": node_id, "prompt": "", "type": "LEARN", "tools": [], "pivots": [], "nexts": [],
            "checkpoints": checkpoints, "input_schema_key": None, "start_message": "", "hooks": [],
            "max_turns": None, "pre_llm_pipeline": None, "dynamic_checkpoint_builder": None,
            "dynamic_checkpoint_config": {}, "tts_provider_override": None, "learn_v2": True,
            "learn_v2_keep_dev_prompt": False, "learn_v2_keep_model": False,
        }],
        "global_pivots": [], "global_tools": list(task.get("tools") or []), "global_hooks": [],
        "system_prompt": task["SYSTEM_TASK_DESCRIPTION"], "version": "v2", "strict": False, "use_intent": "full",
    }
    r["name"], r["description"] = name, desc
    for k in ("id", "created_at", "updated_at"):
        r.pop(k, None)
    left = [i for i, ck in enumerate(checkpoints, 1) if "[[name]]" in json.dumps(ck, ensure_ascii=False)]
    if left:
        raise SystemExit(f"{node_id}: [[name]] still in ckp {left}")
    return r


chunk = wrap([
    narrative("P1 - Nhà KenBi lên xe đi cắm trại", [(1, 4, None), (1, 5, None), (1, 6, None)]),
    narrative("P2 - Buổi sáng nắng", [(2, 1, None)]),
    say_phrase("P2 - Nhìn và nói: a sunny morning", 2, "a sunny morning", with_intro=False),
    say_phrase("P3 - Nhìn và trả lời: a sunny morning", 3, "a sunny morning", answer=True),
    narrative("P4 - Dựng lều, gió mát", [(4, 1, None), (4, 2, None), (4, 3, None), (4, 4, None)]),
    say_phrase("P5 - Nhìn và nói: a cool breeze", 5, "a cool breeze"),
    say_phrase("P6 - Luyện từ khó: breeze", 6, "breeze"),
    say_phrase("P7 - Nhìn và trả lời: a cool breeze", 7, "a cool breeze", answer=True),
    narrative("P8 - Ăn trưa, trời trong", [(8, c, None) for c in range(1, 7)]),
    say_phrase("P9 - Nhìn và nói: a clear sky", 9, "a clear sky"),
    say_phrase("P10 - Luyện từ khó: clear", 10, "clear"),
    say_phrase("P11 - Nhìn và trả lời: a clear sky", 11, "a clear sky", answer=True),
    ending(),
], "learn_chunk", "A1 - Trải nghiệm 30p - Học cụm (chuyển từ workflow 950)",
    "Bot learn v2 cho buổi trải nghiệm 30 phút A1, nhúng vào graph chính bằng SubGraphNode. Chuyển từ workflow 950 "
    "(robot lesson 1209) P1-P12: bỏ intro chung và câu 'next mission', lời, âm thanh, hình giữ nguyên; nhìn và nói có "
    "lượt 2; câu cuối nối sang Jenny.")

# 2897 position 18 ("Okay, your turn. What's it like?") answers freely in one turn. The trial script wants a child who
# says only "clear sky" to hear the full sentence and try once more.
SKY_GUIDE = {"turns": [
    {"turn": 1, "cases": [], "turn_guide": (
        "• Case 1 (Trẻ nói đủ câu có 'It's' và 'clear sky'): <emotion type=\"admire\"/> [Khen cụ thể là trẻ nói đủ cả câu, "
        "nói Pika cũng thấy trời quang, không hỏi thêm] <next_ckp/>\n\n"
        "• Case 2 (Trẻ chỉ nói 'clear sky' hoặc 'a clear sky', thiếu 'It's'): <emotion type=\"encouraging\"/> "
        "[Khen trẻ nói đúng kiểu trời] Let's say the whole sentence: It's a clear sky! [Mời trẻ nói lại cả câu một lần]\n\n"
        "• Case 3 (Các trường hợp còn lại): <emotion type=\"encouraging\"/> [Nhẹ nhàng] Look at the sky. We say: "
        "It's a clear sky! [Mời trẻ nói theo một lần]")},
    {"turn": 2, "cases": [], "turn_guide": (
        "• Case 1 (Trẻ nói đủ câu có 'It's' và 'clear sky'): <emotion type=\"admire\"/> [Khen cụ thể] <next_ckp/>\n\n"
        "• Case 2 (Các trường hợp còn lại): <emotion type=\"encouraging\"/> It's a clear sky! "
        "[Bảo chúng mình sẽ luyện thêm sau, không hỏi thêm] <next_ckp/>")}],
    "global_guide": ""}

src_cks = SRC["task_chain"][0]["checkpoints"]
sent = []
for pos in [4] + list(range(5, 19)) + [23]:
    ck = copy.deepcopy(src_cks[pos - 1])
    if pos == 4:
        ck["question"] = ck["question"].replace("Hello, hello, hello! ", "")
        ck["cache_hash_question"] = None
    if pos == 10:
        # The source guide tags [MEDIA:It's], an id its media_list does not have; the runtime drops it silently.
        s = json.dumps(ck["response_guide"], ensure_ascii=False)
        if "[MEDIA:It's] " not in s:
            raise SystemExit("2897 position 10: [MEDIA:It's] not found")
        ck["response_guide"] = json.loads(s.replace("[MEDIA:It's] ", ""))
        ck["cache_hash_guide"] = None
    if pos == 18:
        ck["response_guide"] = SKY_GUIDE
        ck["cache_hash_guide"] = None
    sent.append(ck)
sentence = wrap(sent, "learn_sentence", "A1 - Trải nghiệm 30p - Học câu (cắt từ 2897)",
                "Bot learn v2 cho buổi trải nghiệm 30 phút A1, nhúng vào graph chính bằng SubGraphNode. Ckp gốc 2897 "
                "vị trí 4-18, 23 (It's a sunny morning / a cool breeze / a clear sky); vị trí 4 bỏ 'Hello, hello, hello!' "
                "(bài cụm đã nói); vị trí 18 thêm lượt 2 cho trẻ nói đủ câu; bỏ light rain, sunset, starry night và lời "
                "tạm biệt.")

for tag, payload in (("learn_chunk", chunk), ("learn_sentence", sentence)):
    with open(f"{OUT}/{tag}_create.json", "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(tag, "ckp:", len(payload["graph"]["nodes"][0]["checkpoints"]))
