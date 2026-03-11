import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/firestore_service.dart';
import '../../models/reward_config_model.dart';
import '../../core/theme.dart';

/// Admin screen to configure reward settings.
class ManageRewardsScreen extends StatefulWidget {
  const ManageRewardsScreen({super.key});

  @override
  State<ManageRewardsScreen> createState() => _ManageRewardsScreenState();
}

class _ManageRewardsScreenState extends State<ManageRewardsScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _pointsPerBottleController;
  late TextEditingController _bronzePointsController;
  late TextEditingController _silverPointsController;
  late TextEditingController _goldPointsController;
  late TextEditingController _maxBottlesPerDayController;
  late TextEditingController _cooldownSecondsController;
  late TextEditingController _wheelGiftsController;

  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _pointsPerBottleController = TextEditingController();
    _bronzePointsController = TextEditingController();
    _silverPointsController = TextEditingController();
    _goldPointsController = TextEditingController();
    _maxBottlesPerDayController = TextEditingController();
    _cooldownSecondsController = TextEditingController();
    _wheelGiftsController = TextEditingController();
    _loadConfig();
  }

  @override
  void dispose() {
    _pointsPerBottleController.dispose();
    _bronzePointsController.dispose();
    _silverPointsController.dispose();
    _goldPointsController.dispose();
    _maxBottlesPerDayController.dispose();
    _cooldownSecondsController.dispose();
    _wheelGiftsController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() => _isLoading = true);
    try {
      final config = await _firestoreService.getRewardConfig();
      _pointsPerBottleController.text = config.pointsPerBottle.toString();
      _bronzePointsController.text = config.bronzePoints.toString();
      _silverPointsController.text = config.silverPoints.toString();
      _goldPointsController.text = config.goldPoints.toString();
      _maxBottlesPerDayController.text = config.maxBottlesPerDay.toString();
      _cooldownSecondsController.text = config.cooldownSeconds.toString();
      _wheelGiftsController.text = config.wheelGifts.join('\n');
      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load config: $e')),
        );
      }
    }
  }

  Future<void> _saveConfig() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final config = RewardConfigModel(
        id: 'default',
        pointsPerBottle: int.parse(_pointsPerBottleController.text),
        bronzePoints: int.parse(_bronzePointsController.text),
        silverPoints: int.parse(_silverPointsController.text),
        goldPoints: int.parse(_goldPointsController.text),
        maxBottlesPerDay: int.parse(_maxBottlesPerDayController.text),
        cooldownSeconds: int.parse(_cooldownSecondsController.text),
        wheelGifts: _wheelGiftsController.text
            .split('\n')
            .map((gift) => gift.trim())
            .where((gift) => gift.isNotEmpty)
            .toList(),
      );

      await _firestoreService.updateRewardConfig(config);

      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Reward settings updated successfully'),
            backgroundColor: AppTheme.primaryGreen,
          ),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving config: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Rewards'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSectionCard(
                      'Recycling Rewards',
                      Icons.recycling,
                      [
                        _buildNumberField(
                          controller: _pointsPerBottleController,
                          label: 'Points Per Bottle',
                          hint: 'How many points earned per bottle',
                          icon: Icons.stars,
                        ),
                        const SizedBox(height: 16),
                        _buildNumberField(
                          controller: _maxBottlesPerDayController,
                          label: 'Max Bottles Per Day',
                          hint: 'Daily bottle recycling limit',
                          icon: Icons.local_drink,
                        ),
                        const SizedBox(height: 16),
                        _buildNumberField(
                          controller: _cooldownSecondsController,
                          label: 'Cooldown (seconds)',
                          hint: 'Time between scans',
                          icon: Icons.timer,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _buildSectionCard(
                      'Wheel Gifts',
                      Icons.card_giftcard,
                      [
                        TextFormField(
                          controller: _wheelGiftsController,
                          minLines: 6,
                          maxLines: 10,
                          decoration: const InputDecoration(
                            labelText: 'Reward Gifts',
                            hintText: 'Enter one gift per line',
                            prefixIcon: Icon(Icons.redeem),
                            alignLabelWithHint: true,
                          ),
                          validator: (value) {
                            final gifts = (value ?? '')
                                .split('\n')
                                .map((gift) => gift.trim())
                                .where((gift) => gift.isNotEmpty)
                                .toList();
                            if (gifts.isEmpty) {
                              return 'Add at least one reward gift';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _buildSectionCard(
                      'Reward Tiers',
                      Icons.emoji_events,
                      [
                        _buildNumberField(
                          controller: _bronzePointsController,
                          label: 'Bronze Tier Points',
                          hint: 'Points needed for Bronze',
                          icon: Icons.workspace_premium,
                          color: const Color(0xFFCD7F32),
                        ),
                        const SizedBox(height: 16),
                        _buildNumberField(
                          controller: _silverPointsController,
                          label: 'Silver Tier Points',
                          hint: 'Points needed for Silver',
                          icon: Icons.workspace_premium,
                          color: Colors.grey[400]!,
                        ),
                        const SizedBox(height: 16),
                        _buildNumberField(
                          controller: _goldPointsController,
                          label: 'Gold Tier Points',
                          hint: 'Points needed for Gold',
                          icon: Icons.workspace_premium,
                          color: const Color(0xFFFFD700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveConfig,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.save),
                      label: Text(_isSaving ? 'Saving...' : 'Save Changes'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _isLoading || _isSaving ? null : _loadConfig,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset to Current'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSectionCard(String title, IconData icon, List<Widget> children) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppTheme.primaryGreen),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildNumberField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    Color? color,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: color ?? AppTheme.primaryGreen),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) {
          return 'Please enter a value';
        }
        final number = int.tryParse(value);
        if (number == null || number < 0) {
          return 'Please enter a valid positive number';
        }
        return null;
      },
    );
  }
}
