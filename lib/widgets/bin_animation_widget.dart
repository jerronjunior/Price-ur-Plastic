import 'package:flutter/material.dart';
import 'dart:async';

class BinAnimationWidget extends StatefulWidget {
  final VoidCallback? onBottleInserted;

  const BinAnimationWidget({Key? key, this.onBottleInserted}) : super(key: key);

  @override
  State<BinAnimationWidget> createState() => _BinAnimationWidgetState();
}

class _BinAnimationWidgetState extends State<BinAnimationWidget> {
  bool _isArrowHidden = false;
  int _insertCount = 0;

  void _insertBottle() {
    if (_isArrowHidden) return; // Prevent multiple inserts at the same time

    setState(() {
      _isArrowHidden = true;
    });

    // Arrow hides for 1 second, then counts as one and reappears
    Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _isArrowHidden = false;
          _insertCount++;
        });
        if (widget.onBottleInserted != null) {
          widget.onBottleInserted!();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Bottle draggable or insert button
        ElevatedButton.icon(
          onPressed: _insertBottle,
          icon: const Icon(Icons.water_drop),
          label: const Text('Insert Bottle'),
        ),
        const SizedBox(height: 30),
        
        // The Bin
        Container(
          width: 150,
          height: 200,
          decoration: BoxDecoration(
            color: Colors.green[700],
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(10),
              bottomRight: Radius.circular(10),
            ),
            border: Border.all(color: Colors.green[900]!, width: 4),
          ),
          child: Column(
            children: [
              // The opening slot
              Container(
                width: double.infinity,
                height: 40,
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                ),
                alignment: Alignment.center,
                child: AnimatedOpacity(
                  opacity: _isArrowHidden ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(
                    Icons.arrow_downward, // Upside down arrow
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.delete_outline,
                color: Colors.white54,
                size: 60,
              ),
              const Spacer(),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Bottles Inserted: $_insertCount',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
