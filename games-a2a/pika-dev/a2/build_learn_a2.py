"""Build the two A2 learn bots (v2, graph with one LEARN node) for the 30-min trial.

Chunk bot: cut from agent 2584 (robot lesson 2977), checkpoints #4-#21; #4 loses the generic opener, #22 (next
mission) becomes a bridge to An Linh's family, and [[name]] is dropped.
Sentence bot: converted from workflow 764 (robot lesson 869, An Linh's family goes to Ly Son island), checkpoints
#1-#3, #6-#8 and #10 (the trial script cuts #4-#5 and #9). The family's lines live only in the recorded mp3 files, so
every branch plays the workflow's own recording; the branch conditions come from the workflow's intent descriptions.
It opens with the script's Ly Son riddle. The agent payload (prompt, tools, generation params) comes from agent 2584.
Usage: python3 build_learn_a2.py <source dir> <out dir>
"""
import copy
import json
import re
import sys

SD, OUT = sys.argv[1], sys.argv[2]


def load(name):
    with open(f"{SD}/{name}", encoding="utf-8") as f:
        d = json.load(f)
    return d.get("result", d)


SRC = load("bot2584_prod.json")
WF = load("activity764.json")
SRC_CKS = SRC["task_chain"][0]["checkpoints"]


def drop_name(obj):
    """[[name]] comes from the device account profile, which on a shared demo robot is not the child."""
    s = json.dumps(obj, ensure_ascii=False)
    s = s.replace("Oh [[name]], ", "Oh, ").replace("[[name]], can you guess", "Can you guess")
    s = re.sub(r",\s*\[\[name\]\]", "", s)
    # The trial never tells the child they got it wrong.
    s = s.replace("Oopsie, that sounded a little different. Let me help you.", "Let me help you. Let's say it together.")
    return json.loads(s)


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


def base_ck(name, ctype):
    ck = copy.deepcopy(SRC_CKS[20])  # #21, a free-answer cta_simplify of 2584: carries every runtime field
    for k in ("question", "question_guide", "response_guide", "image_listening", "media_list"):
        ck[k] = None
    ck.update({"name": name, "type": ctype, "cache_hash_question": None, "cache_hash_guide": None,
               "type_cta_simplify": "base"})
    return ck


# ---------------------------------------------------------------- chunk bot (2584)
chunk_cks = []
for i in range(4, 22):
    ck = copy.deepcopy(SRC_CKS[i - 1])
    before = json.dumps(ck, ensure_ascii=False)
    if i == 4:
        ck["question"] = "<emotion type=\"excited\"/> Today, we're going to discover how people get ready for a trip! <next_ckp/>"
    ck = drop_name(ck)
    after = json.dumps(ck, ensure_ascii=False)
    if after != before:
        if ck.get("question") != json.loads(before).get("question"):
            ck["cache_hash_question"] = None
        if ck.get("response_guide") != json.loads(before).get("response_guide"):
            ck["cache_hash_guide"] = None
    chunk_cks.append(ck)
bridge = base_ck("Kết bài - Nối sang nhà An Linh", "narrative")
bridge["question"] = ("<emotion type=\"happy\"/> Cậu dạy tớ đủ 3 việc chuẩn bị rồi, vào va li hết! "
                      "Gia đình bạn An Linh cũng sắp đi xa đó. Mình qua nhà An Linh xem nha! <next_ckp/>")
chunk_cks.append(bridge)
chunk = wrap(chunk_cks, "learn_chunk", "A2 - Trải nghiệm 30p - Học cụm (cắt từ 2584)",
             "Bot learn v2 cho buổi trải nghiệm 30 phút A2, nhúng vào graph chính bằng SubGraphNode. Ckp gốc 2584 "
             "#4-#21 (pack my suitcase, choose my clothes, prepare some snacks); #4 bỏ câu mở chung; [[name]] bỏ; "
             "#22 thay bằng câu nối sang nhà An Linh.")


# ---------------------------------------------------------------- sentence bot (workflow 764)
def wf_ck(c):
    return WF["parts"][0]["checkpoints"][c - 1]


