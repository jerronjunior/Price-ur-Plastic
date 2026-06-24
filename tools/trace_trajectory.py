from ultralytics import YOLO
import sys

def main():
    print("Loading YOLO11n...")
    model = YOLO('yolo11n.pt')
    video_path = 'E:/BottleDepositAI/videos/VID-20260607-WA0016.mp4'
    print(f"Running inference on {video_path}...")
    
    results = model(video_path, stream=True)
    for i, r in enumerate(results):
        if i % 15 == 0:
            print(f"--- Frame {i} ---")
            for box in r.boxes:
                cls_id = int(box.cls[0])
                conf = float(box.conf[0])
                cls_name = model.names[cls_id]
                xyxy = box.xyxy[0].tolist()
                print(f"  {cls_name} (conf: {conf:.2f}) at {xyxy}")
        if i > 150:  # process only first 150 frames to be quick
            break
    print("Done!")

if __name__ == "__main__":
    main()
