from ultralytics import YOLO

# COCO pre-trained model. Class 39 = bottle.
model = YOLO("yolov8n.pt")


def detect_bottle(image_path: str) -> bool:
    results = model(image_path)
    for r in results:
        for box in r.boxes:
            if int(box.cls) == 39:
                print("Bottle detected")
                return True
    print("Bottle not detected")
    return False


if __name__ == "__main__":
    # Example: python tools/yolo_bottle_check.py assets/images/test.jpg
    import sys

    if len(sys.argv) < 2:
        print("Usage: python tools/yolo_bottle_check.py <image_path>")
        raise SystemExit(1)

    detect_bottle(sys.argv[1])
