import 'dart:io';
import 'package:flutter/material.dart';

class RamSlider extends StatefulWidget {
  final int initialRamMb;
  final ValueChanged<int> onChanged;

  const RamSlider({
    super.key,
    required this.initialRamMb,
    required this.onChanged,
  });

  @override
  State<RamSlider> createState() => _RamSliderState();
}

class _RamSliderState extends State<RamSlider> {
  late int _ramMb;
  late List<int> _steps;

  @override
  void initState() {
    super.initState();
    _steps = _buildSteps();
    // Clamp initial value to nearest valid step
    _ramMb = _nearestStep(widget.initialRamMb);
  }

  /// Build RAM steps based on total device RAM, capping at 75% of available.
  List<int> _buildSteps() {
    // Base steps (MB) — always available
    const base = [512, 1024, 1536, 2048, 3072, 4096, 6144, 8192,
                   10240, 12288, 16384, 20480, 24576, 32768];

    int totalMb = _detectTotalRamMb();
    // Allow up to 75 % of total RAM to leave headroom for the OS
    int maxAllowed = (totalMb * 0.75).floor();
    // Round maxAllowed down to nearest 512 MB boundary
    maxAllowed = (maxAllowed ~/ 512) * 512;
    // At minimum always allow 8 GB steps regardless of detection
    maxAllowed = maxAllowed.clamp(8192, 32768);

    return base.where((v) => v <= maxAllowed).toList();
  }

  /// Try to read total system RAM. Returns a safe fallback (8 GB) on failure.
  int _detectTotalRamMb() {
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        final meminfo = File('/proc/meminfo').readAsStringSync();
        final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
        if (match != null) {
          return (int.parse(match.group(1)!) / 1024).floor();
        }
      }
      // Windows — parse `wmic` output is async-unfriendly here; fallback to 8 GB
    } catch (_) {}
    return 8192; // safe fallback
  }

  int _nearestStep(int mb) {
    if (_steps.isEmpty) return 1024;
    return _steps.reduce((a, b) =>
        (a - mb).abs() < (b - mb).abs() ? a : b);
  }

  String _formatRam(int mb) {
    if (mb < 1024) return '${mb}MB';
    final gb = mb / 1024;
    return gb == gb.truncateToDouble()
        ? '${gb.toInt()}GB'
        : '${gb.toStringAsFixed(1)}GB';
  }

  @override
  Widget build(BuildContext context) {
    final stepIndex = _steps.indexOf(_ramMb).clamp(0, _steps.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'RAM Allocation',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF00C853).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF00C853).withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                _formatRam(_ramMb),
                style: const TextStyle(
                  color: Color(0xFF00C853),
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFF00C853),
            inactiveTrackColor: const Color(0xFF00C853).withValues(alpha: 0.2),
            thumbColor: const Color(0xFF00C853),
            overlayColor: const Color(0xFF00C853).withValues(alpha: 0.1),
            trackHeight: 4,
          ),
          child: Slider(
            value: stepIndex.toDouble(),
            min: 0,
            max: (_steps.length - 1).toDouble(),
            divisions: _steps.length - 1,
            onChanged: (val) {
              final newRam = _steps[val.round()];
              setState(() => _ramMb = newRam);
              widget.onChanged(newRam);
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatRam(_steps.first),
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            Text(
              '≤ 75% device RAM',
              style: TextStyle(fontSize: 10, color: Colors.grey[700]),
            ),
            Text(
              _formatRam(_steps.last),
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      ],
    );
  }
}