import cv2
import torch
import numpy as np
import time
from ultralytics import YOLO
from transformers import pipeline
from PIL import Image

# ── Models ────────────────────────────────────────────────────────────────────
yolo = YOLO("yolo11s.pt")

depth_pipe = pipeline(
    task="depth-estimation",
    model="depth-anything/Depth-Anything-V2-Metric-Indoor-small-hf",
    device=0 if torch.cuda.is_available() else -1,
)

# ── Config ────────────────────────────────────────────────────────────────────
TEST_DURATION_SECONDS = 20
DEPTH_EVERY_N_FRAMES = 1   # Use 1 for fair benchmarking

DEPTH_INPUT_SIZE = 518     # Compatible size for Depth Anything V2

DANGER_M  = 1.0
CAUTION_M = 2.5

cap = cv2.VideoCapture(0)

frame_idx = 0
depth = None

total_frame_time = 0.0
total_depth_time = 0.0
processed_frames = 0
depth_frames = 0

start_test_time = time.perf_counter()

while True:
    frame_start_time = time.perf_counter()

    elapsed = time.perf_counter() - start_test_time
    if elapsed >= TEST_DURATION_SECONDS:
        break

    ret, frame = cap.read()
    if not ret:
        break

    h, w = frame.shape[:2]
    frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

    # ── YOLO ──────────────────────────────────────────────────────────────────
    results = yolo.predict(frame, imgsz=640, verbose=False)
    boxes = results[0].boxes
    names = yolo.names

    # ── Depth: RESIZED INPUT SIZE ─────────────────────────────────────────────
    if frame_idx % DEPTH_EVERY_N_FRAMES == 0:
        depth_start_time = time.perf_counter()

        # print("Depth input frame shape:", frame_rgb.shape)
        pil_img = Image.fromarray(frame_rgb).resize(
            (DEPTH_INPUT_SIZE, DEPTH_INPUT_SIZE),
            Image.Resampling.BICUBIC
        )

        output = depth_pipe(pil_img)

        depth_end_time = time.perf_counter()
        total_depth_time += depth_end_time - depth_start_time
        depth_frames += 1

        raw = output["predicted_depth"]
        if isinstance(raw, torch.Tensor):
            raw = raw.squeeze().cpu().numpy()

        depth = raw.astype(np.float32)

        # Resize depth OUTPUT back to camera frame size
        if depth.shape[:2] != (h, w):
            depth = cv2.resize(depth, (w, h), interpolation=cv2.INTER_LINEAR)

    # ── Per-object depth ──────────────────────────────────────────────────────
    if depth is not None:
        for box in boxes:
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            cls_id = int(box.cls[0])
            label = names[cls_id]
            conf = float(box.conf[0])

            pad_x = max(1, int((x2 - x1) * 0.10))
            pad_y = max(1, int((y2 - y1) * 0.10))

            region = depth[y1 + pad_y:y2 - pad_y, x1 + pad_x:x2 - pad_x]
            valid = region[region > 0.1] if region.size > 0 else np.array([])

            obj_depth = float(np.median(valid)) if valid.size > 0 else 0.0

            if obj_depth < DANGER_M:
                color = (0, 0, 255)
            elif obj_depth < CAUTION_M:
                color = (0, 165, 255)
            else:
                color = (0, 255, 0)

            tag = f"{label} {obj_depth:.2f}m"

            cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            cv2.putText(
                frame,
                tag,
                (x1, max(y1 - 8, 12)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.6,
                color,
                2,
                cv2.LINE_AA,
            )

    cv2.imshow("Version 2 - Resized 518x518 Input", frame)

    frame_idx += 1
    processed_frames += 1

    frame_end_time = time.perf_counter()
    total_frame_time += frame_end_time - frame_start_time

    if cv2.waitKey(1) == 27:
        break

cap.release()
cv2.destroyAllWindows()

# ── Results ───────────────────────────────────────────────────────────────────
avg_frame_time = total_frame_time / processed_frames if processed_frames > 0 else 0
avg_depth_time = total_depth_time / depth_frames if depth_frames > 0 else 0
fps = processed_frames / total_frame_time if total_frame_time > 0 else 0

print("\n========== VERSION 2 RESULTS ==========")
print("Input size to depth model: 518x518")
print(f"Processed frames: {processed_frames}")
print(f"Depth frames: {depth_frames}")
print(f"Average total response time per frame: {avg_frame_time:.4f} seconds")
print(f"Average total response time per frame: {avg_frame_time * 1000:.2f} ms")
print(f"Average depth model time per depth frame: {avg_depth_time:.4f} seconds")
print(f"Average depth model time per depth frame: {avg_depth_time * 1000:.2f} ms")
print(f"Approx FPS: {fps:.2f}")