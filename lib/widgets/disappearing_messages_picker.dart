import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../utils/disappearing_message_duration.dart';
import 'glass.dart';

Future<int?> showDisappearingMessagesPickerDialog(
  BuildContext context, {
  required int initialSeconds,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) =>
        _DisappearingMessagesPickerDialog(initialSeconds: initialSeconds),
  );
}

class _DisappearingMessagesPickerDialog extends StatefulWidget {
  final int initialSeconds;

  const _DisappearingMessagesPickerDialog({required this.initialSeconds});

  @override
  State<_DisappearingMessagesPickerDialog> createState() =>
      _DisappearingMessagesPickerDialogState();
}

class _DisappearingMessagesPickerDialogState
    extends State<_DisappearingMessagesPickerDialog> {
  late int _days;
  late int _hours;
  late int _minutes;
  late int _seconds;
  late final FixedExtentScrollController _daysController;
  late final FixedExtentScrollController _hoursController;
  late final FixedExtentScrollController _minutesController;
  late final FixedExtentScrollController _secondsController;

  int get _selectedSeconds => disappearingMessageSecondsFromParts(
    days: _days,
    hours: _hours,
    minutes: _minutes,
    seconds: _seconds,
  );

  @override
  void initState() {
    super.initState();
    final parts = disappearingMessageDurationParts(widget.initialSeconds);
    _days = parts.days;
    _hours = parts.hours;
    _minutes = parts.minutes;
    _seconds = parts.seconds;
    _daysController = FixedExtentScrollController(initialItem: _days);
    _hoursController = FixedExtentScrollController(initialItem: _hours);
    _minutesController = FixedExtentScrollController(initialItem: _minutes);
    _secondsController = FixedExtentScrollController(initialItem: _seconds);
  }

  @override
  void dispose() {
    _daysController.dispose();
    _hoursController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassAlertDialog(
      title: const Text('Disappearing messages'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              disappearingMessageSummaryLabel(_selectedSeconds),
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 216,
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _DurationWheel(
                      controller: _daysController,
                      childCount: maxDisappearingMessageDays + 1,
                      labelFor: (value) => '$value d',
                      onChanged: (value) => setState(() => _days = value),
                    ),
                  ),
                  Expanded(
                    child: _DurationWheel(
                      controller: _hoursController,
                      childCount: Duration.hoursPerDay,
                      labelFor: (value) => '$value h',
                      onChanged: (value) => setState(() => _hours = value),
                    ),
                  ),
                  Expanded(
                    child: _DurationWheel(
                      controller: _minutesController,
                      childCount: Duration.minutesPerHour,
                      labelFor: (value) => '$value m',
                      onChanged: (value) => setState(() => _minutes = value),
                    ),
                  ),
                  Expanded(
                    child: _DurationWheel(
                      controller: _secondsController,
                      childCount: Duration.secondsPerMinute,
                      labelFor: (value) => '$value s',
                      onChanged: (value) => setState(() => _seconds = value),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selectedSeconds),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DurationWheel extends StatelessWidget {
  final FixedExtentScrollController controller;
  final int childCount;
  final String Function(int value) labelFor;
  final ValueChanged<int> onChanged;

  const _DurationWheel({
    required this.controller,
    required this.childCount,
    required this.labelFor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoPicker.builder(
      scrollController: controller,
      itemExtent: 40,
      useMagnifier: true,
      magnification: 1.06,
      backgroundColor: Colors.transparent,
      childCount: childCount,
      onSelectedItemChanged: onChanged,
      itemBuilder: (context, index) {
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              labelFor(index),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        );
      },
    );
  }
}
