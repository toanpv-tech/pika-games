"""Build the two B1 learn bots (v2, graph with one LEARN node) for the 30-min trial.

Chunk bot: cut from agent 2452 (robot lesson 2582), checkpoints #4-#21; #4 loses the generic opener, #5 says
"prawn fritters" like the later steps, #22 (next mission) becomes a bridge to An Linh, and [[name]] is dropped.
Sentence bot: cut from agent 2400 (robot lesson 2562), checkpoints #5-#28; #23 and #27 get a second turn so a child
who says only the snack, or forgets "enjoys", hears the full sentence and tries once more.
Usage: python3 build_learn_b1.py <source dir> <out dir>
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


def drop_name(obj):
    """[[name]] comes from the device account profile, which on a shared demo robot is not the child."""
    s = json.dumps(obj, ensure_ascii=False)
    s = s.replace("Oh [[name]], ", "Oh, ")
    s = re.sub(r",\s*\[\[name\]\]", "", s)
    # The trial never tells the child they got it wrong.
    s = s.replace("Oopsie, that sounded a little different. Let me help you.", "Let me help you. Let's say it together.")
    return json.loads(s)


def cut(src, keep, edits=None, guides=None):
    cks = src["task_chain"][0]["checkpoints"]
    out = []
    for i in keep:
        orig = cks[i - 1]
        ck = drop_name(copy.deepcopy(orig))
        if edits and i in edits:
            ck["question"] = edits[i](orig["question"])
        if guides and i in guides:
            ck["response_guide"] = guides[i]
        if ck.get("question") != orig.get("question"):
            ck["cache_hash_question"] = None
        if ck.get("response_guide") != orig.get("response_guide"):
            ck["cache_hash_guide"] = None
        out.append(ck)
    return out


def wrap(src, checkpoints, node_id, name, desc):
    r = copy.deepcopy(src)
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


def must_replace(old, new):
    def f(q):
        if old not in q:
            raise SystemExit(f"'{old}' not found")
        return q.replace(old, new)
    return f


# ---------------------------------------------------------------- chunk bot (2452)
CH = load("bot2452_prod.json")
chunk_cks = cut(CH, range(4, 22), edits={
    4: lambda q: ("<emotion type=\"happy_2\"/> Today, we're going to discover Vietnamese snacks. "
                  "Let's learn three special things we can try. <next_ckp/>"),
    5: must_replace("crispy, golden shrimp fritters", "crispy, golden prawn fritters"),
})
bridge = copy.deepcopy(CH["task_chain"][0]["checkpoints"][21])  # #22, a narrative of 2452
bridge.update({"name": "Kết bài - Nối sang An Linh", "cache_hash_question": None, "cache_hash_guide": None,
               "media_list": [],
               "question": ("<emotion type=\"happy\"/> Cậu dạy tớ đủ 3 món rồi, ghi vào sổ hết! Bạn An Linh cũng "
                            "đang gọi Kenbee ra quầy quà vặt đó. Mình nghe xem hai bạn thích món nào nhất nha. "
                            "Let's see! <next_ckp/>")})
chunk_cks.append(drop_name(bridge))
chunk = wrap(CH, chunk_cks, "learn_chunk", "B1 - Trải nghiệm 30p - Học cụm (cắt từ 2452)",
             "Bot learn v2 cho buổi trải nghiệm 30 phút B1, nhúng vào graph chính bằng SubGraphNode. Ckp gốc 2452 "
             "#4-#21 (prawn fritters, sesame balls, coconut jelly); #4 bỏ câu mở chung; #5 'shrimp' thành 'prawn'; "
             "[[name]] bỏ; #22 thay bằng câu nối sang An Linh.")

# ---------------------------------------------------------------- sentence bot (2400)
SNACK_GUIDE = {"tool": None, "ref_text": None, "global_guide": "", "turns": [
    {"turn": 1, "cases": [], "turn_guide": (
        "• Case 1 (Trẻ nói đủ câu 'I enjoy ... the most' với một món ăn vặt): <emotion type=\"admire\"/> [Khen cụ thể "
        "là trẻ nói đủ cả câu, nói Pika thấy đó là lựa chọn tuyệt, không hỏi thêm] <next_ckp/>\n\n"
        "• Case 2 (Trẻ chỉ nói tên món, ví dụ 'sesame balls', hoặc thiếu 'the most'): <emotion type=\"encouraging\"/> "
        "[Khen trẻ chọn món hay] Let's say the whole sentence: I enjoy <món trẻ chọn> the most! [Mời trẻ nói lại cả câu "
        "một lần]\n\n"
        "• Case 3 (Im lặng, không biết, nói chuyện khác; nội dung không phù hợp thì lảng đi): <emotion type=\"encouraging\"/> "
        "[Nhẹ nhàng] For me, I enjoy coconut jelly the most! What about you? Say: I enjoy ... the most!")},
    {"turn": 2, "cases": [], "turn_guide": (
        "• Case 1 (Trẻ nói đủ câu 'I enjoy ... the most'): <emotion type=\"admire\"/> [Khen cụ thể] <next_ckp/>\n\n"
        "• Case 2 (Các trường hợp còn lại): <emotion type=\"encouraging\"/> [Nói mẫu đủ câu với món trẻ chọn, nếu "
        "không có thì dùng coconut jelly] I enjoy ... the most! [Bảo chúng mình sẽ luyện thêm sau, không hỏi thêm] "
        "<next_ckp/>")}]}

TUNG_GUIDE = {"tool": None, "ref_text": None, "global_guide": "", "turns": [
    {"turn": 1, "cases": [], "turn_guide": (
        "• Case 1 (Trẻ nói đúng hoặc gần đúng 'He enjoys sesame balls the most', có 'enjoys'): [MEDIA:tenten] "
        "[That's right. He enjoys sesame balls the most.] <next_ckp/>\n\n"
        "• Case 2 (Trẻ nói 'He enjoy' thiếu -s, hoặc chỉ nói 'sesame balls'): <emotion type=\"encouraging\"/> [Khen trẻ "
        "nói đúng món] Listen: He enjoy-SSS sesame balls the most! [Nhấn rõ đuôi -s, mời trẻ nói lại cả câu một lần]\n\n"
        "• Case 3 (Các trường hợp còn lại): [MEDIA:nen] [He enjoys sesame balls the most. Now you say it!]")},
    {"turn": 2, "cases": [], "turn_guide": (
        "• Case 1 (Trẻ nói 'He enjoys sesame balls the most' hoặc gần đúng): [MEDIA:tenten] [That's right. He enjoys "
        "sesame balls the most.] <next_ckp/>\n\n"
        "• Case 2 (Các trường hợp còn lại): [MEDIA:nen] [He enjoys sesame balls the most. Yummy. He recommends it to "
        "the students, too.] [Bảo chúng mình sẽ luyện thêm sau] <next_ckp/>")}]}

SE = load("bot2400_prod.json")
sentence = wrap(SE, cut(SE, range(5, 29), guides={23: SNACK_GUIDE, 27: TUNG_GUIDE}), "learn_sentence",
                "B1 - Trải nghiệm 30p - Học câu (cắt từ 2400)",
                "Bot learn v2 cho buổi trải nghiệm 30 phút B1, nhúng vào graph chính bằng SubGraphNode. Ckp gốc 2400 "
                "#5-#28 (I enjoy ... the most, He enjoys ... the most); #23 và #27 thêm lượt 2 cho trẻ nói đủ câu; "
                "bỏ mở đầu chung #1-#4 và lời tạm biệt #29.")

for tag, payload in (("learn_chunk", chunk), ("learn_sentence", sentence)):
    with open(f"{OUT}/{tag}_create.json", "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(tag, "ckp:", len(payload["graph"]["nodes"][0]["checkpoints"]))
