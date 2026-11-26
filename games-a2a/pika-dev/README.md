# Pika Trải Nghiệm 30 phút

Buổi trải nghiệm 30 phút cho học sinh lớp 1–5, dựng theo kịch bản `pika-dev.html` (bản 4, 20/11/2026). Mỗi trình độ là một agent BotGraph v2 bọc trong một robot lesson một bước. Đã làm đủ 4 trình độ Pre-A1, A1, A2, B1. Phần dùng chung mọi trình độ (sự thật canon về Pika, luật nói chuyện, pivot, tool, bố cục node) nằm ở `trial_graph.py`; mỗi trình độ chỉ viết nội dung riêng.

## Pre-A1 trên dev (`https://platform-builder-api.stepup.edu.vn`)

| Thành phần | Id | version_id khi tạo | version_id hiện tại | Link |
|---|---|---|---|---|
| Robot lesson (id dùng để giao xuống robot) | 4006 | `6b0662e12002da129e4437b4` | (không đổi) | |
| Agent chính `Pre A1 - Trải nghiệm 30p` | 3787 | `6b0662cc2002da129e4437b2` | `6b068ae82002da129e443840` | https://platform-builder.stepup.edu.vn/agents/3787 |
| Bot learn Học cụm (cắt từ 1528) | 3785 | `6b0662ae2002da129e4437ae` | `6b068ae62002da129e44383e` | https://platform-builder.stepup.edu.vn/agents/3785 |
| Bot learn Học câu (cắt từ 1737) | 3786 | `6b0662b02002da129e4437b0` | `6b06865a2002da129e44382d` | https://platform-builder.stepup.edu.vn/agents/3786 |

Lần sửa ngày 25/11/2026 (sau khi so với kịch bản):
- 3785 bước #4: bỏ câu tiếng Việt vì trùng với câu nối của t3d.
- 3786 bước #20 "I like soup": thêm lượt 2. Bé nói chưa đủ câu thì Pika nói mẫu và mời bé nói lại một lần.
- 3787: mỗi node trò chuyện có câu chuyển vào phần mới. Node `greet` thêm lời mời bé lại gần khi bé hai lần không đáp.

Lần sửa thứ hai cùng ngày: hành trình "bé là thầy dạy Pika về món ăn" (3 agent review: câu chuyện, trải nghiệm lần đầu gặp robot, sư phạm Pre-A1). Pika cần biết tên món để mai đi căn tin trường Pet Pet, nơi Justin hỏi "What food do you like?"; mỗi món bé dạy được bỏ vào hộp cơm tưởng tượng ("Vào hộp!"). Pika xưng tớ – cậu, đúng canon backstory (không ăn được, chỉ "ăn" điện; 10 tuổi Popa, cơ thể mới vài tháng; mê gà rán). Bé chọn món của mình trong rice, noodles, soup; cuối buổi nhận câu thần chú riêng "I like <món>!". Có luật cho trẻ nhút nhát, giới hạn khen và đùa; bé muốn dừng thì Pika dừng, không dụ. 3785 bước #20 dẫn sang Justin ở căn tin.

Bài gốc trong lộ trình (robot lesson 1744 → agent 1528, robot lesson 1946 → agent 1737) không bị sửa.

Đã giao robot lesson 4006 xuống robot `7CB436843I55J3BQ6298` ngày 25/11/2026 bằng Pika Studio (`pika-ctl cmd.assignLesson id=4006`), backend trả HTTP 200. Giao lại sau mỗi lần sửa cùng ngày (lần gần nhất sau khi đổi sang hành trình "bé là thầy dạy Pika"), đều HTTP 200. Kết quả này chỉ có nghĩa là server đã nhận lệnh.

Lần sửa ngày 25/11/2026 (sau khi soạn `khung-kich-ban.md`): bỏ câu ngầm nói bé sai trong lời sửa của bài cụm, giống A1. Pre-A1 3785 bước "Luyện tập phát âm: rice": "Có gì đó chưa đúng lắm nè!" thành "Mình nói lại cùng nhau nha!" (version `6b069a632002da129e443886`). A2 3791 và B1 3794, ba bước "Produce": "Oopsie, that sounded a little different. Let me help you." thành "Let me help you. Let's say it together." (3791 version `6b069a6a2002da129e443888`, 3794 version `6b069a6f2002da129e44388a`). Chỉ vá `response_guide` của các bước đó vào bản kéo từ host. Giao lại lesson 4006 sau lần sửa, HTTP 200.