class Media:
    def __init__(self):
        self.items = []

    def tag(self, mid, image=None, audio=None, desc="", kind="for_question"):
        if not any(m["id"] == mid for m in self.items):
            self.items.append({"id": mid, "type": kind, "score": None, "audio_url": audio or "",
                               "image_url": image or "", "media_description": desc})
        return f"[MEDIA:{mid}]"


def speak(resps, media, prefix, desc, kind="for_question"):
    out = []
    for i, r in enumerate(resps, 1):
        text = (r.get("text") or "").replace("’", "'").replace("  ", " ").strip()
        if r.get("sound") or r.get("media"):
            out.append(media.tag(f"{prefix}_{i}", r.get("media"), r.get("sound"), desc, kind))
        if text:
            out.append(text)
    return " ".join(out)


def loop_resps(c, intent, loop):
    it = next(i for i in wf_ck(c)["intents"] if i["name"] == intent)
    lp = it["loops"][min(loop, len(it["loops"]) - 1)]
    rs = lp["response"] if isinstance(lp["response"], list) else [lp["response"]]
    out = []
    for r in rs:
        out += r.get("pika_responses") or []
    return out


def listening(c):
    return next((r.get("image_listening") for r in wf_ck(c)["question"]["pika_responses"] if r.get("image_listening")), None)


PLAY_ONLY = "Chỉ phát đoạn thu âm, không nói thêm gì: "

riddle = base_ck("Câu nối - Đố đảo Lý Sơn", "cta_simplify")
riddle["question"] = ("<emotion type=\"excited\"/> Đố cậu nha: hòn đảo nào ở Quảng Ngãi nổi tiếng trồng tỏi? "
                      "Phú Quốc hay Lý Sơn?")
riddle["response_guide"] = {"tool": None, "turns": [{"turn": 1, "cases": [], "turn_guide": ""}], "ref_text": None,
                            "global_guide": (
    "Case 1 — Trẻ nói Lý Sơn: <emotion type=\"excited\"/> [Khen ngắn] Đúng rồi, Lý Sơn! Nhà An Linh sắp ra đảo Lý Sơn "
    "ăn Tết đó. Mình đi xem nha! <next_ckp/>\n\n"
    "Case 2 — Các trường hợp còn lại (nói Phú Quốc, không biết, im lặng, nói chuyện khác): <emotion type=\"happy\"/> "
    "[Không nói trẻ sai] Là đảo Lý Sơn đó! Nhà An Linh sắp ra đảo Lý Sơn ăn Tết. Mình đi xem nha! <next_ckp/>")}

# #1: the Tet intro; every intent plays the same "Just start the conversation" line and moves on.
m1 = Media()
intro = base_ck("#1 - Nhà An Linh đi Lý Sơn ăn Tết", "cta_simplify")
intro["question"] = speak(wf_ck(1)["question"]["pika_responses"], m1, "c1q", "Tết intro: An Linh's family is going to Lý Sơn Island")
go_on = speak(loop_resps(1, "intent_ready", 0), m1, "c1go", "An Linh's family greets the child", "for_response")
intro["media_list"] = m1.items
intro["response_guide"] = {"tool": None, "turns": [{"turn": 1, "cases": [], "turn_guide": ""}], "ref_text": None,
                           "global_guide": f"Case 1 — Mọi trường hợp (sẵn sàng, chưa sẵn sàng, im lặng, nói chuyện khác): {go_on} <next_ckp/>"}

ASK_RIGHT = ("Trẻ hỏi được câu 'What do you need to get ready for the trip?' hoặc câu cùng ý ('What do you need?', "
             "'What do you need to prepare?', 'What do you need to get ready?'), kể cả sai ngữ pháp nhỏ")


