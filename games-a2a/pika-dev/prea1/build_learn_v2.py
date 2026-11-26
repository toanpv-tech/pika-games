"""Build the two Pre-A1 learn bots (v2, graph with one LEARN node) for the 30-min trial.

Source: prod dumps of agents 1528 (chunk) and 1737 (sentence). Checkpoints are trimmed to
rice / noodles / soup, edited lines get their cache hash cleared, and [[name]] is replaced
because the trial runs on a shared demo account whose profile name is not the child's.
Usage: python3 build_learn_v2.py <source dir with bot1528_prod.json, bot1737_prod.json> <out dir>
"""
import copy
import json
import re
import sys

SD = sys.argv[1]
OUT = sys.argv[2]


def load(bot_id):
    with open(f"{SD}/bot{bot_id}_prod.json", encoding="utf-8") as f:
        return json.load(f)["result"]


def media_ids(obj):
    return set(re.findall(r"\[MEDIA:([^\]]+)\]", json.dumps(obj, ensure_ascii=False)))


def replace_in(ck, field, old, new):
    val = ck.get(field)
    if val is None:
        return False
    s = val if isinstance(val, str) else json.dumps(val, ensure_ascii=False)
    if old not in s:
        return False
    s = s.replace(old, new)
    ck[field] = s if isinstance(val, str) else json.loads(s)
    return True


def build(src_id, keep, edits, renames, node_id, name, desc, guides=None):
    r = copy.deepcopy(load(src_id))
    task = r["task_chain"][0]
    src = task["checkpoints"]
    out = []
    for i in keep:
        ck = copy.deepcopy(src[i - 1])
        if i in edits:
            ck["question"] = edits[i]
            ck["cache_hash_question"] = None
        if guides and i in guides:
            ck["response_guide"] = guides[i]
            ck["cache_hash_guide"] = None
        for field, old, new in renames.get(i, []):
            if not replace_in(ck, field, old, new):
                raise SystemExit(f"bot {src_id} ckp #{i}: '{old}' not found in {field}")
            ck["cache_hash_question" if field == "question" else "cache_hash_guide"] = None
        if isinstance(ck.get("media_list"), list):
            used = media_ids([ck.get("question"), ck.get("question_guide"), ck.get("response_guide")])
            ck["media_list"] = [m for m in ck["media_list"] if m.get("id") in used]
        out.append(ck)
    left = [i for i, ck in enumerate(out, 1) if "[[name]]" in json.dumps(ck, ensure_ascii=False)]
    if left:
        raise SystemExit(f"bot {src_id}: [[name]] still in new ckp {left}")
    task["checkpoints"] = out
    r["graph"] = {
        "nodes": [{
            "node_id": node_id, "prompt": "", "type": "LEARN", "tools": [], "pivots": [], "nexts": [],
            "checkpoints": out, "input_schema_key": None, "start_message": "", "hooks": [],
            "max_turns": None, "pre_llm_pipeline": None, "dynamic_checkpoint_builder": None,
            "dynamic_checkpoint_config": {}, "tts_provider_override": None, "learn_v2": True,
            "learn_v2_keep_dev_prompt": False, "learn_v2_keep_model": False,
        }],
        "global_pivots": [],
        "global_tools": list(task.get("tools") or []),
        "global_hooks": [],
        "system_prompt": task["SYSTEM_TASK_DESCRIPTION"],
        "version": "v2",
        "strict": False,
        "use_intent": "full",
    }
    r["name"], r["description"] = name, desc
    for k in ("id", "created_at", "updated_at"):
        r.pop(k, None)
    return r


chunk = build(
    1528,
    [4, 5, 6, 7, 8, 9, 10, 17, 18, 19, 20],
    {
        4: "[MEDIA:family_dining_table_intro] What food do you like? Today, let's learn about food! <next_ckp/>",
        19: "[MEDIA:recap_rice] <eng> rice </eng>, [MEDIA:recap_noodles] <eng> noodles </eng>, [MEDIA:recap_soup] <eng> soup </eng>. <next_ckp/>",
        20: "[MEDIA:ending_screen] Cậu dạy tớ đủ tên 3 món rồi! Ở căn tin trường Pet Pet, bạn Justin hay hỏi mọi người thích ăn gì đó. Mình qua đó nghe cùng nhau nha. Mở cánh cửa vàng nào! <next_ckp/>",
    },
    {
        5: [("question", "[[name]] ơi! Cơm", "Cậu ơi! Cơm")],
        # The trial never tells the child they got it wrong.
        6: [("response_guide", "Nào [[name]] ơi,", "Nào cậu ơi,"),
            ("response_guide", "Có gì đó chưa đúng lắm nè!", "Mình nói lại cùng nhau nha!")],
        7: [("question", "Tiếp nào [[name]] ơi!", "Tiếp nào cậu ơi!")],
        8: [("response_guide", "Nào [[name]] ơi,", "Nào cậu ơi,")],
        9: [("question", "[[name]] ơi! Canh", "Cậu ơi! Canh")],
        10: [("response_guide", "Nào [[name]] ơi,", "Nào cậu ơi,")],
        18: [("question", "[[name]] giỏi quá trời", "Cậu giỏi quá trời")],
    },
    "learn_chunk",
    "Pre A1 - Trải nghiệm 30p - Học cụm (cắt từ 1528)",
    "Bot learn v2 cho buổi trải nghiệm 30 phút, nhúng vào graph chính bằng SubGraphNode. Ckp gốc 1528 #4-#10, #17-#20 (rice, noodles, soup); #4 bỏ câu tiếng Việt (graph chính đã nói câu nối); #19 đổi lời; #20 đổi lời, dẫn sang căn tin Pet Pet; [[name]] đổi thành 'cậu'.",
)

