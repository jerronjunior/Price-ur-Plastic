# Admin Dashboard Documentation

## Overview

The admin dashboard provides administrators with the ability to:
- Add and manage recycling bin QR codes
- Configure reward settings and tier requirements
- View system statistics (total users, bins, bottles recycled)

## Features Implemented

### 1. Admin Role System
- Added `isAdmin` field to `UserModel`
- Admin users have access to the admin dashboard
- Admin button appears in Profile screen only for admin users

### 2. Admin Dashboard (`/admin`)
Displays:
- Total Users count
- Total Bins count  
- Total Bottles Recycled count
- Quick access buttons to Manage Bins and Manage Rewards

### 3. Manage Bins (`/admin/bins`)
Allows admins to:
- View all existing bins with their QR codes and locations
- Add new bins with custom Bin ID (QR code value) and location name
- Edit bin location names
- Delete bins
- Real-time updates via Firestore stream

### 4. Manage Rewards (`/admin/rewards`)
Configure all reward system settings:
- **Points Per Bottle**: How many points users earn per recycled bottle
- **Max Bottles Per Day**: Daily recycling limit per user
- **Cooldown Seconds**: Time between allowed scans
- **Bronze Tier Points**: Points needed to reach Bronze tier
- **Silver Tier Points**: Points needed to reach Silver tier
- **Gold Tier Points**: Points needed to reach Gold tier

All changes are saved to Firestore in real-time.

## Setting Up Admin Users

### Method 1: Firebase Console (Recommended)
1. Open Firebase Console
2. Go to Firestore Database
3. Navigate to the `users` collection
4. Find the user document you want to make admin
5. Add a field: `isAdmin` (type: boolean) = `true`
6. Save the document

### Method 2: Firestore Rules (for initial setup)
You can create a Cloud Function or manually set the first admin:

```javascript
// Example Cloud Function to set admin
exports.setAdmin = functions.https.onCall(async (data, context) => {
  const userId = data.userId;
  await admin.firestore().collection('users').doc(userId).update({
    isAdmin: true
  });
  return { success: true };
});
```

### Method 3: During Registration (Temporary)
For testing purposes, you can temporarily modify the registration flow:
1. Open `lib/providers/auth_provider.dart`
2. In the `register` method, after creating the user, set `isAdmin: true`
3. **Important**: Remove this after creating your admin account

## Firestore Collections Structure

### `bins` Collection
```
bins/
  {binId}/
    locationName: string
```

### `reward_config` Collection
```
reward_config/
  default/
    pointsPerBottle: number (default: 1)
    bronzePoints: number (default: 50)
    silverPoints: number (default: 200)
    goldPoints: number (default: 500)
    maxBottlesPerDay: number (default: 25)
    cooldownSeconds: number (default: 20)
    updatedAt: timestamp
```

### `users` Collection (with admin field)
```
users/
  {userId}/
    name: string
    email: string
    mobile: string
    totalPoints: number
    totalBottles: number
    isAdmin: boolean
    profileImageUrl: string (optional)
```

## Testing the Admin Dashboard

1. **Create an Admin User**:
   - Register a new user through the app
   - Use Firebase Console to set `isAdmin: true` on that user
   - Log out and log back in

2. **Access Admin Dashboard**:
   - Log in with the admin account
   - Go to Profile screen
   - Look for the green "Admin Dashboard" button
   - Tap to access admin features

3. **Test Bin Management**:
   - Tap "Manage Bins"
   - Add a test bin (e.g., Bin ID: "TEST001", Location: "Test Location")
   - Try scanning this QR code in the app
   - Edit the location name
   - Delete the test bin

4. **Test Reward Configuration**:
   - Tap "Manage Rewards"
   - Try changing the points per bottle
   - Save changes
   - Test recycling a bottle to verify new points are awarded
   - Reset to defaults if needed

## Security Recommendations

### Firestore Security Rules
Update your `firestore.rules` to protect admin operations:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Helper function to check admin status
    function isAdmin() {
      return request.auth != null && 
             get(/databases/$(database)/documents/users/$(request.auth.uid)).data.isAdmin == true;
    }
    
    // Bins collection - read by all, write by admin only
    match /bins/{binId} {
      allow read: if request.auth != null;
      allow write: if isAdmin();
    }
    
    // Reward config - read by all, write by admin only
    match /reward_config/{configId} {
      allow read: if request.auth != null;
      allow write: if isAdmin();
    }
    
    // Users collection
    match /users/{userId} {
      allow read: if request.auth != null && request.auth.uid == userId;
      allow update: if request.auth != null && request.auth.uid == userId;
      // Prevent users from changing their own admin status
      allow update: if request.auth != null && 
                       request.auth.uid == userId && 
                       !request.resource.data.diff(resource.data).affectedKeys().hasAny(['isAdmin']);
    }
  }
}
```

## Navigation Flow

```
Profile Screen (for admin users)
  └─> Admin Dashboard (/admin)
       ├─> Manage Bins (/admin/bins)
       │    ├─> Add Bin Dialog
       │    ├─> Edit Bin Dialog
       │    └─> Delete Bin Confirmation
       └─> Manage Rewards (/admin/rewards)
            ├─> Edit all reward settings
            └─> Save/Reset
```

## Future Enhancements

Potential admin features to add:
- User management (view all users, ban/unban, manual point adjustment)
- Analytics dashboard (recycling trends, popular locations)
- Notification management (send announcements)
- Report generation (CSV export of data)
- Bulk bin import (CSV upload)
- Activity logs (audit trail of admin actions)

## Troubleshooting

**Issue**: Admin button doesn't appear
- **Solution**: Verify `isAdmin: true` is set in Firestore for the user
- Log out and log back in after setting admin status

**Issue**: "Permission denied" when adding bins
- **Solution**: Update Firestore security rules to allow admin writes

**Issue**: Reward changes not taking effect
- **Solution**: Ensure the app is reading from `reward_config/default` document
- Check that the reward config service methods are being called in scan flows

**Issue**: Stats showing 0 counts
- **Solution**: Verify Firestore indexes are created for the queries
- Check Firebase Console for missing index warnings