## Luồng của agent 3787

| Node | Phần kịch bản | Giới hạn |
|---|---|---|
| `greet` | ① Bụng Pika kêu "rột rột", hỏi tên và tuổi, giao vai thầy dạy món ăn | 4 lượt |
| `t3a` | 3a Pika đoán bừa, bé sửa; bé chọn món của mình trong rice, noodles, soup | 9 lượt, nhắc chốt ở lượt 8 |
| `t3b` | 3b Ba bí mật ăn uống của Pika (từ backstory), bé hỏi một câu | 6 lượt, nhắc chốt ở lượt 5 |
| `t3c` | 3c Hát `yum_yum_time` (97 giây) hoặc kể chuyện "Bạn mèo kén ăn" | 5 lượt |
| `t3d` | 3d Ba câu đố bỏ mì, canh, cơm vào hộp; câu cầu sang Justin ở căn tin | 8 lượt, nhắc chốt ở lượt 7 |
| `learn_chunk` | ④ Học cụm: SubGraph tới bot 3785 | theo checkpoint |
| `learn_sentence` | ⑤ Học câu: SubGraph tới bot 3786 | theo checkpoint |
| `goodbye` | ⑦ Pika nếm giả vờ kiểu Popa, bé nói "I like …", câu thần chú riêng nói với bố mẹ, chào bằng tên bé | tối đa 5 lượt |

Game ⑥ "Hộp cơm bí mật" để đợt 2: cần viết Lua riêng (khoảng 3–4 ngày), đăng game có `gameId`, rồi thêm node GAME giữa `learn_sentence` và `goodbye`.

## A1 trên dev (`https://platform-builder-api.stepup.edu.vn`)

| Thành phần | Id | version_id khi tạo | Link |
|---|---|---|---|
| Robot lesson (id dùng để giao xuống robot) | 4007 | `6b0691892002da129e443871` | |
| Agent chính `A1 Trải nghiệm 30p` | 3790 | `6b0691802002da129e44386f` | https://platform-builder.stepup.edu.vn/agents/3790 |
| Bot learn Học cụm (từ workflow lesson 950, chuyển sang checkpoint) | 3788 | `6b0691702002da129e44386b` | https://platform-builder.stepup.edu.vn/agents/3788 |
| Bot learn Học câu (cắt từ agent 2897) | 3789 | `6b0691712002da129e44386d` | https://platform-builder.stepup.edu.vn/agents/3789 |

Hành trình: bé là hướng dẫn viên trong chuyến cắm trại đầu tiên của Pika cùng nhà KenBi; Pika chưa biết "đọc bầu trời", mỗi kiểu trời bé dạy được bỏ vào album ảnh tưởng tượng ("Vào album!"). Cụm mục tiêu a sunny morning, a cool breeze, a clear sky và câu "It's ...". Bé chọn kiểu trời của mình ở t3a; cuối buổi nhận câu thần chú "It's <kiểu trời>!" để sáng mai nhìn ra cửa sổ nói thử.

Bài gốc (workflow lesson 950, robot lesson 1209 và 3162, agent 2897) không bị sửa.

| Node của 3790 | Nội dung | Giới hạn |
|---|---|---|
| `greet` | Pika hồi hộp đi cắm trại lần đầu, hỏi tên và tuổi, giao vai hướng dẫn viên | 4 lượt |
| `t3a` | Sunny or cool, bé chọn kiểu trời của mình; đi chơi cuối tuần ở đâu; đã cắm trại chưa | 9 lượt, nhắc chốt ở lượt 8 |
| `t3b` | Ba bí mật của Pika (backstory), bé hỏi một câu | 6 lượt, nhắc chốt ở lượt 5 |
| `t3c` | Mặc định kể chuyện "Đám mây nhỏ đi tìm nắng"; bé chọn hát thì hát `rain_rain_go_away` (đổi từ `yum_yum_time` ngày 25/11/2026, version 3790 `6b069aef2002da129e44388c`) | 5 lượt |
| `t3d` | Ba câu đố mặt trời, gió, trời trong; câu cầu sang cảnh nhà KenBi lên xe | 8 lượt, nhắc chốt ở lượt 7 |
| `learn_chunk` | SubGraph tới bot 3788 (13 checkpoint) | theo checkpoint |
| `learn_sentence` | SubGraph tới bot 3789 (16 checkpoint) | theo checkpoint |
| `goodbye` | Lật album, bé nói "It's …", câu thần chú, chào bằng tên bé | tối đa 5 lượt |