# 1737 #20 has one turn that always moves on. The trial script wants a child who says only
# "soup" to hear the full sentence and get one more try, so turn 1 retries below 0.85.
SOUP_NOT_TRYING = "Trẻ CÓ nói tiếng Anh và đang cố đọc theo từ mẫu (kể cả phát âm chưa chuẩn, thiếu hoặc thừa từ) thì KHÔNG chọn nhánh này — CHỈ dùng nhánh này khi trẻ im lặng, nói tiếng Việt, nói \"tớ không biết\", hoặc nói chuyện khác không liên quan tới từ mẫu: "
SOUP_GUIDE = {
    "tool": "pronun_check_v2_simplify",
    "turns": [
        {
            "turn": 1,
            "cases": [
                {"lower_bound": 0.85, "response_guide": "<emotion type=\"playful_2\"/> [Khen ngợi trẻ làm rất tốt!]  [We say, I like soup!] <next_ckp/>"},
                {"lower_bound": 0.6, "response_guide": "<emotion type=\"encouraging\"/> [Khen trẻ đã nói được rồi, chỉ cần nói đủ cả câu] [Listen: I like soup! Cậu nói lại cả câu với tớ một lần nữa nhé!]"},
                {"lower_bound": 0, "response_guide": "<emotion type=\"encouraging\"/> [Khen trẻ đã cố gắng] [Listen carefully: I like soup! Cậu nói lại cả câu với tớ một lần nữa nhé!]"},
            ],
            "turn_guide": SOUP_NOT_TRYING + "<emotion type=\"calm\"/> [Lảng đi, gently redirect] [We say, I like soup! Cậu nói theo tớ nhé!]",
        },
        {
            "turn": 2,
            "cases": [
                {"lower_bound": 0.85, "response_guide": "<emotion type=\"playful_2\"/> [Khen ngợi trẻ làm rất tốt!]  [I like soup! Yummy!] <next_ckp/>"},
                {"lower_bound": 0, "response_guide": "<emotion type=\"encouraging\"/> [We say, I like soup!] [Khen trẻ đã cố gắng, bảo chúng mình sẽ luyện tập thêm sau] <next_ckp/>"},
            ],
            "turn_guide": SOUP_NOT_TRYING + "<emotion type=\"calm\"/> [We say, I like soup!] [Bảo chúng mình sẽ luyện tập thêm sau] <next_ckp/>",
        },
    ],
    "ref_text": "I like soup",
    "global_guide": "",
}

sentence = build(
    1737,
    [5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19, 20, 21, 28],
    {
        28: "[MEDIA:summary_all_foods_visual] Wow! We learned about food we like today! Rice, noodles, and soup. Amazing work! <next_ckp/>",
    },
    {
        13: [("response_guide", "Hey, hey [[name]], let's say", "Hey, hey, let's say")],
    },
    "learn_sentence",
    "Pre A1 - Trải nghiệm 30p - Học câu (cắt từ 1737)",
    "Bot learn v2 cho buổi trải nghiệm 30 phút, nhúng vào graph chính bằng SubGraphNode. Ckp gốc 1737 #5-#13, #15-#21, #28 (I like rice / noodles / soup); #20 thêm lượt 2 cho trẻ nói lại cả câu; #28 đổi lời; bỏ #29, lời tạm biệt do graph chính nói.",
    guides={20: SOUP_GUIDE},
)
for tag, payload in (("learn_chunk", chunk), ("learn_sentence", sentence)):
    with open(f"{OUT}/{tag}_create.json", "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(tag, "ckp:", len(payload["graph"]["nodes"][0]["checkpoints"]))
