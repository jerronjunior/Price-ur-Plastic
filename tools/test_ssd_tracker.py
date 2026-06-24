import cv2
import numpy as np
import tensorflow as tf
from pathlib import Path
from enum import Enum

class DepositState(Enum):
    idle = 1
    detected = 2
    approaching = 3
    entering = 4
    deposited = 5

class BottleDepositTracker:
    def __init__(self, slot_region):
        self.state = DepositState.idle
        self.slot_left = slot_region[0]
        self.slot_top = slot_region[1]
        self.slot_width = slot_region[2]
        self.slot_height = slot_region[3]
        self.last_bottle_center_y = 0.0
        self.missing_frames = 0
        self.count = 0

    def is_intersecting(self, rect):
        bx1, by1, bx2, by2 = rect
        sx1 = self.slot_left
        sy1 = self.slot_top
        sx2 = self.slot_left + self.slot_width
        sy2 = self.slot_top + self.slot_height
        
        return not (bx2 < sx1 or bx1 > sx2 or by2 < sy1 or by1 > sy2)

    def process_detections(self, detections, frame_idx):
        best_bottle = detections[0] if len(detections) > 0 else None

        if self.state == DepositState.idle:
            if best_bottle is not None:
                self.state = DepositState.detected
                self.last_bottle_center_y = (best_bottle[1] + best_bottle[3]) / 2
                self.missing_frames = 0
                print(f"[Frame {frame_idx}] STAGE 1: Bottle detected (conf: {best_bottle[4]:.2f})")
                
        elif self.state == DepositState.detected:
            if best_bottle is not None:
                center_y = (best_bottle[1] + best_bottle[3]) / 2
                if center_y > self.last_bottle_center_y + 0.02:
                    self.state = DepositState.approaching
                    print(f"[Frame {frame_idx}] STAGE 2: Bottle approaching bin")
                self.last_bottle_center_y = center_y
                self.missing_frames = 0
            else:
                self.missing_frames += 1
                if self.missing_frames > 5:
                    self.state = DepositState.idle
                    
        elif self.state == DepositState.approaching:
            if best_bottle is not None:
                center_y = (best_bottle[1] + best_bottle[3]) / 2
                self.last_bottle_center_y = center_y
                self.missing_frames = 0
                if self.is_intersecting(best_bottle):
                    self.state = DepositState.entering
                    print(f"[Frame {frame_idx}] STAGE 3: Bottle entering bin")
            else:
                self.missing_frames += 1
                if self.missing_frames > 10:
                    self.state = DepositState.idle
                    
        elif self.state == DepositState.entering:
            if best_bottle is not None:
                center_y = (best_bottle[1] + best_bottle[3]) / 2
                self.last_bottle_center_y = center_y
                self.missing_frames = 0
            else:
                self.missing_frames += 1
                if self.missing_frames > 3:
                    self.state = DepositState.deposited
                    print(f"[Frame {frame_idx}] STAGE 4: Bottle deposited successfully")
                    self.count += 1
                    print(f"[Frame {frame_idx}] STAGE 5: Counter updated (Total: {self.count})")
                    self.state = DepositState.idle
                    
        elif self.state == DepositState.deposited:
            self.state = DepositState.idle

def main():
    print("Loading SSD MobileNet TFLite model...")
    interpreter = tf.lite.Interpreter(model_path="assets/models/ssd_mobilenet.tflite")
    interpreter.allocate_tensors()
    
    input_details = interpreter.get_input_details()[0]
    
    video_path = "E:/BottleDepositAI/videos/VID-20260607-WA0016.mp4"
    cap = cv2.VideoCapture(video_path)
    
    if not cap.isOpened():
        print(f"Error opening video {video_path}")
        return
        
    tracker = BottleDepositTracker(slot_region=[0.30, 0.18, 0.40, 0.34])
    frame_idx = 0
    
    print(f"Testing detection logic on {video_path}...")
    
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
            
        frame_idx += 1
        if frame_idx % 2 != 0:
            continue  # simulate frame skipping as in dart app

        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        resized_frame = cv2.resize(rgb_frame, (300, 300))
        input_data = np.expand_dims(resized_frame, axis=0)
        
        interpreter.set_tensor(input_details['index'], input_data)
        interpreter.invoke()
        
        boxes = interpreter.get_tensor(interpreter.get_output_details()[0]['index'])[0]
        classes = interpreter.get_tensor(interpreter.get_output_details()[1]['index'])[0]
        scores = interpreter.get_tensor(interpreter.get_output_details()[2]['index'])[0]
        
        detections = []
        for i in range(len(scores)):
            if scores[i] > 0.5:
                # y1, x1, y2, x2
                y1, x1, y2, x2 = boxes[i]
                # convert to x1, y1, x2, y2, score
                detections.append((x1, y1, x2, y2, scores[i]))
                
        detections.sort(key=lambda x: x[4], reverse=True)
        tracker.process_detections(detections, frame_idx)

    print(f"Finished processing. Total bottles counted: {tracker.count}")

if __name__ == '__main__':
    main()
