# Supabase Setup

This project was migrated from Firebase to Supabase.

## 1) Create Supabase project
- Create a new project in Supabase.
- In Authentication -> Providers, enable Email.

## 2) Create database schema
- Open SQL Editor in Supabase.
- Run the SQL from supabase/schema.sql.

## 3) Create storage bucket
- Go to Storage -> Buckets.
- Create bucket: profile-images.
- Set it as Public (the app uses public URLs for profile images).

## 4) Configure Flutter runtime variables
Use dart-define values when running the app:

flutter run --dart-define=SUPABASE_URL=YOUR_SUPABASE_URL --dart-define=SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY

For release builds, pass the same defines to build commands.

## 5) Optional data migration from Firebase
This code migration does not copy your old Firebase data automatically.
If you need data copied from Firebase to Supabase, export from Firebase and import into these tables:
- users
- bins
- recycled_bottles
- reward_config
- notifications
- admin_notifications
- bin_scans

## Notes
- Firebase packages and app initialization were removed from Dart code.
- The service class name FirestoreService was kept to avoid UI refactors; it now talks to Supabase.
