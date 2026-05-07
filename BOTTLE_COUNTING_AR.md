# Bottle Counter with Computer Vision & AR

## Overview

A real-time **bottle counting system** with **computer vision** and **3D particle visualization** for your admin panel. Uses ML model (SSD MobileNet) to detect bottles in camera frames in real-time.

## Features

✅ **Real-time Detection** - Continuously detects bottles in live camera feed  
✅ **Confidence Scoring** - Shows detection confidence for each bottle  
✅ **Bounding Boxes** - Visual detection boxes with corner brackets  
✅ **Particle Effects** - 3D confetti-like animations when new bottles detected  
✅ **Peak Counter** - Tracks maximum bottles detected in session  
✅ **Toggle Controls** - Start/pause detection, show/hide boxes, reset counter  

## Architecture

### Components

**1. BottleCountingService** (`lib/services/bottle_counting_service.dart`)
- Uses `tflite_flutter` to run inference on camera frames
- Detects bottles using SSD MobileNet model (already in assets)
- Returns list of detected bottles with confidence scores & bounding boxes
- Handles YUV420 to RGB conversion & image preprocessing

**2. BottleCounterScreen** (`lib/screens/admin/bottle_counter_screen.dart`)
- Main UI with real-time camera stream
- Displays live counter badge with animations
- Shows detection bounding boxes overlay
- Particle effect system with confetti-like visualization
- Start/Pause/Reset controls with stats panel

**3. App Router** (`lib/app/app_router.dart`)
- Route: `/bottle-counter` (admin-only)
- Accessible from Admin Dashboard

### Model

Your existing **SSD MobileNet** model is used:
- Path: `assets/models/ssd_mobilenet.tflite`
- Input: 300×300 RGB images
- Output: Bounding boxes + confidence scores
- Detects multiple object classes (bottles are one of them)

## How to Use

### 1. From Admin Dashboard

Click **"Bottle Counter AR"** button on the admin dashboard.

### 2. Controls

| Control | Action |
|---------|--------|
| **START** | Begin real-time detection |
| **PAUSE** | Pause detection (camera still visible) |
| **RESET** | Clear counters and detections |
| **Eye Icon** | Toggle bounding box display |

### 3. Reading the UI

- **Large Number (top-right)**: Current bottles detected in frame
- **"Peak: X"**: Maximum bottles detected in this session
- **Status Bar**: Shows "Active" or "Paused" status
- **Green Boxes**: Detection boxes with confidence % labels
- **Confetti**: Animated particles when a new bottle is detected

## Dependencies Added

No new AR package is required for the current implementation. The screen uses the existing camera stack plus custom Flutter overlays for the AR-style effect.

## Implementation Details

### Real-Time Detection Loop

```
Camera Frame → Preprocess (YUV420→RGB, resize 300×300)
    ↓
    TFLite Inference
    ↓
    Parse Output (boxes + scores)
    ↓
    Filter by confidence threshold (0.5)
    ↓
    Sort by confidence descending
    ↓
    Update UI (every 2nd frame for performance)
```

### Bounding Box Rendering

- Normalized coordinates (0-1) converted to screen coordinates
- Color-coded by confidence: Green (>80%), Yellow (60-80%), Orange (<60%)
- Corner brackets + detection labels with confidence percentage
- Real-time update with custom paint

### Particle System

- Triggered when `bottleCount` increases
- 20-100 particles radiating outward from center
- Progressive opacity fade
- Consistent seeded randomness for smooth animations

## Configuration

### Confidence Threshold

To adjust detection sensitivity (currently 0.5):

**File:** `lib/services/bottle_counting_service.dart`
```dart
static const double _confidenceThreshold = 0.5;  // Change this (0.0-1.0)
```

Lower = more detections (higher false positives)  
Higher = fewer detections (higher precision)

### Performance Tuning

**Frame Skip Rate** (currently every 2nd frame):
```dart
if (_frameCount % 2 != 0 || _processingFrame) return;
```

Increase `% 2` to `% 3` or `% 4` for better performance on slower devices.

## Advanced: Custom Model Training

To improve bottle detection accuracy, you can train your own model:

1. **Collect Data**: Gather bottle images from your use case
2. **Annotate**: Label bottles in images using tools like LabelImg
3. **Train**: Use TensorFlow to train SSD MobileNet
4. **Convert**: Export as .tflite format
5. **Replace**: Swap `assets/models/ssd_mobilenet.tflite`

Recommended framework: [TensorFlow Object Detection API](https://github.com/tensorflow/models/tree/master/research/object_detection)

## Troubleshooting

### Model Not Loading
```
❌ Error initializing BottleCounterService
```
**Solution**: Ensure `assets/models/ssd_mobilenet.tflite` exists

### Camera Permission Denied
**Solution**: Check `AndroidManifest.xml` has camera permissions and app has runtime permissions

### Detections Not Updating
**Solution**: Confirm `_isDetecting` is true (tap START button)

### High Latency / Dropped Frames
**Solution**: 
- Increase frame skip: `% 3` instead of `% 2`
- Reduce detection frequency on slower devices
- Optimize model further with quantization

## Future Enhancements

Potential additions:
- ✨ AR overlay with 3D bottle models
- 📊 Detection statistics & graphs
- 🎯 Bounding box filtering by size/confidence
- 📹 Video recording with annotations
- 🔄 Multi-frame smoothing for stable count
- 🤖 Custom ML model training pipeline
- 📤 Export count data to Firebase/CSV

## API Reference

### BottleCountingService

```dart
// Initialize service
final service = BottleCountingService();
await service.initialize();

// Detect in frame
final detections = await service.detectBottlesInFrame(cameraImage);

// Access results
for (final bottle in detections) {
  print('Bottle: ${bottle.confidence} at ${bottle.rect}');
  print('Center: (${bottle.centerX}, ${bottle.centerY})');
  print('Size: ${bottle.width} x ${bottle.height}');
}

// Get smooth count
final count = service.getSmoothBottleCount();

// Cleanup
service.dispose();
```

### DetectedBottle

```dart
class DetectedBottle {
  final double confidence;        // 0.0-1.0
  final List<double> rect;        // [x1, y1, x2, y2] normalized
  final String label;             // "Bottle"
  
  double get centerX;
  double get centerY;
  double get width;
  double get height;
}
```

## File Structure

```
lib/
├── services/
│   └── bottle_counting_service.dart      ← ML inference logic
├── screens/
│   └── admin/
│       └── bottle_counter_screen.dart    ← Main UI + AR
└── app/
    └── app_router.dart                   ← Routes (/bottle-counter)

assets/
└── models/
    └── ssd_mobilenet.tflite              ← ML model (existing)
```

## Testing

### Manual Testing Checklist

- [ ] Can access "Bottle Counter AR" from Admin Dashboard
- [ ] Camera initializes and shows preview
- [ ] START button enables detection
- [ ] Green boxes appear when bottles detected
- [ ] Count increases/decreases correctly
- [ ] Confetti animates on new detections
- [ ] PAUSE stops detection
- [ ] RESET clears all values
- [ ] Eye icon toggles bounding boxes
- [ ] Confidence % displays correctly

## License & Credits

- **ML Model**: Google SSD MobileNet (pre-trained)
- **Framework**: Flutter + TFLite
- **AR Plugin**: ar_flutter_plugin (optional enhancement)

---

**Questions?** Check ADMIN_DOCUMENTATION.md for general admin features.