def ask_family(c, who, desc):
    """Child asks a family member the target question; two turns as in the workflow (retry, then model and move on)."""
    m = Media()
    ck = base_ck(f"#{c} - Bé hỏi {who}", "cta_simplify")
    ck["question"] = speak(wf_ck(c)["question"]["pika_responses"], m, f"c{c}q", desc)
    ck["image_listening"] = listening(c)
    ok = speak(loop_resps(c, "intent_true", 0), m, f"c{c}ok", f"{who} answers what they need", "for_response")
    retry = speak(loop_resps(c, "intent_false", 0), m, f"c{c}retry", "invites the child to try asking again", "for_response")
    model = speak(loop_resps(c, "intent_false", 1), m, f"c{c}model", f"models the question, {who} answers", "for_response")
    ck["media_list"] = m.items
    ck["response_guide"] = {"tool": None, "ref_text": None, "global_guide": "", "turns": [
        {"turn": 1, "cases": [], "turn_guide": (
            f"• Case 1 ({ASK_RIGHT}): {PLAY_ONLY}{ok} <next_ckp/>\n\n"
            f"• Case 2 (Các trường hợp còn lại: hỏi sai, không biết, im lặng, nói chuyện khác): {PLAY_ONLY}{retry}")},
        {"turn": 2, "cases": [], "turn_guide": (
            f"• Case 1 ({ASK_RIGHT}): {PLAY_ONLY}{ok} <next_ckp/>\n\n"
            f"• Case 2 (Các trường hợp còn lại): {PLAY_ONLY}{model} <next_ckp/>")}]}
    return ck


SAY_RIGHT = ("Trẻ nói một câu có 'I need' kèm một món trong danh sách (suitcase, clothes, shirt, t-shirt, snacks, tent, "
             "first-aid kit, board game), ví dụ 'I need a suitcase' hoặc 'I need to pack my suitcase'")


def answer_shop(c, n, with_intro=False):
    """Child, as An Linh, answers Auntie Bay with 'I need ...'; one turn as in the workflow."""
    m = Media()
    ck = base_ck(f"#{c} - Bé là An Linh, trả lời câu {n}", "cta_simplify")
    ck["question"] = speak(wf_ck(c)["question"]["pika_responses"], m, f"c{c}q",
                           "Auntie Bảy's Tết shop; the child is An Linh and answers with 'I need ...'")
    ck["image_listening"] = listening(c) or "https://smedia.stepup.edu.vn/robot/emotion/gifs/toilyson38lisa1fix1.jpg"
    ok = speak(loop_resps(c, "intent_true", 0), m, f"c{c}ok", "Auntie Bảy replies", "for_response")
    other = speak(loop_resps(c, "intent_false", 0), m, f"c{c}other", "Auntie Bảy replies", "for_response")
    ck["media_list"] = m.items
    ck["response_guide"] = {"tool": None, "turns": [{"turn": 1, "cases": [], "turn_guide": ""}], "ref_text": None,
                            "global_guide": (
        f"Case 1 — {SAY_RIGHT}: {PLAY_ONLY}{ok} <next_ckp/>\n\n"
        f"Case 2 — Các trường hợp còn lại (không có 'I need', không biết, im lặng, nói chuyện khác): {PLAY_ONLY}{other} <next_ckp/>")}
    return ck


m10 = Media()
end = base_ck("#10 - Cả nhà lên đường ra đảo", "narrative")
end["question"] = speak(wf_ck(10)["question"]["pika_responses"], m10, "c10q", "The family sets off to Lý Sơn Island") + " <next_ckp/>"
end["media_list"] = m10.items

sentence = wrap([
    riddle,
    intro,
    ask_family(2, "bố An Linh", "An Linh's dad on the sofa; the child asks him what he needs for the trip"),
    ask_family(3, "mẹ An Linh", "An Linh's mom; the child asks her what she needs for the trip"),
    answer_shop(6, 1),
    answer_shop(7, 2),
    answer_shop(8, 3),
    end,
], "learn_sentence", "A2 - Trải nghiệm 30p - Học câu (chuyển từ workflow 764)",
    "Bot learn v2 cho buổi trải nghiệm 30 phút A2, nhúng vào graph chính bằng SubGraphNode. Mở bằng câu đố Lý Sơn, "
    "rồi chuyển từ workflow 764 (robot lesson 869) #1-#3, #6-#8, #10: lời người nhà An Linh là file thu âm gốc, mỗi "
    "nhánh phát đúng file của nhánh đó; bỏ #4-#5 (hỏi thêm 2 người) và #9 (câu trả lời thứ 4).")

for tag, payload in (("learn_chunk", chunk), ("learn_sentence", sentence)):
    with open(f"{OUT}/{tag}_create.json", "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(tag, "ckp:", len(payload["graph"]["nodes"][0]["checkpoints"]))