Lint bot learn còn cảnh báo T001, G003, M004: có sẵn ở bài gốc hoặc là chủ ý (hai bước cùng câu mẫu nhưng khác việc), giữ nguyên.

Đã giao robot lesson 4007 xuống robot `7CB436843I55J3BQ6298` ngày 25/11/2026 bằng Pika Studio (`pika-ctl cmd.assignLesson id=4007`), backend trả HTTP 200. Kết quả này chỉ có nghĩa là server đã nhận lệnh.

## A2 trên dev (`https://platform-builder-api.stepup.edu.vn`)

| Thành phần | Id | version_id khi tạo | Link |
|---|---|---|---|
| Robot lesson (id dùng để giao xuống robot) | 4008 | `6b06945f2002da129e443879` | |
| Agent chính `A2 Trải nghiệm 30p` | 3793 | `6b0694582002da129e443877` | https://platform-builder.stepup.edu.vn/agents/3793 |
| Bot learn Học cụm (cắt từ agent 2584) | 3791 | `6b06944c2002da129e443873` | https://platform-builder.stepup.edu.vn/agents/3791 |
| Bot learn Học câu (từ workflow lesson 764, chuyển sang checkpoint) | 3792 | `6b06944d2002da129e443875` | https://platform-builder.stepup.edu.vn/agents/3792 |

Hành trình: nhà An Linh ra đảo Lý Sơn ăn Tết, Pika được đi cùng, chuyến đi đầu tiên của Pika nhưng Pika chưa biết chuẩn bị; bé là huấn luyện viên chuẩn bị, mỗi thứ bé dạy được bỏ vào va li tưởng tượng ("Vào va li!"). Cụm mục tiêu pack my suitcase, choose my clothes, prepare some snacks và câu "I need to ...". Bé chọn việc của mình ở t3a; cuối buổi nhận câu thần chú "I need to <việc>!". A2 là lớp 4–5 có học thêm nên Pika nói tiếng Anh trước rồi thêm một câu tiếng Việt (`lang_rule` trong `a2/build_main_graph.py`).

Bài gốc (robot lesson 2977 và 869, agent 2584, workflow lesson 764) không bị sửa.

