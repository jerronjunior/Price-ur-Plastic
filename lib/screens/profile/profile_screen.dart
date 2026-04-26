import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/theme.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/notification_provider.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';
import '../../services/storage_service.dart';

/// Profile screen: user info, edit profile, logout.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _emailController;
  late TextEditingController _mobileController;
  bool _isEditing = false;
  bool _showNotificationPanel = false;
  bool _uploadingImage = false;
  final ImagePicker _imagePicker = ImagePicker();
  final StorageService _storageService = StorageService();

  void _syncControllersFromUser([UserModel? user]) {
    final userData = user ?? context.read<AuthProvider>().user;
    final nameParts = userData?.name.split(' ') ?? ['', ''];
    _firstNameController.text = nameParts.isNotEmpty ? nameParts[0] : '';
    _lastNameController.text =
        nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
    _emailController.text = userData?.email ?? '';
    _mobileController.text = userData?.mobile ?? '';
  }

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController();
    _lastNameController = TextEditingController();
    _emailController = TextEditingController();
    _mobileController = TextEditingController();
    _syncControllersFromUser();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadImage() async {
    try {
      // Show options: Camera or Gallery
      final source = await showDialog<ImageSource>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose Image Source'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Camera'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Gallery'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );

      if (source == null) return;

      // Pick image
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      setState(() => _uploadingImage = true);

      // Upload to Supabase Storage
      final userId = context.read<AuthProvider>().userId;
      if (userId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please log in again and try.')),
          );
        }
        return;
      }

      final imageUrl = await _storageService.uploadProfileImage(
        userId,
        File(pickedFile.path),
      );

      // Save image URL in Firestore user document.
      await context.read<AuthProvider>().updateProfileImage(imageUrl);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated!')),
        );
      }
    } on StorageServiceException catch (e) {
      if (mounted) {
        final errorText = e.message ?? 'Failed to upload profile picture.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorText)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload profile picture: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingImage = false);
      }
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;
    bool submitting = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final currentPassword = currentController.text;
              final newPassword = newController.text;
              final confirmPassword = confirmController.text;

              if (currentPassword.isEmpty ||
                  newPassword.isEmpty ||
                  confirmPassword.isEmpty) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(
                      content: Text('Please fill all password fields.')),
                );
                return;
              }
              if (newPassword.length < 6) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(
                    content:
                        Text('New password must be at least 6 characters.'),
                  ),
                );
                return;
              }
              if (newPassword != confirmPassword) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(content: Text('New passwords do not match.')),
                );
                return;
              }

              setDialogState(() => submitting = true);
              final msg =
                  await this.context.read<AuthProvider>().changePassword(
                        currentPassword: currentPassword,
                        newPassword: newPassword,
                      );
              if (!mounted) return;
              setDialogState(() => submitting = false);

              if (msg != null) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(content: Text(msg), backgroundColor: Colors.red),
                );
                return;
              }

              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(
                  content: Text('Password changed successfully.'),
                  backgroundColor: Colors.green,
                ),
              );
            }

            return AlertDialog(
              title: const Text('Change Password'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: currentController,
                      obscureText: obscureCurrent,
                      decoration: InputDecoration(
                        labelText: 'Current Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureCurrent
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () => setDialogState(
                              () => obscureCurrent = !obscureCurrent),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: newController,
                      obscureText: obscureNew,
                      decoration: InputDecoration(
                        labelText: 'New Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureNew
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () =>
                              setDialogState(() => obscureNew = !obscureNew),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirmController,
                      obscureText: obscureConfirm,
                      decoration: InputDecoration(
                        labelText: 'Confirm New Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () => setDialogState(
                            () => obscureConfirm = !obscureConfirm,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      submitting ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: submitting ? null : submit,
                  child: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Update'),
                ),
              ],
            );
          },
        );
      },
    );

    currentController.dispose();
    newController.dispose();
    confirmController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = context.watch<NotificationProvider>().hasUnread;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      bottomNavigationBar: const AppBottomNavBar(currentRoute: '/profile'),
      body: Stack(
        children: [
          StreamBuilder(
            stream: context.read<AuthProvider>().userStream,
            builder: (context, snapshot) {
              final authProvider = context.read<AuthProvider>();
              final fallbackFirebaseUser = authProvider.firebaseUser;
              final user = snapshot.data ?? authProvider.user;
              if (user == null && fallbackFirebaseUser == null) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                return const Center(child: Text('Not logged in'));
              }

              final displayName =
                  user?.name ?? fallbackFirebaseUser?.displayName ?? 'User';
              final displayEmail =
                  user?.email ?? fallbackFirebaseUser?.email ?? '';
              final displayMobile = user?.mobile ?? '';
              final displayProfileImage = user?.profileImageUrl;
              final displayIsAdmin = user?.isAdmin ?? false;

              final nameParts = displayName.split(' ');
              final firstName = nameParts.isNotEmpty ? nameParts[0] : '';
              final lastName =
                  nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
              final userInitial =
                  displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';

              if (!_isEditing) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_isEditing && user != null) {
                    _syncControllersFromUser(user);
                  }
                });
              }

              if (!_isEditing && user == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || _isEditing) return;
                  _firstNameController.text = firstName;
                  _lastNameController.text = lastName;
                  _emailController.text = displayEmail;
                  _mobileController.text = displayMobile;
                });
              }

              return SingleChildScrollView(
                child: Column(
                  children: [
                    // Blue Header
                    Container(
                      width: double.infinity,
                      color: AppTheme.primaryBlue,
                      padding: EdgeInsets.fromLTRB(
                        24,
                        20 + MediaQuery.of(context).padding.top,
                        24,
                        20,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.person, color: Colors.white),
                            onPressed: () {},
                          ),
                          const Text(
                            'PROFILE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                const Icon(Icons.notifications,
                                    color: Colors.white),
                                if (hasUnread)
                                  const Positioned(
                                    right: -1,
                                    top: -1,
                                    child: SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            onPressed: () {
                              if (!_showNotificationPanel) {
                                context
                                    .read<NotificationProvider>()
                                    .markAllAsRead();
                              }
                              setState(() {
                                _showNotificationPanel =
                                    !_showNotificationPanel;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // User Info Card
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            // Avatar with edit button
                            Stack(
                              children: [
                                GestureDetector(
                                  onTap: _uploadingImage
                                      ? null
                                      : _pickAndUploadImage,
                                  child: CircleAvatar(
                                    radius: 50,
                                    backgroundColor:
                                        Colors.white.withOpacity(0.3),
                                    backgroundImage: displayProfileImage != null
                                        ? NetworkImage(displayProfileImage)
                                        : null,
                                    child: _uploadingImage
                                        ? const CircularProgressIndicator(
                                            color: Colors.white,
                                          )
                                        : displayProfileImage == null
                                            ? Text(
                                                userInitial,
                                                style: const TextStyle(
                                                  fontSize: 40,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white,
                                                ),
                                              )
                                            : null,
                                  ),
                                ),
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: GestureDetector(
                                    onTap: _uploadingImage
                                        ? null
                                        : _pickAndUploadImage,
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: AppTheme.primaryBlue,
                                          width: 2,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.camera_alt,
                                        size: 18,
                                        color: AppTheme.primaryBlue,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            // Name
                            Text(
                              displayName,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Email
                            Text(
                              displayEmail,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Info Section
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            // First Name
                            _InfoRow(
                              label: 'First Name',
                              value: firstName,
                              isEditing: _isEditing,
                              controller: _firstNameController,
                            ),
                            const Divider(height: 32),
                            // Last Name
                            _InfoRow(
                              label: 'Last Name',
                              value: lastName,
                              isEditing: _isEditing,
                              controller: _lastNameController,
                            ),
                            const Divider(height: 32),
                            // Email
                            _InfoRow(
                              label: 'Email',
                              value: displayEmail,
                              isEditing: false,
                              controller: _emailController,
                            ),
                            const Divider(height: 32),
                            // Mobile
                            _InfoRow(
                              label: 'Mobile',
                              value: displayMobile,
                              isEditing: _isEditing,
                              controller: _mobileController,
                            ),
                            const SizedBox(height: 24),
                            // Edit Profile Button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () async {
                                  if (_isEditing) {
                                    // Save changes
                                    final firstName =
                                        _firstNameController.text.trim();
                                    final lastName =
                                        _lastNameController.text.trim();
                                    final mobile =
                                        _mobileController.text.trim();
                                    final fullName =
                                        '$firstName $lastName'.trim();

                                    if (fullName.isEmpty) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('Name cannot be empty'),
                                          backgroundColor: Colors.red,
                                        ),
                                      );
                                      return;
                                    }

                                    try {
                                      await context
                                          .read<AuthProvider>()
                                          .updateProfile(
                                            name: fullName,
                                            mobile: mobile,
                                          );

                                      setState(() => _isEditing = false);

                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                'Profile updated successfully!'),
                                            backgroundColor: Colors.green,
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                                'Failed to update profile: $e'),
                                            backgroundColor: Colors.red,
                                          ),
                                        );
                                      }
                                    }
                                  } else {
                                    setState(() => _isEditing = true);
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryBlue,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(
                                  _isEditing ? 'Save Profile' : 'Edit Profile',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Admin Dashboard Button (only for admins)
                            if (displayIsAdmin)
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () => context.push('/admin'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryGreen,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  icon: const Icon(Icons.admin_panel_settings,
                                      color: Colors.white),
                                  label: const Text(
                                    'Admin Dashboard',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            if (displayIsAdmin) const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _showChangePasswordDialog,
                                icon: const Icon(Icons.lock_reset),
                                label: const Text('Change Password'),
                                style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Logout Button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () async {
                                  await context.read<AuthProvider>().logout();
                                  if (context.mounted) context.go('/login');
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFE53935),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Logout',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          ),
          // Notification Panel Overlay
          if (_showNotificationPanel)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showNotificationPanel = false;
                  });
                },
                child: Container(
                  color: Colors.black.withOpacity(0.3),
                  child: GestureDetector(
                    onTap: () {},
                    child: NotificationPanel(
                      notifications:
                          context.watch<NotificationProvider>().notifications,
                      onClose: () {
                        setState(() {
                          _showNotificationPanel = false;
                        });
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    required this.isEditing,
    required this.controller,
  });

  final String label;
  final String value;
  final bool isEditing;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    if (isEditing && label != 'Email') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.grey,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            textAlign: TextAlign.left,
            keyboardType:
                label == 'Mobile' ? TextInputType.phone : TextInputType.text,
            inputFormatters: label == 'Mobile'
                ? [FilteringTextInputFormatter.digitsOnly]
                : null,
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
      ],
    );
  }
}
