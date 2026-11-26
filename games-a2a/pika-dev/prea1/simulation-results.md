# Kết quả giả lập Pre-A1 (agent 3787)

Chưa có lần chạy nào thành công: dịch vụ giả lập trên host dev trả 504 ngay khi gọi, nên chưa có transcript để chấm.

## Các lần chạy

| Lần | Ngày | Persona × lượt | Kết quả | Ghi chú |
|---|---|---|---|---|
| 1 | 25/11/2026 | 4 × 70 | Chưa chạy | Backend từ chối trước khi chạy: `maxTurns must be <= 50` (log `sim/run_422_maxturns.log`) |
| 2 | 25/11/2026 | 4 × 50 | Chưa đạt | Cả 4 persona HTTP 504 từ Cloudflare (log `sim/run_504_50turns.log`) |
| 3 | 25/11/2026 | 1 × 12 (dò) | Chưa đạt | HTTP 504 sau 1 giây, trong khi `GET /simulate/profiles` vẫn trả trong 1 giây: lỗi ở dịch vụ giả lập phía sau, không phải ở bài (log `sim/run_probe.log`) |

## Việc còn lại

| Việc | Trạng thái |
|---|---|
| Báo admin dịch vụ `/simulate/run` trên dev trả 504, hoặc chạy qua server local (`PIKA_ENV=local`) | Chờ |
| Chạy lại 4 persona (`personas.json`, tối đa 50 lượt mỗi persona) và đếm số lượt thực tế của từng phần | Chờ |
| Chỉnh `max_turns` cho tổng buổi sát 28–30 phút, sau đó đo trên robot thật | Chờ |