| Node của 3793 | Nội dung | Giới hạn |
|---|---|---|
| `greet` | Pika sắp đi du lịch lần đầu, hỏi tên và tuổi, giao vai huấn luyện viên | 4 lượt |
| `t3a` | Đi du lịch với gia đình chưa; car, plane or boat; hay mang gì; bé chọn việc chuẩn bị của mình | 9 lượt, nhắc chốt ở lượt 8 |
| `t3b` | Ba bí mật của Pika, bé hỏi một câu (gợi ý: Pika mang gì khi đi du lịch) | 6 lượt, nhắc chốt ở lượt 5 |
| `t3c` | Mặc định kể chuyện "Chiếc va li hay quên"; bé chọn hát thì hát `the_wheels_on_the_bus` | 5 lượt |
| `t3d` | Ba câu đố xe buýt, mũ, va li; câu cầu vào bài | 8 lượt, nhắc chốt ở lượt 7 |
| `learn_chunk` | SubGraph tới bot 3791 (19 checkpoint: 2584 #4–#21 và câu nối sang nhà An Linh) | theo checkpoint |
| `learn_sentence` | SubGraph tới bot 3792 (8 checkpoint: đố đảo Lý Sơn, 764 #1–#3, #6–#8, #10) | theo checkpoint |
| `goodbye` | Kiểm va li giả vờ, bé nói "I need to …", câu thần chú, "Have a nice trip", chào bằng tên bé | tối đa 5 lượt |

Bot 3792: lời người nhà An Linh và cô Bảy chỉ có trong file thu âm của workflow 764 (không có chữ), nên mỗi nhánh phát đúng file mp3 gốc của nhánh đó và dặn Pika không nói thêm; điều kiện nhánh lấy từ mô tả intent của workflow. Chưa kiểm trên robot: Pika có im khi phát thu âm không, bước #6 có nhắc tới hai người nhà đã cắt (#4–#5) không, câu "I need to pack my suitcase" có vào nhánh đúng không.

Lint bot 3791 còn cảnh báo T001 (bước nói theo và bước sửa cùng cụm, thiết kế gốc của 2584), giữ nguyên.

Đã giao robot lesson 4008 xuống robot `7CB436843I55J3BQ6298` ngày 25/11/2026 bằng Pika Studio (`pika-ctl cmd.assignLesson id=4008`), backend trả HTTP 200. Kết quả này chỉ có nghĩa là server đã nhận lệnh.

## B1 trên dev (`https://platform-builder-api.stepup.edu.vn`)

| Thành phần | Id | version_id khi tạo | Link |
|---|---|---|---|
| Robot lesson (id dùng để giao xuống robot) | 4009 | `6b06986d2002da129e443884` | |
| Agent chính `B1 Trải nghiệm 30p` | 3796 | `6b0698672002da129e443882` | https://platform-builder.stepup.edu.vn/agents/3796 |
| Bot learn Học cụm (cắt từ agent 2452) | 3794 | `6b06985c2002da129e44387e` | https://platform-builder.stepup.edu.vn/agents/3794 |
| Bot learn Học câu (cắt từ agent 2400) | 3795 | `6b06985e2002da129e443880` | https://platform-builder.stepup.edu.vn/agents/3795 |

Hành trình: Pika không ăn được nhưng mê tưởng tượng đồ ăn (bụng kêu "rột rột"), giữ sổ tay ăn vặt tưởng tượng gửi về Popa ("Ghi vào sổ!"); bé là người dẫn Pika khám phá quầy quà vặt của Kenbee. Cụm mục tiêu prawn fritters, sesame balls, coconut jelly và câu "I enjoy ... the most". Bé chọn món của mình ở t3a; cuối buổi nói "I enjoy <món> the most" và nhận câu hỏi thần chú "Which Vietnamese snack do you enjoy the most?" để mai hỏi bạn. B1 là học sinh trường quốc tế nên Pika nói tiếng Anh là chính (`lang_rule` trong `b1/build_main_graph.py`).

Bài gốc (robot lesson 2582 và 2562, agent 2452 và 2400) không bị sửa.

| Node của 3796 | Nội dung | Giới hạn |
|---|---|---|
| `greet` | Bụng Pika kêu "rột rột", hỏi tên và tuổi, giao vai người dẫn khám phá món ăn vặt | 4 lượt |
| `t3a` | Tan học hay ăn gì, vì sao; quầy quà vặt gần nhà hoặc món bà, mẹ làm; bé chọn món của mình trong 3 món | 9 lượt, nhắc chốt ở lượt 8 |
| `t3b` | Ba bí mật của Pika, bé hỏi một câu (gợi ý: Pika có ăn được không) | 6 lượt, nhắc chốt ở lượt 5 |
| `t3c` | Mặc định kể chuyện "Robot lần đầu đi chợ quê"; bé chọn hát thì hát `yum_yum_time` (Pat-a-Cake trong kịch bản không có trong danh sách bài hát) | 5 lượt |
| `t3d` | Ba câu đố bánh chưng, thạch dừa, bánh rán vừng; câu cầu sang quầy của Kenbee | 8 lượt, nhắc chốt ở lượt 7 |
| `learn_chunk` | SubGraph tới bot 3794 (19 checkpoint: 2452 #4–#21, #5 "shrimp" thành "prawn", câu nối sang An Linh) | theo checkpoint |
| `learn_sentence` | SubGraph tới bot 3795 (24 checkpoint: 2400 #5–#28; #23 và #27 thêm lượt 2 cho trẻ nói đủ câu) | theo checkpoint |
| `goodbye` | Đọc sổ giả vờ, bé nói "I enjoy … the most", câu hỏi thần chú, chào bằng tên bé | tối đa 5 lượt |

Ghi chú bài gốc 2452: mô tả media của ba bước "Now listen to me!" (#7, #12, #17) mang chữ của bài khác ("feed the baby", "helping in the kitchen", "going to a cafe"); ảnh đi kèm đúng món nên audio nhiều khả năng đúng, cần nghe thử trên robot. Lint còn G001, R008 và field thừa C003 có sẵn ở bài gốc, giữ nguyên.

Đã giao robot lesson 4009 xuống robot `7CB436843I55J3BQ6298` ngày 25/11/2026 bằng Pika Studio (`pika-ctl cmd.assignLesson id=4009`), backend trả HTTP 200 (lần đầu lỗi mạng, thử lại thì được). Kết quả này chỉ có nghĩa là server đã nhận lệnh.

## Điều kiện khi chạy trên robot

- Tài khoản trên máy demo phải để chế độ ngôn ngữ `VI-EN`; bài không ép được song ngữ.
- Các node trò chuyện gọi bé bằng tên bé tự nói. Hai bot learn không dùng `[[name]]` (đã đổi thành "cậu") vì `[[name]]` lấy từ hồ sơ tài khoản.
- Giới hạn mỗi phần tính theo số lượt, không theo phút (runtime không có đồng hồ). Con số hiện tại là ước lượng, cần chỉnh sau khi đo.

## File

| File | Việc |
|---|---|
| `pika-dev.html` | Kịch bản gốc 4 trình độ |
| `prea1/build_main_graph.py --dev-tools` | Bản có thêm `sing_back` (bé ngân "la la", Pika hát lại) và `play_sound`. Ngày 25/11/2026 hai tool này mới có trên nhánh dev của runtime: graph có chúng bị staging/prod từ chối. Bản đang chạy không dùng cờ này |
| `prea1/build_learn_v2.py` | Dựng payload 2 bot learn từ dump 1528 và 1737: `python3 build_learn_v2.py source .` |
| `prea1/build_main_graph.py` | Dựng graph agent chính: `python3 build_main_graph.py main_v2.json 3785 3786` |
| `prea1/learn_chunk_create.json`, `prea1/learn_sentence_create.json`, `prea1/main_v2.json`, `prea1/robot_lesson_create.json` | Payload đã gửi lên dev |
| `prea1/source/` | Dump bài gốc (agent 1528, 1737; robot lesson 1744, 1946) đọc ngày 25/11/2026 |
| `prea1/pushed/` | Bản fetch lại sau lần ghi gần nhất, để đối chiếu |
| `prea1/personas.json`, `prea1/sim/` | Persona giả lập và log các lần chạy |
| `prea1/simulation-results.md` | Kết quả giả lập |
| `trial_graph.py` | Khung graph dùng chung mọi trình độ; file `build_main_graph.py` của từng trình độ gọi `trial_graph.build(...)` |
| `a1/build_learn_a1.py` | Dựng payload 2 bot learn A1 từ workflow lesson 950 và agent 2897: `python3 build_learn_a1.py source .` |
| `a1/build_main_graph.py` | Dựng graph agent A1: `python3 build_main_graph.py main_v2.json 3788 3789` (thêm `--dev-tools` như Pre-A1) |
| `a1/learn_chunk_create.json`, `a1/learn_sentence_create.json`, `a1/main_v2.json`, `a1/robot_lesson_create.json` | Payload A1 đã gửi lên dev |
| `a2/build_learn_a2.py` | Dựng payload 2 bot learn A2 từ agent 2584 và workflow lesson 764: `python3 build_learn_a2.py source .` |
| `a2/build_main_graph.py` | Dựng graph agent A2: `python3 build_main_graph.py main_v2.json 3791 3792` |
| `a2/learn_chunk_create.json`, `a2/learn_sentence_create.json`, `a2/main_v2.json`, `a2/robot_lesson_create.json` | Payload A2 đã gửi lên dev |
| `a2/source/`, `a2/pushed/` | Dump bài gốc A2 (agent 2584, activity 764, robot lesson 2977, 869) và bản fetch lại sau khi ghi |
| `b1/build_learn_b1.py` | Dựng payload 2 bot learn B1 từ agent 2452 và 2400: `python3 build_learn_b1.py source .` |
| `b1/build_main_graph.py` | Dựng graph agent B1: `python3 build_main_graph.py main_v2.json 3794 3795` |
| `b1/learn_chunk_create.json`, `b1/learn_sentence_create.json`, `b1/main_v2.json`, `b1/robot_lesson_create.json` | Payload B1 đã gửi lên dev |
| `b1/source/`, `b1/pushed/` | Dump bài gốc B1 (agent 2452, 2400; robot lesson 2582, 2562) và bản fetch lại sau khi ghi |
| `a1/source/`, `a1/pushed/` | Dump bài gốc A1 (activity 950, agent 2897, robot lesson 1209, 3162) và bản fetch lại sau khi ghi |

## Sửa bài

Sửa script dựng, chạy lại, rồi `fetch_bot.py <id>` bản trên host, thay phần sửa vào `result` và `push_bot.py update <id> <file>` (skill `bot-config`). Robot lesson 4006 vẫn trỏ tới agent 3787 (4007 trỏ tới 3790, 4008 trỏ tới 3793, 4009 trỏ tới 3796) nên không phải tạo lesson mới; chỉ cần giao lại xuống robot.
