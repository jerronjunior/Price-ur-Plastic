#!/usr/bin/env python3
"""
retrain.py
──────────
Run this script weekly/monthly to retrain your TFLite model
using data collected from real user interactions in Firebase.

Requirements:
  pip install firebase-admin tflite-model-maker Pillow numpy

Usage:
  python retrain.py --project price-ur-plastic-faab5 --min-samples 50
"""

import argparse
import os
import sys
import json
import tempfile
from datetime import datetime
from pathlib import Path

# ── Step 1: Download training data from Firebase ──────────────────────────────
def download_training_data(project_id: str, output_dir: str, min_samples: int):
    try:
        import firebase_admin
        from firebase_admin import credentials, firestore, storage
    except ImportError:
        print("ERROR: pip install firebase-admin")
        sys.exit(1)

    # Initialise Firebase (uses service account key)
    cred_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS',
                                'service-account-key.json')
    if not os.path.exists(cred_path):
        print(f"ERROR: Service account key not found at {cred_path}")
        print("Download from: Firebase Console → Project Settings → Service Accounts")
        sys.exit(1)

    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred, {
        'storageBucket': f'{project_id}.appspot.com'
    })

    db     = firestore.client()
    bucket = storage.bucket()

    # Get all training samples
    samples = db.collection('training_samples').where(
        'imageUrl', '!=', ''
    ).stream()

    counts = {}
    downloaded = 0

    for doc in samples:
        data  = doc.to_dict()
        label = data.get('label', 'unknown')
        url   = data.get('imageUrl', '')

        if not url or label in ('insertion_confirmed',):
            continue

        # Create label directory
        label_dir = Path(output_dir) / label
        label_dir.mkdir(parents=True, exist_ok=True)

        # Download image
        try:
            blob_path = url.split('/o/')[1].split('?')[0].replace('%2F', '/')
            blob = bucket.blob(blob_path)
            filename = label_dir / f"{doc.id}.jpg"
            blob.download_to_filename(str(filename))
            counts[label] = counts.get(label, 0) + 1
            downloaded += 1
            print(f"  Downloaded: {label}/{doc.id}.jpg")
        except Exception as e:
            print(f"  SKIP {doc.id}: {e}")

    print(f"\nTotal downloaded: {downloaded} images")
    for label, count in counts.items():
        print(f"  {label}: {count} samples")

    # Check minimum
    total = sum(counts.values())
    if total < min_samples:
        print(f"\nNot enough samples ({total} < {min_samples}). "
              f"Wait for more user data before retraining.")
        sys.exit(0)

    return counts


# ── Step 2: Retrain using TFLite Model Maker ──────────────────────────────────
def retrain_model(data_dir: str, output_path: str):
    try:
        from tflite_model_maker import image_classifier
        from tflite_model_maker.config import ExportFormat
    except ImportError:
        print("ERROR: pip install tflite-model-maker")
        sys.exit(1)

    print("\nLoading training data…")
    data = image_classifier.DataLoader.from_folder(data_dir)
    train_data, test_data = data.split(0.9)

    print("Training model (this takes a few minutes)…")
    model = image_classifier.create(
        train_data,
        model_spec='mobilenet_v2',
        epochs=10,
        batch_size=32,
        train_whole_model=False,  # Only retrain top layers — fast
    )

    # Evaluate
    loss, accuracy = model.evaluate(test_data)
    print(f"\nAccuracy: {accuracy * 100:.1f}%  Loss: {loss:.4f}")

    if accuracy < 0.75:
        print(f"WARNING: Accuracy below 75%. Not uploading this model.")
        print(f"Collect more training data and try again.")
        return False

    # Export TFLite
    model.export(export_dir=str(Path(output_path).parent),
                 export_format=ExportFormat.TFLITE)

    print(f"Model saved: {output_path}")
    return True


# ── Step 3: Upload new model to Firebase Storage ──────────────────────────────
def upload_model(model_path: str, version: str, project_id: str):
    import firebase_admin
    from firebase_admin import storage, remote_config

    bucket    = storage.bucket()
    blob_path = f"models/ssd_mobilenet_v{version}.tflite"
    blob      = bucket.blob(blob_path)

    print(f"\nUploading model to Firebase Storage: {blob_path}")
    blob.upload_from_filename(model_path)
    blob.make_public()
    print(f"Uploaded: {blob.public_url}")

    # Update Remote Config so apps know there's a new model
    # Apps will download it on next startup
    print(f"Updating Remote Config: tflite_model_version = {version}")
    rc = remote_config.Client()
    template = rc.get_template()
    template.parameters['tflite_model_version'] = remote_config.Parameter(
        default_value=remote_config.ParameterValue(value=version)
    )
    rc.validate_template(template)
    rc.publish_template(template)
    print(f"Remote Config updated. Apps will download model v{version} on next launch.")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description='Retrain RecycleScan TFLite model')
    parser.add_argument('--project',     default='price-ur-plastic-faab5')
    parser.add_argument('--min-samples', type=int, default=50,
                        help='Minimum training samples required')
    args = parser.parse_args()

    version    = datetime.now().strftime('%Y%m%d')
    output_dir = tempfile.mkdtemp(prefix='recycleScan_training_')
    model_path = os.path.join(output_dir, 'model.tflite')

    print(f"RecycleScan Model Retraining")
    print(f"Version: {version}")
    print(f"Project: {args.project}")
    print(f"Working dir: {output_dir}")
    print("─" * 50)

    print("\n[1/3] Downloading training data from Firebase…")
    counts = download_training_data(args.project, output_dir, args.min_samples)

    print("\n[2/3] Retraining model…")
    success = retrain_model(output_dir, model_path)

    if success:
        print("\n[3/3] Uploading new model…")
        upload_model(model_path, version, args.project)
        print(f"\n✅ Done! Model v{version} is live.")
        print("Users will get the update on next app launch.")
    else:
        print("\n⚠️  Retraining skipped — accuracy too low.")


if __name__ == '__main__':
    main()
