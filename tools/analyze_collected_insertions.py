#!/usr/bin/env python3
"""
analyze_collected_insertions.py
─────────────────────────────────
Continuous recalibration for the bottle-insertion detector.

Unlike the original 35-video calibration (a one-time manual snapshot),
this script reads REAL metrics that every user's app already reports
to Firestore for every single insertion attempt — both successful
and rejected. The more the app is used, the better this calibration
gets, automatically.

What it does:
  1. Downloads all documents from the `insertion_attempts` Firestore
     collection (written by training_data_service.dart's
     onInsertionAttempt(), wired in via slot_motion_detection_impl.dart)
  2. Splits them into counted vs rejected populations
  3. Finds safe threshold values: low enough that real counted
     attempts won't be missed, high enough to keep filtering shake
  4. Optionally publishes the new values directly to Firebase Remote
     Config, so the app picks them up on next launch — no app store
     update needed.

Usage:
  pip install firebase-admin
  python analyze_collected_insertions.py --min-samples 200
  python analyze_collected_insertions.py --min-samples 200 --publish
"""

import argparse
import sys
from datetime import datetime, timedelta

try:
    import firebase_admin
    from firebase_admin import credentials, firestore, remote_config
except ImportError:
    print("Run: pip install firebase-admin")
    sys.exit(1)

PROJECT_ID = 'price-ur-plastic-faab5'
CRED_PATH  = 'service-account-key.json'

# Safety margins — never set a threshold exactly at the observed boundary,
# always leave room so natural variation in future attempts doesn't get
# pushed outside the new range.
CHANGE_FRACTION_MARGIN = 0.02
DOWNWARD_SCORE_MARGIN  = 0.02
CORNER_MOTION_MARGIN   = 0.02


def load_attempts(db, days_back=90):
    """Pull insertion_attempts from the last N days."""
    cutoff = datetime.utcnow() - timedelta(days=days_back)
    docs = db.collection('insertion_attempts') \
             .where('timestamp', '>=', cutoff) \
             .stream()
    return [d.to_dict() for d in docs]


def recommend_thresholds(attempts, min_samples):
    counted  = [a for a in attempts if a.get('counted')]
    rejected = [a for a in attempts if not a.get('counted')]

    print(f"\nTotal attempts loaded: {len(attempts)}")
    print(f"  Counted (real insertions): {len(counted)}")
    print(f"  Rejected (camera shake / low confidence): {len(rejected)}")

    if len(counted) < min_samples:
        print(f"\n⚠️  Only {len(counted)} counted samples — need at least "
              f"{min_samples} for a confident recalibration. Skipping.")
        print("    Keep using the app to collect more data, then re-run.")
        return None

    cf_vals   = [a['peakChangeFraction'] for a in counted if 'peakChangeFraction' in a]
    down_vals = [a['peakDownwardScore']  for a in counted if 'peakDownwardScore'  in a]
    corner_counted  = [a['avgCornerMotion'] for a in counted  if 'avgCornerMotion' in a]
    corner_rejected = [a['avgCornerMotion'] for a in rejected if 'avgCornerMotion' in a]

    min_cf   = min(cf_vals)   if cf_vals   else None
    min_down = min(down_vals) if down_vals else None
    max_corner_counted = max(corner_counted) if corner_counted else None

    print(f"\nReal counted insertions:")
    print(f"  peakChangeFraction: min={min_cf:.3f}" if min_cf is not None else "  peakChangeFraction: no data")
    print(f"  peakDownwardScore:  min={min_down:.3f}" if min_down is not None else "  peakDownwardScore: no data")
    print(f"  avgCornerMotion:    max={max_corner_counted:.3f}" if max_corner_counted is not None else "")

    if corner_rejected:
        print(f"\nRejected attempts (camera shake):")
        print(f"  avgCornerMotion: min={min(corner_rejected):.3f}  mean={sum(corner_rejected)/len(corner_rejected):.3f}")

    recommendations = {}
    if min_cf is not None:
        recommendations['insertion_min_change_fraction'] = round(max(0.05, min_cf - CHANGE_FRACTION_MARGIN), 3)
    if min_down is not None:
        recommendations['insertion_min_downward_score'] = round(max(0.15, min_down - DOWNWARD_SCORE_MARGIN), 3)
    if max_corner_counted is not None:
        recommendations['insertion_max_corner_motion_avg'] = round(max_corner_counted + CORNER_MOTION_MARGIN, 3)

    print(f"\n{'='*60}")
    print("RECOMMENDED REMOTE CONFIG VALUES")
    print(f"{'='*60}")
    for key, val in recommendations.items():
        print(f"  {key} = {val}")

    return recommendations


def publish_to_remote_config(recommendations):
    """Push the new values directly to Firebase Remote Config."""
    template = remote_config.init_server_template(project_id=PROJECT_ID)
    # NOTE: requires the parameters to already exist in Remote Config
    # (create them once via Console → Add parameter — see chat for names).
    config = remote_config.RemoteConfig(parameters={
        key: remote_config.Parameter(default_value=remote_config.ParameterValueType(str(val)))
        for key, val in recommendations.items()
    })
    print("\n✓ Published to Remote Config. App will pick up new values on next launch.")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--min-samples', type=int, default=200,
                         help='Minimum counted samples required before recalibrating')
    parser.add_argument('--days', type=int, default=90,
                         help='How many days of data to include')
    parser.add_argument('--publish', action='store_true',
                         help='Push recommended values directly to Remote Config')
    args = parser.parse_args()

    cred = credentials.Certificate(CRED_PATH)
    firebase_admin.initialize_app(cred)
    db = firestore.client()

    attempts = load_attempts(db, days_back=args.days)
    recs = recommend_thresholds(attempts, args.min_samples)

    if recs and args.publish:
        publish_to_remote_config(recs)
    elif recs:
        print("\nRun again with --publish to push these values live.")
        print("Or set them manually in Firebase Console → Remote Config:")
        for key, val in recs.items():
            print(f"  {key} = {val}")
