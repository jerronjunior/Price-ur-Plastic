import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
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

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    final nameParts = user?.name.split(' ') ?? ['', ''];
    _firstNameController = TextEditingController(text: nameParts.isNotEmpty ? nameParts[0] : '');
    _lastNameController = TextEditingController(text: nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '');
    _emailController = TextEditingController(text: user?.email ?? '');
    _mobileController = TextEditingController(text: ''); // Empty mobile field
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

      // Upload to Firebase Storage
      final userId = context.read<AuthProvider>().userId;
      if (userId == null) return;

      final imageUrl = await _storageService.uploadProfileImage(
        userId,
        File(pickedFile.path),
      );

      if (imageUrl != null && mounted) {
        // Update user profile with new image URL
        await context.read<AuthProvider>().updateProfileImage(imageUrl);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile picture updated!')),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to upload image')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingImage = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      bottomNavigationBar: AppBottomNavBar(currentRoute: '/profile'),
      body: Stack(
        children: [
          StreamBuilder(
            stream: context.read<AuthProvider>().userStream,
            builder: (context, snapshot) {
              final user = snapshot.data ?? context.read<AuthProvider>().user;
              if (user == null) {
                return const Center(child: Text('Not logged in'));
              }

              final nameParts = user.name.split(' ');
              final firstName = nameParts.isNotEmpty ? nameParts[0] : '';
              final lastName = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
              final userInitial = user.name.isNotEmpty ? user.name[0].toUpperCase() : '?';

              return SingleChildScrollView(
            child: Column(
              children: [
                // Blue Header
                Container(
                  width: double.infinity,
                  color: AppTheme.primaryBlue,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
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
                        icon: const Icon(Icons.notifications, color: Colors.white),
                        onPressed: () {
                          setState(() {
                            _showNotificationPanel = !_showNotificationPanel;
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
                              onTap: _uploadingImage ? null : _pickAndUploadImage,
                              child: CircleAvatar(
                                radius: 50,
                                backgroundColor: Colors.white.withOpacity(0.3),
                                backgroundImage: user.profileImageUrl != null
                                    ? NetworkImage(user.profileImageUrl!)
                                    : null,
                                child: _uploadingImage
                                    ? const CircularProgressIndicator(
                                        color: Colors.white,
                                      )
                                    : user.profileImageUrl == null
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
                                onTap: _uploadingImage ? null : _pickAndUploadImage,
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
                                  child: Icon(
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
                          user.name,
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
                          user.email,
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
                          value: user.email,
                          isEditing: false,
                          controller: _emailController,
                        ),
                        const Divider(height: 32),
                        // Mobile
                        _InfoRow(
                          label: 'Mobile',
                          value: '',
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
                                final firstName = _firstNameController.text.trim();
                                final lastName = _lastNameController.text.trim();
                                final fullName = '$firstName $lastName'.trim();
                                if (fullName.isNotEmpty) {
                                  await context.read<AuthProvider>().updateName(fullName);
                                }
                              }
                              setState(() => _isEditing = !_isEditing);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              padding: const EdgeInsets.symmetric(vertical: 14),
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
                              padding: const EdgeInsets.symmetric(vertical: 14),
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
          SizedBox(
            width: 150,
            child: TextField(
              controller: controller,
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
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
